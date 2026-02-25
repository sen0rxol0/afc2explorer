#import "MainWindowController.h"
#import "MacBrowserViewController.h"
#import "iPadBrowserViewController.h"
#import "TransferPanelViewController.h"
#import "DeviceManager.h"
#import "TransferEngine.h"

@interface MainWindowController ()

@property (nonatomic, strong) NSSplitViewController       *splitVC;
@property (nonatomic, strong) MacBrowserViewController    *macVC;
@property (nonatomic, strong) iPadBrowserViewController   *ipadVC;
@property (nonatomic, strong) TransferPanelViewController *transferVC;
@property (nonatomic, strong) NSTextField                 *statusLabel;
@property (nonatomic, strong) NSView                      *statusDot;
@property (nonatomic, strong) TransferEngine              *transferEngine;

@end

@implementation MainWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1100, 700)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                            NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title           = @"AFC2 Utility";
    window.minSize         = NSMakeSize(800, 500);
    window.titlebarAppearsTransparent = NO;

    if (!(self = [super initWithWindow:window])) return nil;

    [self buildUI];
    [self observeDeviceNotifications];
    [self updateStatusForState:DeviceConnectionStateDisconnected];

    return self;
}

// ── UI Construction ───────────────────────────────────────────────────────────

- (void)buildUI {
    self.macVC      = [[MacBrowserViewController alloc] init];
    self.ipadVC     = [[iPadBrowserViewController alloc] init];
    self.transferVC = [[TransferPanelViewController alloc] init];

    // Wire drag-drop between browsers via the engine (set after connect)
    self.macVC.partnerBrowser  = self.ipadVC;
    self.ipadVC.partnerBrowser = self.macVC;

    NSSplitViewController *splitVC = [[NSSplitViewController alloc] init];
    splitVC.splitView.vertical = YES;

    NSSplitViewItem *macItem   = [NSSplitViewItem splitViewItemWithViewController:self.macVC];
    NSSplitViewItem *ipadItem  = [NSSplitViewItem splitViewItemWithViewController:self.ipadVC];
    macItem.minimumThickness   = 300;
    ipadItem.minimumThickness  = 300;

    [splitVC addSplitViewItem:macItem];
    [splitVC addSplitViewItem:ipadItem];
    self.splitVC = splitVC;

    // Status bar at the bottom
    NSView *statusBar = [self buildStatusBar];

    // Transfer drawer below the split
    NSView *content = self.window.contentView;
    [content addSubview:splitVC.view];
    [content addSubview:statusBar];
    [content addSubview:self.transferVC.view];

    splitVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    statusBar.translatesAutoresizingMaskIntoConstraints    = NO;
    self.transferVC.view.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [splitVC.view.topAnchor constraintEqualToAnchor:content.topAnchor],
        [splitVC.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [splitVC.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [splitVC.view.bottomAnchor constraintEqualToAnchor:self.transferVC.view.topAnchor],

        [self.transferVC.view.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.transferVC.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.transferVC.view.bottomAnchor constraintEqualToAnchor:statusBar.topAnchor],
        [self.transferVC.view.heightAnchor constraintEqualToConstant:130],

        [statusBar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [statusBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [statusBar.heightAnchor constraintEqualToConstant:28],
    ]];

    [self.window center];
}

- (NSView *)buildStatusBar {
    NSView *bar = [[NSView alloc] init];
    bar.wantsLayer     = YES;
    bar.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    // Status dot
    NSView *dot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    dot.wantsLayer     = YES;
    dot.layer.cornerRadius = 5;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot = dot;

    NSTextField *label = [NSTextField labelWithString:@"No device connected"];
    label.font         = [NSFont systemFontOfSize:11];
    label.textColor    = [NSColor secondaryLabelColor];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel   = label;

    [bar addSubview:dot];
    [bar addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [dot.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [dot.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [dot.widthAnchor constraintEqualToConstant:10],
        [dot.heightAnchor constraintEqualToConstant:10],

        [label.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:6],
    ]];
    return bar;
}

// ── Device notifications ──────────────────────────────────────────────────────

- (void)observeDeviceNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(deviceConnected:)   name:DeviceDidConnectNotification    object:nil];
    [nc addObserver:self selector:@selector(deviceDisconnected:) name:DeviceDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(deviceFailed:)       name:DeviceConnectionFailedNotification object:nil];
}

- (void)deviceConnected:(NSNotification *)note {
    DeviceManager *mgr = [DeviceManager sharedManager];
    self.transferEngine = [[TransferEngine alloc] initWithAFC2Client:mgr.afc2Client];
    self.ipadVC.afc2Client     = mgr.afc2Client;
    self.ipadVC.transferEngine = self.transferEngine;
    self.macVC.transferEngine  = self.transferEngine;
    self.transferVC.engine     = self.transferEngine;

    [self.ipadVC navigateTo:@"/"];
    [self updateStatusForState:DeviceConnectionStateConnected];
}

- (void)deviceDisconnected:(NSNotification *)note {
    [self.ipadVC clearBrowser];
    self.transferEngine        = nil;
    self.ipadVC.afc2Client     = nil;
    self.ipadVC.transferEngine = nil;
    self.macVC.transferEngine  = nil;
    self.transferVC.engine     = nil;
    [self updateStatusForState:DeviceConnectionStateDisconnected];
}

- (void)deviceFailed:(NSNotification *)note {
    NSError *err = note.userInfo[DeviceConnectionErrorKey];
    [self updateStatusForState:DeviceConnectionStateFailed];
    self.statusLabel.stringValue = err.localizedDescription ?: @"Connection failed";

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateStatusForState:DeviceConnectionStateDisconnected];
    });
}

- (void)updateStatusForState:(DeviceConnectionState)state {
    NSColor *color;
    NSString *text;
    switch (state) {
        case DeviceConnectionStateDisconnected:
            color = [NSColor systemGrayColor];
            text  = @"No device connected";
            break;
        case DeviceConnectionStateConnecting:
            color = [NSColor systemYellowColor];
            text  = @"Connecting…";
            break;
        case DeviceConnectionStateConnected: {
            color = [NSColor systemGreenColor];
            NSString *name = [DeviceManager sharedManager].deviceName ?: @"iPad";
            text  = [NSString stringWithFormat:@"Connected – %@", name];
            break;
        }
        case DeviceConnectionStateFailed:
            color = [NSColor systemRedColor];
            text  = @"Connection failed";
            break;
    }
    self.statusDot.layer.backgroundColor = color.CGColor;
    self.statusLabel.stringValue = text;
}

@end
