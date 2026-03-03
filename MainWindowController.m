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
@property (nonatomic, strong) TransferEngine              *transferEngine;

// Bottom status bar
@property (nonatomic, strong) NSView       *statusDot;
@property (nonatomic, strong) NSTextField  *statusLabel;
@property (nonatomic, strong) NSButton     *reconnectButton;

// Disconnected overlay
@property (nonatomic, strong) NSView       *emptyStateView;

// Prevents stacking connection-error alerts
@property (nonatomic, assign) BOOL          errorAlertPresented;

@end

@implementation MainWindowController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1100, 700)
                  styleMask:NSWindowStyleMaskTitled        |
                            NSWindowStyleMaskResizable     |
                            NSWindowStyleMaskClosable      |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title   = @"AFC2 Utility";
    win.minSize = NSMakeSize(800, 520);
    if (!(self = [super initWithWindow:win])) return nil;
    [self buildUI];
    [self observeDeviceNotifications];
    [self updateStatusForState:DeviceConnectionStateDisconnected];
    return self;
}

// ── UI ────────────────────────────────────────────────────────────────────────

- (void)buildUI {
    self.macVC      = [[MacBrowserViewController alloc] init];
    self.ipadVC     = [[iPadBrowserViewController alloc] init];
    self.transferVC = [[TransferPanelViewController alloc] init];
    self.macVC.partnerBrowser  = self.ipadVC;
    self.ipadVC.partnerBrowser = self.macVC;

    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    split.splitView.vertical = YES;
    NSSplitViewItem *macItem  = [NSSplitViewItem splitViewItemWithViewController:self.macVC];
    NSSplitViewItem *ipadItem = [NSSplitViewItem splitViewItemWithViewController:self.ipadVC];
    macItem.minimumThickness  = 280;
    ipadItem.minimumThickness = 280;
    [split addSplitViewItem:macItem];
    [split addSplitViewItem:ipadItem];
    self.splitVC = split;

    NSView *statusBar  = [self buildStatusBar];
    NSView *emptyState = [self buildEmptyState];
    self.emptyStateView = emptyState;

    NSView *content = self.window.contentView;
    for (NSView *v in @[split.view, emptyState, self.transferVC.view, statusBar])
        v.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:split.view];
    [content addSubview:emptyState];
    [content addSubview:self.transferVC.view];
    [content addSubview:statusBar];

    [NSLayoutConstraint activateConstraints:@[
        [split.view.topAnchor      constraintEqualToAnchor:content.topAnchor],
        [split.view.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [split.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [split.view.bottomAnchor   constraintEqualToAnchor:self.transferVC.view.topAnchor],

        [emptyState.topAnchor      constraintEqualToAnchor:split.view.topAnchor],
        [emptyState.leadingAnchor  constraintEqualToAnchor:split.view.leadingAnchor],
        [emptyState.trailingAnchor constraintEqualToAnchor:split.view.trailingAnchor],
        [emptyState.bottomAnchor   constraintEqualToAnchor:split.view.bottomAnchor],

        [self.transferVC.view.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [self.transferVC.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.transferVC.view.bottomAnchor   constraintEqualToAnchor:statusBar.topAnchor],
        [self.transferVC.view.heightAnchor   constraintEqualToConstant:110],

        [statusBar.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [statusBar.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor],
        [statusBar.heightAnchor   constraintEqualToConstant:28],
    ]];

    [self.window center];
}

// ── Status bar (slim, bottom) ─────────────────────────────────────────────────

- (NSView *)buildStatusBar {
    NSView *bar = [[NSView alloc] init];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *dot = [[NSView alloc] init];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = 4;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot = dot;

    NSTextField *lbl = [NSTextField labelWithString:@"No device connected"];
    lbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    lbl.textColor = [NSColor secondaryLabelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = lbl;

    NSButton *btn = [NSButton buttonWithTitle:@"Reconnect"
                                       target:self
                                       action:@selector(reconnect:)];
    btn.bezelStyle  = NSBezelStyleInline;
    btn.controlSize = NSControlSizeSmall;
    btn.hidden      = YES;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    self.reconnectButton = btn;

    [bar addSubview:sep];
    [bar addSubview:dot];
    [bar addSubview:lbl];
    [bar addSubview:btn];

    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor      constraintEqualToAnchor:bar.topAnchor],
        [sep.leadingAnchor  constraintEqualToAnchor:bar.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],

        [dot.widthAnchor    constraintEqualToConstant:8],
        [dot.heightAnchor   constraintEqualToConstant:8],
        [dot.leadingAnchor  constraintEqualToAnchor:bar.leadingAnchor constant:10],
        [dot.centerYAnchor  constraintEqualToAnchor:bar.centerYAnchor],

        [lbl.leadingAnchor  constraintEqualToAnchor:dot.trailingAnchor constant:6],
        [lbl.centerYAnchor  constraintEqualToAnchor:bar.centerYAnchor],

        [btn.leadingAnchor  constraintEqualToAnchor:lbl.trailingAnchor constant:8],
        [btn.centerYAnchor  constraintEqualToAnchor:bar.centerYAnchor],
    ]];
    return bar;
}

// ── Disconnected overlay ──────────────────────────────────────────────────────

- (NSView *)buildEmptyState {
    NSView *view = [[NSView alloc] init];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    NSImageView *icon = [[NSImageView alloc] init];
    if (@available(macOS 11.0, *)) {
//        icon.image = [[NSImage imageWithSystemSymbolName:@"cable.connector"
//                                   accessibilityDescription:nil]
//                      imageWithSymbolConfiguration:
//                          [NSImageSymbolConfiguration
//                              configurationWithPointSize:44 weight:NSFontWeightThin]];
    } else {
        icon.image = [NSImage imageNamed:NSImageNameNetwork];
    }
    icon.contentTintColor = [NSColor tertiaryLabelColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"No Device Connected"];
    title.font      = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    title.textColor = [NSColor labelColor];
    title.alignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *sub = [NSTextField wrappingLabelWithString:
        @"Connect a jailbroken iPad 2 via USB.\n"
        @"Apple File Conduit 2 must be installed on the device."];
    sub.font      = [NSFont systemFontOfSize:12];
    sub.textColor = [NSColor secondaryLabelColor];
    sub.alignment = NSTextAlignmentCenter;
    sub.translatesAutoresizingMaskIntoConstraints = NO;

    [view addSubview:icon];
    [view addSubview:title];
    [view addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-44],
        [icon.widthAnchor   constraintEqualToConstant:52],
        [icon.heightAnchor  constraintEqualToConstant:52],

        [title.topAnchor     constraintEqualToAnchor:icon.bottomAnchor constant:16],
        [title.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        [sub.topAnchor     constraintEqualToAnchor:title.bottomAnchor constant:8],
        [sub.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [sub.widthAnchor   constraintLessThanOrEqualToConstant:340],
    ]];
    return view;
}

// ── Device notifications ──────────────────────────────────────────────────────

- (void)observeDeviceNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(_deviceConnected:)
               name:DeviceDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceDisconnected:)
               name:DeviceDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceFailed:)
               name:DeviceConnectionFailedNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceRetrying:)
               name:DeviceConnectionRetryingNotification object:nil];
}

- (void)_deviceConnected:(NSNotification *)note {
    DeviceManager *mgr = [DeviceManager sharedManager];
    self.transferEngine        = [[TransferEngine alloc] initWithAFC2Client:mgr.afc2Client];
    self.ipadVC.afc2Client     = mgr.afc2Client;
    self.ipadVC.transferEngine = self.transferEngine;
    self.macVC.transferEngine  = self.transferEngine;
    self.transferVC.engine     = self.transferEngine;

    [self.ipadVC navigateTo:@"/"];
    [self updateStatusForState:DeviceConnectionStateConnected];
    self.window.title = [NSString stringWithFormat:@"AFC2 Utility \u2014 %@",
                         mgr.deviceName ?: @"iPad"];

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        self.emptyStateView.animator.alphaValue = 0;
    } completionHandler:^{
        self.emptyStateView.hidden = YES;
    }];
}

- (void)_deviceDisconnected:(NSNotification *)note {
    [self.ipadVC clearBrowser];
    self.transferEngine        = nil;
    self.ipadVC.afc2Client     = nil;
    self.ipadVC.transferEngine = nil;
    self.macVC.transferEngine  = nil;
    self.transferVC.engine     = nil;
    [self updateStatusForState:DeviceConnectionStateDisconnected];
    self.window.title = @"AFC2 Utility";

    self.emptyStateView.hidden     = NO;
    self.emptyStateView.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        self.emptyStateView.animator.alphaValue = 1;
    }];
}

- (void)_deviceFailed:(NSNotification *)note {
    NSError *err = note.userInfo[DeviceConnectionErrorKey];
    [self updateStatusForState:DeviceConnectionStateFailed];
    self.window.title = @"AFC2 Utility";

    if (!self.errorAlertPresented) {
        self.errorAlertPresented = YES;
        [self presentConnectionError:err];
        self.errorAlertPresented = NO;
    }
}

- (void)_deviceRetrying:(NSNotification *)note {
    NSError *info = note.userInfo[DeviceConnectionErrorKey];
    self.statusLabel.stringValue = info.localizedDescription ?: @"Retrying\u2026";
    self.statusDot.layer.backgroundColor = [NSColor systemYellowColor].CGColor;
    self.reconnectButton.hidden = YES;
}

// ── Status bar update ─────────────────────────────────────────────────────────

- (void)updateStatusForState:(DeviceConnectionState)state {
    NSColor  *color;
    NSString *text;

    switch (state) {
        case DeviceConnectionStateDisconnected:
            color = [NSColor systemGrayColor];
            text  = @"No device connected";
            self.reconnectButton.hidden = YES;
            break;
        case DeviceConnectionStateConnecting:
            color = [NSColor systemYellowColor];
            text  = @"Connecting\u2026";
            self.reconnectButton.hidden = YES;
            break;
        case DeviceConnectionStateConnected: {
            color = [NSColor systemGreenColor];
            NSString *name = [DeviceManager sharedManager].deviceName ?: @"iPad";
            text = [NSString stringWithFormat:@"Connected \u2014 %@", name];
            self.reconnectButton.hidden = YES;
            break;
        }
        case DeviceConnectionStateFailed:
            color = [NSColor systemRedColor];
            text  = @"Connection failed";
            self.reconnectButton.hidden = NO;
            break;
    }

    self.statusDot.layer.backgroundColor = color.CGColor;
    self.statusLabel.stringValue = text;
}

// ── Connection error alert ────────────────────────────────────────────────────

- (void)presentConnectionError:(NSError *)error {
    NSAlert *alert       = [[NSAlert alloc] init];
    alert.alertStyle     = NSAlertStyleWarning;
    alert.messageText    = @"Could Not Connect to Device";
    alert.informativeText = error.localizedDescription ?: @"An unknown error occurred.";
    [alert addButtonWithTitle:@"OK"];

    NSString *reason = error.localizedDescription ?: @"";
    BOOL isAFC2Issue = ([reason containsString:@"AFC2"] ||
                        [reason containsString:@"afc2"] ||
                        [reason containsString:@"Cydia"] ||
                        [reason containsString:@"jailbreak"]);
    [alert addButtonWithTitle:isAFC2Issue ? @"AFC2 Guide\u2026" : @"Troubleshooting\u2026"];

    if ([alert runModal] == NSAlertSecondButtonReturn) {
        if (isAFC2Issue) [self showAFC2InstallGuide:nil];
        else             [self showTroubleshooting:nil];
    }
}

// ── Menu action forwarding ────────────────────────────────────────────────────

- (void)triggerUpload    { [self.macVC  triggerUpload]; }
- (void)triggerDownload  { [self.ipadVC downloadSelected:nil]; }
- (void)triggerNewFolder { [self.ipadVC newFolder:nil]; }
- (void)triggerRefresh   { [self.ipadVC refresh:nil]; }

- (IBAction)reconnect:(id)sender {
    [self updateStatusForState:DeviceConnectionStateConnecting];
    [[DeviceManager sharedManager] reconnect];
}

// ── Guide / help sheets ───────────────────────────────────────────────────────

- (void)showAFC2InstallGuide:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle    = NSAlertStyleInformational;
    a.messageText   = @"AFC2 Installation Guide";
    a.informativeText =
        @"Apple File Conduit 2 (AFC2) grants full filesystem access over USB.\n\n"
        @"Requirements\n"
        @"  \u2022 iPad 2, iOS 9.3.5\n"
        @"  \u2022 Jailbroken with Ph\u0153nix\n\n"
        @"Steps\n"
        @"  1. Open Cydia on the iPad.\n"
        @"  2. Search for \u201cApple File Conduit 2\u201d (source: BigBoss).\n"
        @"  3. Install it, then tap Restart Springboard.\n"
        @"  4. Plug into Mac via Lightning cable.\n"
        @"  5. Unlock iPad \u2014 tap Trust if prompted.\n"
        @"  6. AFC2 Utility connects automatically.\n\n"
        @"BigBoss is pre-added in Cydia on iOS 9 \u2014 no extra sources needed.";
    [a addButtonWithTitle:@"Done"];
    [a addButtonWithTitle:@"Jailbreak Guide\u2026"];
    [a addButtonWithTitle:@"Troubleshooting\u2026"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertSecondButtonReturn) [self showJailbreakGuide:nil];
    if (r == NSAlertThirdButtonReturn)  [self showTroubleshooting:nil];
}

- (void)showJailbreakGuide:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle    = NSAlertStyleInformational;
    a.messageText   = @"Jailbreaking iPad 2 — iOS 9.3.5";
    a.informativeText =
        @"Use Ph\u0153nix (semi-untethered jailbreak by Siguza & tihmstar).\n\n"
        @"  1. Download Ph\u0153nix IPA from phoenixpwn.com.\n"
        @"  2. Install to iPad via AltStore or Sideloadly.\n"
        @"  3. Trust the developer certificate in Settings \u203a General \u203a\n"
        @"     VPN & Device Management.\n"
        @"  4. Open the Ph\u0153nix app and follow the prompts.\n"
        @"  5. Cydia appears on the home screen after success.\n\n"
        @"Note: Re-run Ph\u0153nix after every reboot to restore the jailbreak.";
    [a addButtonWithTitle:@"Done"];
    [a addButtonWithTitle:@"AFC2 Guide\u2026"];
    if ([a runModal] == NSAlertSecondButtonReturn) [self showAFC2InstallGuide:nil];
}

- (void)showTroubleshooting:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle    = NSAlertStyleInformational;
    a.messageText   = @"Connection Troubleshooting";
    a.informativeText =
        @"1. Try a different Lightning cable or USB port.\n\n"
        @"2. Unlock the iPad. Tap Trust if prompted.\n\n"
        @"3. Re-jailbreak — Ph\u0153nix is semi-untethered. Open the app again after a reboot.\n\n"
        @"4. Confirm AFC2 is installed in Cydia.\n\n"
        @"5. Reset trust: Settings \u203a General \u203a Transfer or Reset iPad \u203a\n"
        @"   Reset Location & Privacy. Reconnect and tap Trust.\n\n"
        @"6. Restart usbmuxd in Terminal:\n"
        @"      sudo pkill usbmuxd\n\n"
        @"7. Check Console.app — filter on \u201clockdownd\u201d or \u201cusbmuxd\u201d.";
    [a addButtonWithTitle:@"Done"];
    [a addButtonWithTitle:@"AFC2 Guide\u2026"];
    if ([a runModal] == NSAlertSecondButtonReturn) [self showAFC2InstallGuide:nil];
}

- (void)showHelp:(id)sender {
    NSAlert *a = [[NSAlert alloc] init];
    a.alertStyle    = NSAlertStyleInformational;
    a.messageText   = @"How to Use AFC2 Utility";
    a.informativeText =
        @"Left panel \u2014 Mac filesystem.  Right panel \u2014 iPad filesystem.\n\n"
        @"Transfer files\n"
        @"  \u2022 Drag Mac files into the iPad panel to upload.\n"
        @"  \u2022 Right-click an iPad item \u2192 Download.\n"
        @"  \u2022 \u2318U upload  /  \u2318D download.\n\n"
        @"Manage iPad files\n"
        @"  \u2022 Right-click \u2192 Rename or Delete.\n"
        @"  \u2022 \u21e7\u2318N new folder.  \u2191 go up.  \u2318R refresh.\n\n"
        @"Transfers panel\n"
        @"  \u2022 Active transfers shown at the bottom.\n"
        @"  \u2022 Double-click a failed item for error details.\n\n"
        @"Safety\n"
        @"  \u2022 /System, /bin, /usr, /sbin are write-protected.\n"
        @"  \u2022 /Library, /etc, /private require confirmation.";
    [a addButtonWithTitle:@"Done"];
    [a runModal];
}

@end
