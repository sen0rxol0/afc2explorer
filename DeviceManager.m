#import "DeviceManager.h"
#import "AFC2Client.h"

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>

NSNotificationName const DeviceDidConnectNotification         = @"DeviceDidConnectNotification";
NSNotificationName const DeviceDidDisconnectNotification      = @"DeviceDidDisconnectNotification";
NSNotificationName const DeviceConnectionFailedNotification   = @"DeviceConnectionFailedNotification";
NSNotificationName const DeviceConnectionRetryingNotification = @"DeviceConnectionRetryingNotification";
NSString *const DeviceConnectionErrorKey = @"DeviceConnectionErrorKey";

static const NSUInteger      kMaxRetries   = 2;
static const NSTimeInterval  kRetryDelay   = 1.0;

// ── Private ───────────────────────────────────────────────────────────────────

@interface DeviceManager () {
    idevice_t          _device;
    lockdownd_client_t _lockdown;
    afc_client_t       _afcRaw;
    NSUInteger         _retryCount;
    BOOL               _subscribed;   // track whether event callback is active
}
@property (atomic,   readwrite) DeviceConnectionState connectionState;
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
    // Guard: only subscribe once.  Calling idevice_event_subscribe twice
    // registers a second callback that fires in parallel — causes races.
    if (_subscribed) return;
    _subscribed = YES;
    idevice_event_subscribe(device_event_cb, (__bridge void *)self);

    // Probe for an already-attached device immediately so we don't wait for
    // a new ADD event if the device was plugged in before the app launched.
    dispatch_async(_connectionQueue, ^{
        [self probeAttachedDevice];
    });
}

- (void)stopMonitoring {
    if (_subscribed) {
        idevice_event_unsubscribe();
        _subscribed = NO;
    }
    [self _teardownSession];
}

/// Scan the USBMUX device list and connect to the first device found.
- (void)probeAttachedDevice {
    if (self.connectionState != DeviceConnectionStateDisconnected &&
        self.connectionState != DeviceConnectionStateFailed) return;

    idevice_info_t *devList = NULL;
    int count = 0;
    // idevice_get_device_list_extended is available in libimobiledevice ≥1.3
    if (idevice_get_device_list_extended(&devList, &count) != IDEVICE_E_SUCCESS) return;

    NSString *udid = nil;
    for (int i = 0; i < count; i++) {
        if (devList[i]->conn_type == CONNECTION_USBMUXD) {
            udid = [NSString stringWithUTF8String:devList[i]->udid];
            break;
        }
    }
    idevice_device_list_extended_free(devList);

    if (udid) {
        _retryCount = 0;
        [self connectToDeviceWithUDID:udid];
    }
}

// ── Manual reconnect (called by UI buttons / menu) ────────────────────────────

- (void)reconnect {
    // Tear down cleanly on the connection queue, then restart.
    dispatch_async(_connectionQueue, ^{
        [self _teardownSession];
        self.connectionState = DeviceConnectionStateDisconnected;
        // Small pause so usbmuxd can settle before we probe again.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       self->_connectionQueue, ^{
            [self probeAttachedDevice];
        });
    });
}

// ── Event callback ────────────────────────────────────────────────────────────

- (void)handleDeviceEvent:(const idevice_event_t *)event {
    if (event->conn_type != CONNECTION_USBMUXD) return;
    NSString *udid = [NSString stringWithUTF8String:event->udid];

    if (event->event == IDEVICE_DEVICE_ADD) {
        if (self.connectionState != DeviceConnectionStateDisconnected &&
            self.connectionState != DeviceConnectionStateFailed) return;
        _retryCount = 0;
        dispatch_async(_connectionQueue, ^{
            [self connectToDeviceWithUDID:udid];
        });

    } else if (event->event == IDEVICE_DEVICE_REMOVE) {
        if ([udid isEqualToString:self.deviceUDID]) {
            dispatch_async(_connectionQueue, ^{
                [self _teardownSession];
                self.connectionState = DeviceConnectionStateDisconnected;
                self.deviceName = nil;
                self.deviceUDID = nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:DeviceDidDisconnectNotification object:self];
                });
            });
        }
    }
}

// ── Connection sequence ───────────────────────────────────────────────────────

- (void)connectToDeviceWithUDID:(NSString *)udid {
    // Must run on _connectionQueue, not main thread.
    [self _teardownNative];
    self.connectionState = DeviceConnectionStateConnecting;

    // ── Step 1: device handle ─────────────────────────────────────────────────
    idevice_error_t ierr = idevice_new_with_options(&_device,
                                                     udid.UTF8String,
                                                     IDEVICE_LOOKUP_USBMUX);
    if (ierr != IDEVICE_E_SUCCESS) {
        NSString *msg = (ierr == IDEVICE_E_NO_DEVICE)
            ? @"Device not found — check the USB cable."
            : [NSString stringWithFormat:@"Cannot open device (idevice error %d).", ierr];
        [self _failWithMessage:msg code:ierr]; return;
    }

    // ── Step 2: lockdown handshake (with transient-error retry) ──────────────
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(
        _device, &_lockdown, "AFC2Utility");

    if (lerr != LOCKDOWN_E_SUCCESS) {
        BOOL transient = (lerr == LOCKDOWN_E_SSL_ERROR ||
                          lerr == LOCKDOWN_E_INVALID_RESPONSE ||
                          lerr == LOCKDOWN_E_RECEIVE_TIMEOUT);
        if (transient && _retryCount < kMaxRetries) {
            _retryCount++;
            NSString *hint = [NSString stringWithFormat:
                @"Handshake hiccup, retrying (%lu/%lu)…",
                (unsigned long)_retryCount, (unsigned long)kMaxRetries];
            [self _postRetrying:hint];
            [self _teardownNative];
            self.connectionState = DeviceConnectionStateConnecting;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(kRetryDelay * NSEC_PER_SEC)),
                           _connectionQueue, ^{
                [self connectToDeviceWithUDID:udid];
            });
            return;
        }

        NSString *msg;
        if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED)
            msg = @"iPad is locked — unlock it and tap Trust when prompted.";
        else if (lerr == LOCKDOWN_E_USER_DENIED_PAIRING)
            msg = @"Trust was denied. On iPad: Settings › General › Transfer or Reset iPad "
                  @"› Reset Location & Privacy, then reconnect.";
        else if (lerr == LOCKDOWN_E_PAIRING_FAILED)
            msg = @"Pairing failed. Disconnect the cable and reconnect, then tap Trust.";
        else
            msg = [NSString stringWithFormat:
                @"Lockdown handshake failed (error %d). Unlock the iPad and tap Trust.",
                lerr];
        [self _failWithMessage:msg code:lerr]; return;
    }

    // ── Step 3: read device name ──────────────────────────────────────────────
    char *name = NULL;
    lockdownd_get_device_name(_lockdown, &name);
    self.deviceName = name ? @(name) : @"iPad";
    if (name) free(name);
    self.deviceUDID = udid;

    // ── Step 4: start AFC2 service ────────────────────────────────────────────
    lockdownd_service_descriptor_t svc = NULL;
    lerr = lockdownd_start_service(_lockdown, "com.apple.afc2", &svc);
    if (lerr != LOCKDOWN_E_SUCCESS || !svc) {
        NSString *msg = (lerr == LOCKDOWN_E_INVALID_SERVICE || !svc)
            ? @"AFC2 service not found.\n\n"
              "Install Apple File Conduit 2 via Cydia on the jailbroken iPad, "
              "then reconnect. Use Device › AFC2 Installation Guide for help."
            : [NSString stringWithFormat:
                @"AFC2 service failed to start (error %d). "
                @"Ensure the device is currently jailbroken.", lerr];
        [self _failWithMessage:msg code:lerr]; return;
    }

    // ── Step 5: open AFC client ───────────────────────────────────────────────
    afc_error_t aerr = afc_client_new(_device, svc, &_afcRaw);
    lockdownd_service_descriptor_free(svc);
    if (aerr != AFC_E_SUCCESS) {
        [self _failWithMessage:[NSString stringWithFormat:
            @"AFC2 client failed to open (error %d). "
            @"Disconnect and reconnect the cable.", aerr]
                         code:aerr];
        return;
    }

    // ── Step 6: hand off to wrapper ───────────────────────────────────────────
    AFC2Client *client = [[AFC2Client alloc] initWithAFCClient:_afcRaw device:_device];
    _afcRaw = NULL;
    _device = NULL;

    self.afc2Client      = client;
    self.connectionState = DeviceConnectionStateConnected;
    _retryCount = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceDidConnectNotification object:self];
    });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Tear down the AFC2Client wrapper and post a disconnect notification.
- (void)_teardownSession {
    [self.afc2Client invalidate];
    self.afc2Client = nil;
    _retryCount = 0;
    [self _teardownNative];
}

/// Free raw libimobiledevice handles without touching the AFC2Client wrapper.
- (void)_teardownNative {
    if (_afcRaw)   { afc_client_free(_afcRaw);        _afcRaw   = NULL; }
    if (_lockdown) { lockdownd_client_free(_lockdown); _lockdown = NULL; }
    if (_device)   { idevice_free(_device);            _device   = NULL; }
}

- (void)_failWithMessage:(NSString *)msg code:(int)code {
    [self _teardownNative];
    self.connectionState = DeviceConnectionStateFailed;
    NSError *err = [NSError errorWithDomain:@"AFC2UtilityErrorDomain"
                                       code:code
                                   userInfo:@{NSLocalizedDescriptionKey: msg}];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceConnectionFailedNotification
                          object:self
                        userInfo:@{DeviceConnectionErrorKey: err}];
    });
}

- (void)_postRetrying:(NSString *)msg {
    NSError *info = [NSError errorWithDomain:@"AFC2UtilityErrorDomain"
                                        code:0
                                    userInfo:@{NSLocalizedDescriptionKey: msg}];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:DeviceConnectionRetryingNotification
                          object:self
                        userInfo:@{DeviceConnectionErrorKey: info}];
    });
}

// ── Legacy public disconnect (kept for stopMonitoring) ────────────────────────

- (void)disconnect {
    dispatch_async(_connectionQueue, ^{
        [self _teardownSession];
        self.connectionState = DeviceConnectionStateDisconnected;
        self.deviceName = nil;
        self.deviceUDID = nil;
    });
}

@end
