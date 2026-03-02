#import <Cocoa/Cocoa.h>
// Import DeviceManager only for the enum — avoid circular imports.
#import "DeviceManager.h"

/// Owns the menu bar status item (the icon in the system menu bar).
/// Shows device connection state and quick access to guides and app window.
@interface StatusBarController : NSObject

+ (instancetype _Nullable )sharedController;

/// Update the icon and tooltip to reflect current connection state.
- (void)updateConnectionState:(DeviceConnectionState)state deviceName:(NSString *_Nullable)name;

@end


