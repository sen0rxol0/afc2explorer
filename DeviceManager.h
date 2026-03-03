#import <Foundation/Foundation.h>

@class AFC2Client;

typedef NS_ENUM(NSInteger, DeviceConnectionState) {
    DeviceConnectionStateDisconnected,
    DeviceConnectionStateConnecting,
    DeviceConnectionStateConnected,
    DeviceConnectionStateFailed
};

extern NSNotificationName const DeviceDidConnectNotification;
extern NSNotificationName const DeviceDidDisconnectNotification;
extern NSNotificationName const DeviceConnectionFailedNotification;
extern NSNotificationName const DeviceConnectionRetryingNotification;
extern NSString *const DeviceConnectionErrorKey;

@interface DeviceManager : NSObject

@property (atomic,   readonly) DeviceConnectionState connectionState;
@property (nonatomic, readonly, strong) AFC2Client *afc2Client;
@property (nonatomic, readonly, copy)   NSString   *deviceName;
@property (nonatomic, readonly, copy)   NSString   *deviceUDID;

+ (instancetype)sharedManager;

/// Start the USB event listener and probe for already-attached devices.
- (void)startMonitoring;

/// Stop the USB event listener and tear down any active session.
- (void)stopMonitoring;

/// Tear down the current session and probe again immediately.
/// Safe to call from any thread.
- (void)reconnect;

@end
