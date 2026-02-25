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

@interface DeviceManager : NSObject

@property (nonatomic, readonly) DeviceConnectionState connectionState;
@property (nonatomic, readonly, strong) AFC2Client *afc2Client;
@property (nonatomic, readonly, copy) NSString *deviceName;
@property (nonatomic, readonly, copy) NSString *deviceUDID;

+ (instancetype)sharedManager;

- (void)startMonitoring;
- (void)stopMonitoring;
- (void)disconnect;

@end
