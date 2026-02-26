#import <Cocoa/Cocoa.h>
@class AFC2Client, TransferEngine, MacBrowserViewController;

@interface iPadBrowserViewController : NSViewController
    <NSOutlineViewDataSource, NSOutlineViewDelegate,
     NSDraggingDestination, NSMenuDelegate>

@property (nonatomic, weak) AFC2Client              *afc2Client;
@property (nonatomic, weak) TransferEngine          *transferEngine;
@property (nonatomic, weak) MacBrowserViewController *partnerBrowser;
@property (nonatomic, copy, readonly) NSString      *currentPath;

- (void)navigateTo:(NSString *)path;
- (void)clearBrowser;

/// Called by MainWindowController from File menu
- (IBAction)downloadSelected:(id)sender;
- (IBAction)newFolder:(id)sender;
- (IBAction)refresh:(id)sender;

@end
