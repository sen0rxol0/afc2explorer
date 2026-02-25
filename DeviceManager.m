#import "DeviceManager.h"
#import "AFC2Client.h"

// libimobiledevice C headers
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/afc.h>

NSNotificationName const DeviceDidConnectNotification    = @"DeviceDidConnectNotification";
NSNotificationName const DeviceDidDisconnectNotification = @"DeviceDidDisconnectNotification";
NSNotificationName const DeviceConnectionFailedNotification = @"DeviceConnectionFailedNotification";
NSString *const DeviceConnectionErrorKey = @"DeviceConnectionErrorKey";

// ── Private interface ─────────────────────────────────────────────────────────

@interface DeviceManager () {
    idevice_t          _device;
    lockdownd_client_t _lockdown;
    afc_client_t       _afcRaw;          // kept only during connect; handed to AFC2Client
}

@property (nonatomic, readwrite) DeviceConnectionState connectionState;
@property (nonatomic, readwrite, strong) AFC2Client *afc2Client;
@property (nonatomic, readwrite, copy) NSString *deviceName;
@property (nonatomic, readwrite, copy) NSString *deviceUDID;

@property (nonatomic, strong) dispatch_queue_t connectionQueue;

- (void)handleDeviceEvent:(const idevice_event_t *)event;

@end

// ── C callback ────────────────────────────────────────────────────────────────
// Placed after the @interface extension so handleDeviceEvent: is visible
// to the compiler when the call on the next line is parsed.

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
}

- (void)stopMonitoring {
    idevice_event_unsubscribe();
    [self disconnect];
}

// ── Event dispatch (from C callback, may be any thread) ──────────────────────

- (void)handleDeviceEvent:(const idevice_event_t *)event {
    if (event->conn_type != CONNECTION_USBMUXD) return;   // USB only

    NSString *udid = [NSString stringWithUTF8String:event->udid];

    if (event->event == IDEVICE_DEVICE_ADD) {
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

    idevice_error_t err;

    // 1. Open device handle
    err = idevice_new_with_options(&_device, udid.UTF8String, IDEVICE_LOOKUP_USBMUX);
    if (err != IDEVICE_E_SUCCESS) {
        [self failWithDescription:@"Could not open device handle" code:err];
        return;
    }

    // 2. Lockdown client
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(_device, &_lockdown, "AFC2Utility");
    if (lerr != LOCKDOWN_E_SUCCESS) {
        [self failWithDescription:@"Lockdown handshake failed" code:lerr];
        return;
    }

    // 3. Read device name for UI
    char *devName = NULL;
    lockdownd_get_device_name(_lockdown, &devName);
    self.deviceName = devName ? [NSString stringWithUTF8String:devName] : @"iPad";
    if (devName) free(devName);
    self.deviceUDID = udid;

    // 4. Start AFC2 service
    lockdownd_service_descriptor_t svc = NULL;
    lerr = lockdownd_start_service(_lockdown, "com.apple.afc2", &svc);
    if (lerr != LOCKDOWN_E_SUCCESS || !svc) {
        [self failWithDescription:@"AFC2 service unavailable – is the device jailbroken with AFC2 installed?" code:lerr];
        return;
    }

    // 5. Open AFC client
    afc_error_t aerr = afc_client_new(_device, svc, &_afcRaw);
    lockdownd_service_descriptor_free(svc);
    if (aerr != AFC_E_SUCCESS) {
        [self failWithDescription:@"Failed to open AFC2 client" code:aerr];
        return;
    }

    // 6. Hand raw client to our ObjC wrapper
    AFC2Client *client = [[AFC2Client alloc] initWithAFCClient:_afcRaw device:_device];
    _afcRaw  = NULL;   // ownership transferred
    _device  = NULL;

    self.afc2Client     = client;
    self.connectionState = DeviceConnectionStateConnected;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DeviceDidConnectNotification object:self];
    });
}

- (void)handleUnexpectedDisconnect {
    [self teardownNative];
    [self.afc2Client invalidate];
    self.afc2Client      = nil;
    self.connectionState = DeviceConnectionStateDisconnected;
    self.deviceName      = nil;
    self.deviceUDID      = nil;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DeviceDidDisconnectNotification object:self];
    });
}

- (void)disconnect {
    dispatch_sync(_connectionQueue, ^{
        [self handleUnexpectedDisconnect];
    });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (void)teardownNative {
    if (_afcRaw)  { afc_client_free(_afcRaw);        _afcRaw  = NULL; }
    if (_lockdown){ lockdownd_client_free(_lockdown); _lockdown = NULL; }
    if (_device)  { idevice_free(_device);            _device  = NULL; }
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

@end
