#import "DeviceManager.h"
#import "AFC2Client.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>

NSNotificationName const DeviceDidConnectNotification       = @"DeviceDidConnectNotification";
NSNotificationName const DeviceDidDisconnectNotification    = @"DeviceDidDisconnectNotification";
NSNotificationName const DeviceConnectionFailedNotification = @"DeviceConnectionFailedNotification";
NSNotificationName const DeviceConnectionRetryingNotification = @"DeviceConnectionRetryingNotification";
NSString *const DeviceConnectionErrorKey = @"DeviceConnectionErrorKey";

/// Maximum automatic retry attempts for transient connection errors.
static const NSUInteger kDeviceConnectionMaxRetries = 2;
/// Seconds to wait between automatic retry attempts.
static const NSTimeInterval kDeviceConnectionRetryDelay = 0.8;

// ── Private interface ─────────────────────────────────────────────────────────

@interface DeviceManager () {
    idevice_t          _device;
    lockdownd_client_t _lockdown;
    afc_client_t       _afcRaw;
    NSUInteger         _retryCount;
}

@property (atomic, readwrite) DeviceConnectionState connectionState;
@property (nonatomic, readwrite, strong) AFC2Client *afc2Client;
@property (nonatomic, readwrite, copy)   NSString   *deviceName;
@property (nonatomic, readwrite, copy)   NSString   *deviceUDID;
@property (nonatomic, strong) dispatch_queue_t connectionQueue;

- (void)handleDeviceEvent:(const idevice_event_t *)event;

@end

static void device_event_cb(const idevice_event_t *event, void *userdata) {
    DeviceManager *mgr = (__bridge DeviceManager *)userdata;
    [mgr handleDeviceEvent:event];
}

// ── Implementation ────────────────────────────────────────────────────────────

@implementation DeviceManager

+ (instancetype)sharedManager {
    static DeviceManager *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _connectionState = DeviceConnectionStateDisconnected;
    _connectionQueue = dispatch_queue_create("com.afc2util.device", DISPATCH_QUEUE_SERIAL);
    return self;
}

// ── Monitoring ────────────────────────────────────────────────────────────────

- (void)startMonitoring {
    idevice_event_subscribe(device_event_cb, (__bridge void *)self);
    // FIX (UX): if a device is already attached when monitoring starts, probe
    // for it immediately so we connect without waiting for a new ADD event.
    dispatch_async(_connectionQueue, ^{
        char **udids = NULL;
        int count = 0;
        if (idevice_get_device_list(&udids, &count) == IDEVICE_E_SUCCESS && count > 0) {
            NSString *udid = [NSString stringWithUTF8String:udids[0]];
            idevice_device_list_free(udids);
            if (self.connectionState == DeviceConnectionStateDisconnected ||
                self.connectionState == DeviceConnectionStateFailed) {
                _retryCount = 0;
                [self connectToDeviceWithUDID:udid];
            }
        } else {
            if (udids) idevice_device_list_free(udids);
        }
    });
}

- (void)stopMonitoring {
    idevice_event_unsubscribe();
    [self disconnect];
}

// ── Event dispatch ────────────────────────────────────────────────────────────

- (void)handleDeviceEvent:(const idevice_event_t *)event {
    if (event->conn_type != CONNECTION_USBMUXD) return;

    NSString *udid = [NSString stringWithUTF8String:event->udid];

    if (event->event == IDEVICE_DEVICE_ADD) {
        // Guard against duplicate ADD events (USB re-enumeration).
        if (self.connectionState != DeviceConnectionStateDisconnected &&
            self.connectionState != DeviceConnectionStateFailed) return;

        _retryCount = 0;
        dispatch_async(_connectionQueue, ^{
            [self connectToDeviceWithUDID:udid];
        });
    } else if (event->event == IDEVICE_DEVICE_REMOVE) {
        if ([udid isEqualToString:self.deviceUDID]) {
            dispatch_async(_connectionQueue, ^{
                [self handleUnexpectedDisconnect];
            });
        }
    }
}

// ── Connection sequence ───────────────────────────────────────────────────────

- (void)connectToDeviceWithUDID:(NSString *)udid {
    NSAssert(![NSThread isMainThread], @"Must run off main thread");

    [self teardownNative];
    self.connectionState = DeviceConnectionStateConnecting;

    // 1. Open device handle
    idevice_error_t err = idevice_new_with_options(&_device, udid.UTF8String, IDEVICE_LOOKUP_USBMUX);
    if (err != IDEVICE_E_SUCCESS) {
        NSString *desc = (err == IDEVICE_E_NO_DEVICE)
            ? @"Device not found. Try a different USB cable or port, then reconnect."
            : [NSString stringWithFormat:@"Could not open device handle (error %d).", err];
        [self failWithDescription:desc code:err]; return;
    }

    // 2. Lockdown client — retry on SSL/timeout errors that can occur transiently
    //    during USB re-enumeration immediately after plug-in.
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(_device, &_lockdown, "AFC2Utility");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        BOOL isTransient = (lerr == LOCKDOWN_E_SSL_ERROR || lerr == LOCKDOWN_E_INVALID_RESPONSE);
        if (isTransient && _retryCount < kDeviceConnectionMaxRetries) {
            _retryCount++;
            NSString *info = [NSString stringWithFormat:
                @"Handshake hiccup — retrying (%lu of %lu)…",
                (unsigned long)_retryCount,
                (unsigned long)kDeviceConnectionMaxRetries];
            [self postRetryingWithDescription:info];
            [self teardownNative];
            self.connectionState = DeviceConnectionStateConnecting;
            dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(kDeviceConnectionRetryDelay * NSEC_PER_SEC));
            dispatch_after(when, _connectionQueue, ^{
                [self connectToDeviceWithUDID:udid];
            });
            return;
        }

        NSString *desc;
        switch (lerr) {
            case LOCKDOWN_E_PASSWORD_PROTECTED:
                desc = @"The iPad is locked. Unlock it and tap \u201cTrust This Computer\u201d when prompted.";
                break;
            case LOCKDOWN_E_USER_DENIED_PAIRING:
                desc = @"You tapped \u201cDon\u2019t Trust\u201d on the device. On the iPad go to "
                       @"Settings \u203a General \u203a Transfer or Reset iPad \u203a Reset Location & Privacy, "
                       @"then reconnect and tap Trust.";
                break;
            case LOCKDOWN_E_PAIRING_FAILED:
                desc = @"Pairing failed. Disconnect the cable, re-jailbreak with Ph\u0153nix if needed, "
                       @"then reconnect.";
                break;
            default:
                desc = [NSString stringWithFormat:
                    @"Lockdown handshake failed (error %d). Unlock the device and tap Trust.", lerr];
        }
        [self failWithDescription:desc code:lerr]; return;
    }

    // 3. Read device name
    char *devName = NULL;
    lockdownd_get_device_name(_lockdown, &devName);
    self.deviceName = devName ? [NSString stringWithUTF8String:devName] : @"iPad";
    if (devName) free(devName);
    self.deviceUDID = udid;

    // 4. Start AFC2 service
    lockdownd_service_descriptor_t svc = NULL;
    lerr = lockdownd_start_service(_lockdown, "com.apple.afc2", &svc);
    if (lerr != LOCKDOWN_E_SUCCESS || !svc) {
        NSString *desc = (lerr == LOCKDOWN_E_INVALID_SERVICE || !svc)
            ? @"AFC2 service not found on the device.\n\n"
              "Apple File Conduit 2 is not installed. Open Cydia on the iPad, "
              "search for \u201cApple File Conduit 2\u201d, install it, then "
              "use Device \u203a AFC2 Installation Guide for full instructions."
            : [NSString stringWithFormat:
                @"Failed to start AFC2 service (error %d). Ensure AFC2 is installed via Cydia "
                @"and the device is currently jailbroken.", lerr];
        [self failWithDescription:desc code:lerr]; return;
    }

    // 5. Open AFC client
    afc_error_t aerr = afc_client_new(_device, svc, &_afcRaw);
    lockdownd_service_descriptor_free(svc);
    if (aerr != AFC_E_SUCCESS) {
        [self failWithDescription:[NSString stringWithFormat:
            @"Failed to open AFC2 client (error %d). "
            @"Try disconnecting and reconnecting the cable.", aerr]
                             code:aerr]; return;
    }

    // 6. Hand off to ObjC wrapper
    AFC2Client *client = [[AFC2Client alloc] initWithAFCClient:_afcRaw device:_device];
    _afcRaw  = NULL;
    _device  = NULL;

    self.afc2Client      = client;
    self.connectionState = DeviceConnectionStateConnected;
    _retryCount = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceDidConnectNotification object:self];
    });
}

- (void)handleUnexpectedDisconnect {
    [self teardownNative];
    [self.afc2Client invalidate];
    self.afc2Client      = nil;
    self.connectionState = DeviceConnectionStateDisconnected;
    self.deviceName      = nil;
    self.deviceUDID      = nil;
    _retryCount          = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceDidDisconnectNotification object:self];
    });
}

// FIX (WARN): replace dispatch_sync with async + semaphore to avoid potential
// deadlock if disconnect is ever called from within connectionQueue.
- (void)disconnect {
    if (self.connectionState == DeviceConnectionStateDisconnected) return;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    dispatch_async(_connectionQueue, ^{
        [self handleUnexpectedDisconnect];
        dispatch_semaphore_signal(sema);
    });
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (void)teardownNative {
    if (_afcRaw)   { afc_client_free(_afcRaw);        _afcRaw   = NULL; }
    if (_lockdown) { lockdownd_client_free(_lockdown); _lockdown = NULL; }
    if (_device)   { idevice_free(_device);            _device   = NULL; }
}

- (void)failWithDescription:(NSString *)desc code:(int)code {
    [self teardownNative];
    self.connectionState = DeviceConnectionStateFailed;

    NSError *err = [NSError errorWithDomain:@"AFC2UtilityErrorDomain"
                                       code:code
                                   userInfo:@{NSLocalizedDescriptionKey: desc}];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceConnectionFailedNotification
                          object:self
                        userInfo:@{DeviceConnectionErrorKey: err}];
    });
}

- (void)postRetryingWithDescription:(NSString *)desc {
    NSError *info = [NSError errorWithDomain:@"AFC2UtilityErrorDomain"
                                        code:0
                                    userInfo:@{NSLocalizedDescriptionKey: desc}];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceConnectionRetryingNotification
                          object:self
                        userInfo:@{DeviceConnectionErrorKey: info}];
    });
}

@end
