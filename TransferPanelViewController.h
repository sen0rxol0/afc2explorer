#import <Cocoa/Cocoa.h>
@class TransferEngine;

@interface TransferPanelViewController : NSViewController
@property (nonatomic, weak) TransferEngine *engine;
@end
