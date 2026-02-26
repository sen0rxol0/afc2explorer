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

    // Reconnect button (only visible on failure)
    NSButton *reconBtn = [NSButton buttonWithTitle:@"Reconnect"
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

    NSButton *guideBtn = [NSButton buttonWithTitle:@"Open AFC2 Installation Guide…"
                                            target:self
                                            action:@selector(showAFC2InstallGuide:)];
    guideBtn.bezelStyle = NSBezelStyleRounded;
    guideBtn.keyEquivalent = @"\r";
    guideBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *troubleBtn = [NSButton buttonWithTitle:@"Connection Troubleshooting…"
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
    [self presentConnectionError:err];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self updateStatusForState:DeviceConnectionStateDisconnected];
    });
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
            text     = @"Connecting…";
            self.reconnectButton.hidden = YES;
            break;
        case DeviceConnectionStateConnected: {
            dotColor = [NSColor systemGreenColor];
            DeviceManager *mgr = [DeviceManager sharedManager];
            text = [NSString stringWithFormat:@"Connected — %@", mgr.deviceName ?: @"iPad"];
            NSString *udid = mgr.deviceUDID;
            if (udid.length >= 12)
                detail = [NSString stringWithFormat:@"UDID  %@…%@",
                          [udid substringToIndex:8],
                          [udid substringFromIndex:udid.length - 4]];
            self.reconnectButton.hidden = YES;
            break;
        }
        case DeviceConnectionStateFailed:
            dotColor = [NSColor systemRedColor];
            text     = @"Connection failed";
            detail   = @"Check USB cable and AFC2 installation on device";
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
    NSString *hint   = @"";

    if (error.code == -3 ||
        [reason containsString:@"AFC2"] ||
        [reason containsString:@"service"]) {
        hint = @"\n\nThis usually means Apple File Conduit 2 is not installed on the device. "
               @"Use the Device › AFC2 Installation Guide to set it up.";
    } else if (error.code == -1 ||
               [reason containsString:@"lockdown"] ||
               [reason containsString:@"trust"]) {
        hint = @"\n\nUnlock the iPad and tap \"Trust This Computer\" when prompted, "
               @"then try reconnecting.";
    }

    alert.informativeText = [reason stringByAppendingString:hint];
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Open AFC2 Guide…"];

    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self showAFC2InstallGuide:nil];
}

// ── Menu action forwarding ────────────────────────────────────────────────────

- (void)triggerUpload   { [self.macVC  triggerUpload]; }
- (void)triggerDownload { [self.ipadVC downloadSelected:nil]; }
- (void)triggerNewFolder { [self.ipadVC newFolder:nil]; }
- (void)triggerRefresh  { [self.ipadVC refresh:nil]; }

- (IBAction)reconnect:(id)sender {
    [[DeviceManager sharedManager] disconnect];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
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
        @"  • iPad 2 running iOS 9.3.5\n"
        @"  • Device jailbroken with Phœnix\n\n"
        @"Steps\n"
        @"  1. Open Cydia on the iPad.\n"
        @"  2. Tap Search and type \"Apple File Conduit 2\".\n"
        @"  3. Tap the result, then tap Install → Confirm.\n"
        @"  4. When Cydia finishes, tap Restart Springboard.\n"
        @"  5. Plug the iPad into your Mac with a Lightning cable.\n"
        @"  6. Unlock the iPad — tap Trust if prompted.\n"
        @"  7. AFC2 Utility will detect the device automatically.\n\n"
        @"Source: BigBoss (pre-added in Cydia on iOS 9, no extra steps needed).";
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"Jailbreak Guide…"];
    [alert addButtonWithTitle:@"Troubleshooting…"];

    NSModalResponse r = [alert runModal];
    if (r == NSAlertSecondButtonReturn)  [self showJailbreakGuide:nil];
    if (r == NSAlertThirdButtonReturn)   [self showTroubleshooting:nil];
}

- (void)showJailbreakGuide:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"Jailbreaking iPad 2 on iOS 9.3.5";
    alert.informativeText =
        @"Phœnix is the recommended semi-untethered jailbreak for iPad 2 / iOS 9.3.5, "
        @"created by Siguza and tihmstar.\n\n"
        @"Steps\n"
        @"  1. Download the Phœnix IPA from phoenixpwn.com on your Mac.\n"
        @"  2. Install it onto the iPad using AltStore or Sideloadly.\n"
        @"  3. On the iPad: Settings › General › VPN & Device Management\n"
        @"     → trust your Apple ID's developer certificate.\n"
        @"  4. Open the Phœnix app on the iPad and follow the on-screen steps.\n"
        @"  5. After a successful jailbreak, Cydia appears on the home screen.\n\n"
        @"Note: Phœnix is semi-untethered — the jailbreak is lost on every reboot. "
        @"Re-run the Phœnix app (without reinstalling) each time the device restarts.";
    [alert addButtonWithTitle:@"Done"];
    [alert addButtonWithTitle:@"AFC2 Guide…"];

    if ([alert runModal] == NSAlertSecondButtonReturn)
        [self showAFC2InstallGuide:nil];
}

- (void)showTroubleshooting:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"Connection Troubleshooting";
    alert.informativeText =
        @"Work through these steps in order:\n\n"
        @"1. Cable  — try a different Lightning cable.\n\n"
        @"2. Trust prompt  — unlock the iPad. If \"Trust This Computer?\" "
        @"appears, tap Trust.\n\n"
        @"3. AFC2 missing  — open Cydia and confirm \"Apple File Conduit 2\" is "
        @"installed. If not, install it from BigBoss.\n\n"
        @"4. Re-jailbreak  — Phœnix is semi-untethered; the jailbreak is lost "
        @"on each reboot. Open the Phœnix app on the iPad again.\n\n"
        @"5. Restart usbmuxd  — in Terminal on your Mac:\n"
        @"       sudo pkill usbmuxd\n"
        @"   macOS restarts usbmuxd automatically. Reconnect the device.\n\n"
        @"6. Revoke trust  — on the iPad:\n"
        @"       Settings › General › Transfer or Reset iPad\n"
        @"       → Reset Location & Privacy\n"
        @"   Reconnect and accept the new trust prompt.\n\n"
        @"7. Console.app  — filter by \"usbmuxd\" or \"lockdownd\" for low-level "
        @"error details.";
    [alert addButtonWithTitle:@"Done"];
    [alert runModal];
}

- (void)showHelp:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleInformational;
    alert.messageText   = @"How to Use AFC2 Utility";
    alert.informativeText =
        @"Browsing\n"
        @"  • Left panel — your Mac's file system.\n"
        @"  • Right panel — the iPad's file system.\n"
        @"  • Click ▶ to expand a directory on the iPad.\n"
        @"  • Double-click a Mac folder to navigate into it.\n\n"
        @"Transferring files\n"
        @"  • Drag files from the Mac panel → iPad panel to upload.\n"
        @"  • Right-click an iPad item → Download to save to your Mac.\n"
        @"  • ⌘U / ⌘D — Upload / Download from the File menu.\n\n"
        @"Managing iPad files\n"
        @"  • Right-click for: Download, Rename, Delete.\n"
        @"  • ⇧⌘N — New Folder at the current iPad path.\n"
        @"  • ↑ — go up one directory.  ↻ — refresh.\n\n"
        @"Transfers\n"
        @"  • Active and completed transfers appear in the bottom panel.\n"
        @"  • You can browse freely while transfers run in the background.\n"
        @"  • Click a failed transfer for error details.\n\n"
        @"Safety\n"
        @"  • Writes to /System, /bin, /usr, /sbin are always blocked.\n"
        @"  • Writes to /Library, /etc, /private require confirmation.";
    [alert addButtonWithTitle:@"Done"];
    [alert runModal];
}

@end
