#import "AppDelegate.h"
#import "MainWindowController.h"
#import "DeviceManager.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.mainWindowController = [[MainWindowController alloc] init];
    [self.mainWindowController showWindow:nil];
    [[DeviceManager sharedManager] startMonitoring];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[DeviceManager sharedManager] stopMonitoring];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
