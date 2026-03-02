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
extern NSString *const DeviceConnectionErrorKey;

/// Posted on the main thread whenever the error category changes so the UI can
/// offer targeted advice.  userInfo contains DeviceConnectionErrorKey.
extern NSNotificationName const DeviceConnectionRetryingNotification;

@interface DeviceManager : NSObject

@property (atomic, readonly) DeviceConnectionState connectionState;
@property (nonatomic, readonly, strong) AFC2Client *afc2Client;
@property (nonatomic, readonly, copy) NSString *deviceName;
@property (nonatomic, readonly, copy) NSString *deviceUDID;

+ (instancetype)sharedManager;

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)disconnect;

@end
