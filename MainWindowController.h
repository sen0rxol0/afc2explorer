#import <Cocoa/Cocoa.h>

@interface MainWindowController : NSWindowController

/// Called by AppDelegate menu actions
- (void)triggerUpload;
- (void)triggerDownload;
- (void)triggerNewFolder;
- (void)triggerRefresh;

/// Guide / help sheets — also called by in-window buttons
- (void)showAFC2InstallGuide:(id)sender;
- (void)showJailbreakGuide:(id)sender;
- (void)showTroubleshooting:(id)sender;
- (void)showHelp:(id)sender;

@end
