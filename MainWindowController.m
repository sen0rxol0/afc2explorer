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

// Status bar
@property (nonatomic, strong) NSView      *statusDot;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *deviceDetailLabel;
@property (nonatomic, strong) NSButton    *reconnectButton;

// Empty / disconnected overlay
@property (nonatomic, strong) NSView      *emptyStateView;

// Track whether a connection-error alert is already showing to avoid stacking.
@property (nonatomic, assign) BOOL errorAlertPresented;

@end

@implementation MainWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1100, 720)
                  styleMask:NSWindowStyleMaskTitled        |
                            NSWindowStyleMaskResizable     |
                            NSWindowStyleMaskClosable      |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title   = @"AFC2 Utility";
    window.minSize = NSMakeSize(820, 560);
    if (!(self = [super initWithWindow:window])) return nil;
    [self buildUI];
    [self observeDeviceNotifications];
    [self updateStatusForState:DeviceConnectionStateDisconnected];
    return self;
}

// ── UI construction ───────────────────────────────────────────────────────────

- (void)buildUI {
    self.macVC      = [[MacBrowserViewController alloc] init];
    self.ipadVC     = [[iPadBrowserViewController alloc] init];
    self.transferVC = [[TransferPanelViewController alloc] init];

    self.macVC.partnerBrowser  = self.ipadVC;
    self.ipadVC.partnerBrowser = self.macVC;

    NSSplitViewController *splitVC = [[NSSplitViewController alloc] init];
    splitVC.splitView.vertical = YES;
    NSSplitViewItem *macItem  = [NSSplitViewItem splitViewItemWithViewController:self.macVC];
    NSSplitViewItem *ipadItem = [NSSplitViewItem splitViewItemWithViewController:self.ipadVC];
    macItem.minimumThickness  = 300;
    ipadItem.minimumThickness = 300;
    [splitVC addSplitViewItem:macItem];
    [splitVC addSplitViewItem:ipadItem];
    self.splitVC = splitVC;

    NSView *statusBar  = [self buildStatusBar];
    NSView *emptyState = [self buildEmptyState];
    self.emptyStateView = emptyState;

    NSView *content = self.window.contentView;
    [content addSubview:splitVC.view];
    [content addSubview:emptyState];
    [content addSubview:self.transferVC.view];
    [content addSubview:statusBar];

    for (NSView *v in @[splitVC.view, emptyState, self.transferVC.view, statusBar])
        v.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // Browsers fill the top area
        [splitVC.view.topAnchor    constraintEqualToAnchor:content.topAnchor],
        [splitVC.view.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [splitVC.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [splitVC.view.bottomAnchor constraintEqualToAnchor:self.transferVC.view.topAnchor],

        // Empty state covers browsers exactly
        [emptyState.topAnchor    constraintEqualToAnchor:splitVC.view.topAnchor],
        [emptyState.leadingAnchor  constraintEqualToAnchor:splitVC.view.leadingAnchor],
        [emptyState.trailingAnchor constraintEqualToAnchor:splitVC.view.trailingAnchor],
        [emptyState.bottomAnchor constraintEqualToAnchor:splitVC.view.bottomAnchor],

        // Transfer panel
        [self.transferVC.view.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [self.transferVC.view.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.transferVC.view.bottomAnchor   constraintEqualToAnchor:statusBar.topAnchor],
        [self.transferVC.view.heightAnchor   constraintEqualToConstant:130],

        // Status bar at bottom
        [statusBar.leadingAnchor  constraintEqualToAnchor:content.leadingAnchor],
        [statusBar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [statusBar.bottomAnchor   constraintEqualToAnchor:content.bottomAnchor],
        [statusBar.heightAnchor   constraintEqualToConstant:36],
    ]];

    [self.window center];
}

// ── Status bar ────────────────────────────────────────────────────────────────

- (NSView *)buildStatusBar {
    NSView *bar = [[NSView alloc] init];
    bar.wantsLayer = YES;
    bar.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    // Top hairline separator
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    // Coloured dot
    NSView *dot = [[NSView alloc] init];
    dot.wantsLayer = YES;
    dot.layer.cornerRadius = 5;
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot = dot;

    // Primary label — bold connection status
    NSTextField *label = [NSTextField labelWithString:@"No device connected"];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel = label;

    // Secondary label — UDID or hint
    NSTextField *detail = [NSTextField labelWithString:@""];
    detail.font      = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    detail.textColor = [NSColor tertiaryLabelColor];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    self.deviceDetailLabel = detail;

    // Reconnect button (only visible on failure / disconnected)
    NSButton *reconBtn = [NSButton buttonWithTitle:@"\u21ba Reconnect"
                                            target:self
                                            action:@selector(reconnect:)];
    reconBtn.bezelStyle  = NSBezelStyleInline;
    reconBtn.controlSize = NSControlSizeSmall;
    reconBtn.hidden      = YES;
    reconBtn.translatesAutoresizingMaskIntoConstraints = NO;
    self.reconnectButton = reconBtn;

    // AFC2 guide shortcut on the right
    NSButton *guideBtn = [NSButton buttonWithTitle:@"AFC2 Guide"
                                            target:self
                                            action:@selector(showAFC2InstallGuide:)];
    guideBtn.bezelStyle  = NSBezelStyleInline;
    guideBtn.controlSize = NSControlSizeSmall;
    guideBtn.translatesAutoresizingMaskIntoConstraints = NO;

    [bar addSubview:sep];
    [bar addSubview:dot];
    [bar addSubview:label];
    [bar addSubview:detail];
    [bar addSubview:reconBtn];
    [bar addSubview:guideBtn];

    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],

        [dot.widthAnchor  constraintEqualToConstant:10],
        [dot.heightAnchor constraintEqualToConstant:10],
        [dot.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:12],
        [dot.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:7],
        [label.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor constant:-6],

        [detail.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [detail.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:1],

        [reconBtn.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
        [reconBtn.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [guideBtn.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-12],
        [guideBtn.centerYAnchor  constraintEqualToAnchor:bar.centerYAnchor],
    ]];

    return bar;
}

// ── Empty / disconnected state ────────────────────────────────────────────────

- (NSView *)buildEmptyState {
    NSView *view = [[NSView alloc] init];
    view.wantsLayer = YES;
    view.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;

    NSImageView *iconView = [[NSImageView alloc] init];
    if (@available(macOS 11.0, *)) {
//        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
//            configurationWithPointSize:52 weight:NSFontWeightThin];
//        iconView.image = [[NSImage imageWithSystemSymbolName:@"cable.connector"
//                                       accessibilityDescription:nil]
//                          imageWithSymbolConfiguration:cfg];
    } else {
        iconView.image = [NSImage imageNamed:NSImageNameNetwork];
    }
    iconView.contentTintColor = [NSColor tertiaryLabelColor];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"No Device Connected"];
    title.font      = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.alignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *subtitle = [NSTextField wrappingLabelWithString:
        @"Connect a jailbroken iPad 2 via USB and make sure\n"
        @"Apple File Conduit 2 is installed on the device."];
    subtitle.font      = [NSFont systemFontOfSize:13];
    subtitle.textColor = [NSColor secondaryLabelColor];
    subtitle.alignment = NSTextAlignmentCenter;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *guideBtn = [NSButton buttonWithTitle:@"Open AFC2 Installation Guide\u2026"
                                            target:self
                                            action:@selector(showAFC2InstallGuide:)];
    guideBtn.bezelStyle = NSBezelStyleRounded;
    guideBtn.keyEquivalent = @"\r";
    guideBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *troubleBtn = [NSButton buttonWithTitle:@"Connection Troubleshooting\u2026"
                                              target:self
                                              action:@selector(showTroubleshooting:)];
    troubleBtn.bezelStyle = NSBezelStyleInline;
    troubleBtn.translatesAutoresizingMaskIntoConstraints = NO;

    [view addSubview:iconView];
    [view addSubview:title];
    [view addSubview:subtitle];
    [view addSubview:guideBtn];
    [view addSubview:troubleBtn];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:view.centerYAnchor constant:-64],
        [iconView.widthAnchor   constraintEqualToConstant:60],
        [iconView.heightAnchor  constraintEqualToConstant:60],

        [title.topAnchor    constraintEqualToAnchor:iconView.bottomAnchor constant:18],
        [title.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        [subtitle.topAnchor    constraintEqualToAnchor:title.bottomAnchor constant:10],
        [subtitle.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [subtitle.widthAnchor   constraintLessThanOrEqualToConstant:380],

        [guideBtn.topAnchor    constraintEqualToAnchor:subtitle.bottomAnchor constant:22],
        [guideBtn.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],

        [troubleBtn.topAnchor    constraintEqualToAnchor:guideBtn.bottomAnchor constant:10],
        [troubleBtn.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
    ]];

    return view;
}

// ── Device notifications ──────────────────────────────────────────────────────

- (void)observeDeviceNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(deviceConnected:)
               name:DeviceDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(deviceDisconnected:)
               name:DeviceDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(deviceFailed:)
               name:DeviceConnectionFailedNotification object:nil];
    [nc addObserver:self selector:@selector(deviceRetrying:)
               name:DeviceConnectionRetryingNotification object:nil];
}

- (void)deviceConnected:(NSNotification *)note {
    DeviceManager *mgr = [DeviceManager sharedManager];
    self.transferEngine            = [[TransferEngine alloc] initWithAFC2Client:mgr.afc2Client];
    self.ipadVC.afc2Client         = mgr.afc2Client;
    self.ipadVC.transferEngine     = self.transferEngine;
    self.macVC.transferEngine      = self.transferEngine;
    self.transferVC.engine         = self.transferEngine;

    [self.ipadVC navigateTo:@"/"];
    [self updateStatusForState:DeviceConnectionStateConnected];

    // FIX (UX): reflect device name in window title bar so it's visible even
    // when the status bar is small.
    NSString *devName = mgr.deviceName ?: @"iPad";
    self.window.title = [NSString stringWithFormat:@"AFC2 Utility \u2014 %@", devName];

    // Fade out empty state
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        self.emptyStateView.animator.alphaValue = 0;
    } completionHandler:^{
        self.emptyStateView.hidden = YES;
    }];
}

- (void)deviceDisconnected:(NSNotification *)note {
    [self.ipadVC clearBrowser];
    self.transferEngine        = nil;
    self.ipadVC.afc2Client     = nil;
    self.ipadVC.transferEngine = nil;
    self.macVC.transferEngine  = nil;
    self.transferVC.engine     = nil;
    [self updateStatusForState:DeviceConnectionStateDisconnected];
    self.window.title = @"AFC2 Utility";

    // Fade in empty state
    self.emptyStateView.hidden     = NO;
    self.emptyStateView.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.25;
        self.emptyStateView.animator.alphaValue = 1;
    }];
}

- (void)deviceFailed:(NSNotification *)note {
    NSError *err = note.userInfo[DeviceConnectionErrorKey];
    [self updateStatusForState:DeviceConnectionStateFailed];
    self.window.title = @"AFC2 Utility";

    // Only present the alert if one is not already showing.
    if (!self.errorAlertPresented) {
        self.errorAlertPresented = YES;
        [self presentConnectionError:err];
        self.errorAlertPresented = NO;
    }

    // Auto-reset the status dot back to "disconnected" after a delay, and
    // FIX (BUG): also sync the menu bar status item so it doesn't stay red.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([DeviceManager sharedManager].connectionState == DeviceConnectionStateFailed) {
            [self updateStatusForState:DeviceConnectionStateDisconnected];
            // Sync the menu bar icon to the reset state.
            [[NSNotificationCenter defaultCenter]
                postNotificationName:DeviceDidDisconnectNotification
                              object:[DeviceManager sharedManager]];
        }
    });
}

- (void)deviceRetrying:(NSNotification *)note {
    // Show the "Retrying…" message in the status bar without presenting an alert.
    NSError *info = note.userInfo[DeviceConnectionErrorKey];
    self.statusLabel.stringValue = info.localizedDescription ?: @"Retrying\u2026";
    self.statusDot.layer.backgroundColor = [NSColor systemYellowColor].CGColor;
    self.reconnectButton.hidden = YES;
}

// ── Status update ─────────────────────────────────────────────────────────────

- (void)updateStatusForState:(DeviceConnectionState)state {
    NSColor  *dotColor;
    NSString *text, *detail = @"";

    switch (state) {
        case DeviceConnectionStateDisconnected:
            dotColor = [NSColor systemGrayColor];
            text     = @"No device connected";
            self.reconnectButton.hidden = YES;
            break;
        case DeviceConnectionStateConnecting:
            dotColor = [NSColor systemYellowColor];
            text     = @"Connecting\u2026";
            self.reconnectButton.hidden = YES;
            break;
        case DeviceConnectionStateConnected: {
            dotColor = [NSColor systemGreenColor];
            DeviceManager *mgr = [DeviceManager sharedManager];
            text = [NSString stringWithFormat:@"Connected \u2014 %@", mgr.deviceName ?: @"iPad"];
            NSString *udid = mgr.deviceUDID;
            if (udid.length >= 12)
                detail = [NSString stringWithFormat:@"UDID  %@\u2026%@",
                          [udid substringToIndex:8],
                          [udid substringFromIndex:udid.length - 4]];
            self.reconnectButton.hidden = YES;
            break;
        }
        case DeviceConnectionStateFailed:
            dotColor = [NSColor systemRedColor];
            text     = @"Connection failed";
            detail   = @"Check USB cable and AFC2 installation \u2014 use \u21ba Reconnect to retry";
            self.reconnectButton.hidden = NO;
            break;
    }

    self.statusDot.layer.backgroundColor = dotColor.CGColor;
    self.statusLabel.stringValue         = text;
    self.deviceDetailLabel.stringValue   = detail;
}

// ── Connection error alert ────────────────────────────────────────────────────

- (void)presentConnectionError:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle  = NSAlertStyleWarning;
    alert.messageText = @"Could Not Connect to Device";

    NSString *reason = error.localizedDescription ?: @"An unknown error occurred.";

    // The error descriptions from DeviceManager.m are already user-friendly and
    // contain actionable guidance, so just show them directly.  We only append
    // a guide link hint when the message references AFC2 specifically.
    NSString *guideHint = @"";
    if ([reason containsString:@"AFC2"] || [reason containsString:@"afc2"] ||
        [reason containsString:@"Cydia"] || [reason containsString:@"jailbreak"]) {
        guideHint = @"\n\nUse the \u201cOpen AFC2 Guide\u2026\u201d button for step-by-step installation instructions.";
    }

    alert.informativeText = [reason stringByAppendingString:guideHint];
    [alert addButtonWithTitle:@"OK"];

    BOOL offerGuide = (guideHint.length > 0);
    if (offerGuide) {
        [alert addButtonWithTitle:@"Open AFC2 Guide\u2026"];
    } else {
        [alert addButtonWithTitle:@"Connection Troubleshooting\u2026"];
    }

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertSecondButtonReturn) {
        if (offerGuide)
            [self showAFC2InstallGuide:nil];
        else
            [self showTroubleshooting:nil];
    }
}

// ── Menu action forwarding ────────────────────────────────────────────────────

- (void)triggerUpload   { [self.macVC  triggerUpload]; }
- (void)triggerDownload { [self.ipadVC downloadSelected:nil]; }
- (void)triggerNewFolder { [self.ipadVC newFolder:nil]; }
- (void)triggerRefresh  { [self.ipadVC refresh:nil]; }

- (IBAction)reconnect:(id)sender {
    [[DeviceManager sharedManager] disconnect];
    // Update status immediately so the dot doesn't stay red/failed
    [self updateStatusForState:DeviceConnectionStateConnecting];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DeviceManager sharedManager] startMonitoring];
    });
}

// ── Guide / help sheets ───────────────────────────────────────────────────────

- (void)showAFC2InstallGuide:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"AFC2 Installation Guide";
    alert.informativeText =
        @"Apple File Conduit 2 (AFC2) grants full filesystem access over USB "
        @"on a jailbroken device.\n\n"
        @"Requirements\n"
        @"  \u2022 iPad 2 running iOS 9.3.5\n"
        @"  \u2022 Device jailbroken with Ph\u0153nix\n\n"
        @"Steps\n"
        @"  1. Open Cydia on the iPad.\n"
        @"  2. Tap Search and type \u201cApple File Conduit 2\u201d.\n"
        @"  3. Tap the result published by saurik \u2014 source: BigBoss.\n"
        @"  4. Tap Install \u2192 Confirm.\n"
        @"  5. When Cydia finishes, tap Restart Springboard.\n"
        @"  6. Plug the iPad into your Mac with a Lightning cable.\n"
        @"  7. Unlock the iPad \u2014 tap Trust if prompted.\n"
        @"  8. AFC2 Utility will detect the device automatically.\n\n"
        @"Note: The BigBoss source is pre-added in Cydia on iOS 9 \u2014 no extra setup needed.\n\n"
        @"If Cydia is not present, the device needs to be jailbroken first. "
        @"Tap \u201cJailbreak Guide\u2026\u201d for instructions.";
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Jailbreak Guide\u2026"];
    [alert addButtonWithTitle:@"Troubleshooting\u2026"];

    NSModalResponse r = [alert runModal];
    if (r == NSAlertSecondButtonReturn)  [self showJailbreakGuide:nil];
    if (r == NSAlertThirdButtonReturn)   [self showTroubleshooting:nil];
}

- (void)showJailbreakGuide:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"Jailbreaking iPad 2 on iOS 9.3.5";
    alert.informativeText =
        @"Ph\u0153nix is the recommended semi-untethered jailbreak for iPad 2 / iOS 9.3.5, "
        @"created by Siguza and tihmstar.\n\n"
        @"Steps\n"
        @"  1. Download the Ph\u0153nix IPA from phoenixpwn.com on your Mac.\n"
        @"  2. Install it onto the iPad using AltStore or Sideloadly.\n"
        @"  3. On the iPad: Settings \u203a General \u203a VPN & Device Management\n"
        @"     \u2192 trust your Apple ID\u2019s developer certificate.\n"
        @"  4. Open the Ph\u0153nix app on the iPad and follow the on-screen steps.\n"
        @"  5. After a successful jailbreak, Cydia appears on the home screen.\n\n"
        @"Important: Ph\u0153nix is semi-untethered \u2014 the jailbreak is lost on every reboot. "
        @"Re-run the Ph\u0153nix app (without reinstalling) each time the device restarts.";
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"AFC2 Guide\u2026"];

    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self showAFC2InstallGuide:nil];
}

- (void)showTroubleshooting:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"Connection Troubleshooting";
    alert.informativeText =
        @"Work through these steps in order:\n\n"
        @"1. Cable \u2014 try a different Lightning cable or USB port.\n\n"
        @"2. Trust prompt \u2014 unlock the iPad. If \u201cTrust This Computer?\u201d "
        @"appears, tap Trust.\n\n"
        @"3. Re-jailbreak \u2014 Ph\u0153nix is semi-untethered; the jailbreak is lost "
        @"on each reboot. Open the Ph\u0153nix app on the iPad again.\n\n"
        @"4. AFC2 missing \u2014 open Cydia and confirm \u201cApple File Conduit 2\u201d is "
        @"installed. If not, install it from BigBoss.\n\n"
        @"5. Denied trust \u2014 on the iPad:\n"
        @"       Settings \u203a General \u203a Transfer or Reset iPad\n"
        @"       \u2192 Reset Location & Privacy\n"
        @"   Reconnect and accept the new trust prompt.\n\n"
        @"6. Restart usbmuxd \u2014 in Terminal on your Mac:\n"
        @"       sudo pkill usbmuxd\n"
        @"   macOS restarts usbmuxd automatically. Reconnect the device.\n\n"
        @"7. Console.app \u2014 filter by \u201cusbmuxd\u201d or \u201clockdownd\u201d for low-level "
        @"error details.";
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"AFC2 Guide\u2026"];

    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self showAFC2InstallGuide:nil];
}

- (void)showHelp:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"How to Use AFC2 Utility";
    alert.informativeText =
        @"Browsing\n"
        @"  \u2022 Left panel \u2014 your Mac\u2019s file system.\n"
        @"  \u2022 Right panel \u2014 the iPad\u2019s file system.\n"
        @"  \u2022 Click \u25b6 to expand a directory on the iPad.\n"
        @"  \u2022 Double-click a Mac folder to navigate into it.\n\n"
        @"Transferring files\n"
        @"  \u2022 Drag files from the Mac panel \u2192 iPad panel to upload.\n"
        @"  \u2022 Right-click an iPad item \u2192 Download to save to your Mac.\n"
        @"  \u2022 \u2318U / \u2318D \u2014 Upload / Download from the File menu.\n\n"
        @"Managing iPad files\n"
        @"  \u2022 Right-click for: Download, Rename, Delete.\n"
        @"  \u2022 \u21e7\u2318N \u2014 New Folder at the current iPad path.\n"
        @"  \u2022 \u2191 \u2014 go up one directory.  \u21bb \u2014 refresh.\n\n"
        @"Transfers\n"
        @"  \u2022 Active and completed transfers appear in the bottom panel.\n"
        @"  \u2022 You can browse freely while transfers run in the background.\n"
        @"  \u2022 Double-click a failed transfer for error details.\n\n"
        @"Safety\n"
        @"  \u2022 Writes to /System, /bin, /usr, /sbin are always blocked.\n"
        @"  \u2022 Writes to /Library, /etc, /private require confirmation.";
    [alert addButtonWithTitle:@"Done"];
    [alert runModal];
}

@end
