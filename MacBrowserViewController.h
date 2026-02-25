#import <Cocoa/Cocoa.h>
@class TransferEngine;
@class iPadBrowserViewController;

@interface MacBrowserViewController : NSViewController
    <NSOutlineViewDataSource, NSOutlineViewDelegate,
     NSDraggingSource, NSMenuDelegate>

@property (nonatomic, weak) TransferEngine            *transferEngine;
@property (nonatomic, weak) iPadBrowserViewController *partnerBrowser;

/// Currently displayed directory
@property (nonatomic, copy, readonly) NSString *currentPath;

@end
