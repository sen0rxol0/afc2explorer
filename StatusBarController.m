#import "StatusBarController.h"
#import "AppDelegate.h"
#import "DeviceManager.h"
#import "MainWindowController.h"

@protocol _GuideProvider <NSObject>
- (void)showAFC2InstallGuide:(id)sender;
- (void)showJailbreakGuide:(id)sender;
- (void)showTroubleshooting:(id)sender;
- (void)showHelp:(id)sender;
@end

@interface StatusBarController ()
@property (nonatomic, strong) NSStatusItem *statusItem;
/// Last known state so we can render the menu without querying DeviceManager.
@property (nonatomic, assign) DeviceConnectionState lastState;
@property (nonatomic, copy)   NSString *lastDeviceName;
@end

@implementation StatusBarController

+ (instancetype)sharedController {
    static StatusBarController *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lastState = DeviceConnectionStateDisconnected;
    [self buildStatusItem];
    return self;
}

// ── Build the status item ─────────────────────────────────────────────────────

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];

    NSButton *btn = self.statusItem.button;
    if (@available(macOS 11.0, *)) {
//        btn.image = [NSImage imageWithSystemSymbolName:@"cable.connector"
//                                 accessibilityDescription:@"AFC2 Utility"];
//        btn.image.template = YES;   // adapts to dark/light menu bar
    } else {
        btn.title = @"AFC2";
    }
    btn.toolTip = @"AFC2 Utility \u2014 No device connected";

    [self rebuildMenu];
}

// ── Menu construction ─────────────────────────────────────────────────────────

- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] init];

    // ── Connection status header (non-clickable) ──────────────────────────────
    NSString *stateStr;
    switch (self.lastState) {
        case DeviceConnectionStateDisconnected:
            stateStr = @"No device connected";
            break;
        case DeviceConnectionStateConnecting:
            stateStr = @"Connecting\u2026";
            break;
        case DeviceConnectionStateConnected:
            stateStr = [NSString stringWithFormat:@"\u2705  %@", self.lastDeviceName ?: @"iPad"];
            break;
        case DeviceConnectionStateFailed:
            stateStr = @"\u26a0\ufe0f  Connection failed";
            break;
    }

    NSMenuItem *stateItem = [[NSMenuItem alloc] init];
    stateItem.attributedTitle = [[NSAttributedString alloc]
        initWithString:stateStr
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12
                                                               weight:NSFontWeightSemibold]}];
    stateItem.enabled = NO;
    [menu addItem:stateItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // ── Show main window ──────────────────────────────────────────────────────
    [[menu addItemWithTitle:@"Open AFC2 Utility"
                    action:@selector(openMainWindow:)
             keyEquivalent:@""] setTarget:self];

    [menu addItem:[NSMenuItem separatorItem]];

    // ── Device actions ────────────────────────────────────────────────────────
    NSMenuItem *reconItem = [menu addItemWithTitle:@"\u21ba  Reconnect Device"
                                            action:@selector(reconnect:)
                                     keyEquivalent:@""];
    reconItem.target  = self;
    // Only enable reconnect when not already connected.
    reconItem.enabled = (self.lastState != DeviceConnectionStateConnected &&
                         self.lastState != DeviceConnectionStateConnecting);

    [menu addItem:[NSMenuItem separatorItem]];

    // ── Setup guides — top-level items for quick access ───────────────────────
    [[menu addItemWithTitle:@"AFC2 Installation Guide\u2026"
                    action:@selector(showAFC2Guide:)
             keyEquivalent:@""] setTarget:self];

    [[menu addItemWithTitle:@"Jailbreak Guide (Ph\u0153nix)\u2026"
                    action:@selector(showJailbreakGuide:)
             keyEquivalent:@""] setTarget:self];

    [[menu addItemWithTitle:@"Connection Troubleshooting\u2026"
                    action:@selector(showTroubleshooting:)
             keyEquivalent:@""] setTarget:self];

    [menu addItem:[NSMenuItem separatorItem]];

    // ── Help & Quit ───────────────────────────────────────────────────────────
    [[menu addItemWithTitle:@"Help\u2026"
                    action:@selector(showHelp:)
             keyEquivalent:@""] setTarget:self];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Quit AFC2 Utility"
                   action:@selector(terminate:)
            keyEquivalent:@"q"];

    self.statusItem.menu = menu;
}

// ── State update (called by AppDelegate on device notifications) ──────────────

- (void)updateConnectionState:(DeviceConnectionState)state deviceName:(NSString *)name {
    self.lastState      = state;
    self.lastDeviceName = name;

    NSButton *btn = self.statusItem.button;
    switch (state) {
        case DeviceConnectionStateDisconnected:
            btn.toolTip = @"AFC2 Utility \u2014 No device connected";
            if (@available(macOS 11.0, *))
                btn.contentTintColor = nil;
            break;
        case DeviceConnectionStateConnecting:
            btn.toolTip = @"AFC2 Utility \u2014 Connecting\u2026";
            if (@available(macOS 11.0, *))
                btn.contentTintColor = [NSColor systemYellowColor];
            break;
        case DeviceConnectionStateConnected:
            btn.toolTip = [NSString stringWithFormat:@"AFC2 Utility \u2014 Connected to %@",
                           name ?: @"iPad"];
            if (@available(macOS 11.0, *))
                btn.contentTintColor = [NSColor systemGreenColor];
            break;
        case DeviceConnectionStateFailed:
            btn.toolTip = @"AFC2 Utility \u2014 Connection failed";
            if (@available(macOS 11.0, *))
                btn.contentTintColor = [NSColor systemRedColor];
            break;
    }
    [self rebuildMenu];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (IBAction)openMainWindow:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    [appDelegate.mainWindowController showWindow:nil];
}

- (IBAction)reconnect:(id)sender {
    [[DeviceManager sharedManager] disconnect];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DeviceManager sharedManager] startMonitoring];
    });
}

// Guide actions delegate to MainWindowController through AppDelegate
- (id<_GuideProvider>)_guideTarget {
    return (id<_GuideProvider>)((AppDelegate *)NSApp.delegate).mainWindowController;
}

- (IBAction)showAFC2Guide:(id)sender      { [[self _guideTarget] showAFC2InstallGuide:sender]; }
- (IBAction)showJailbreakGuide:(id)sender { [[self _guideTarget] showJailbreakGuide:sender]; }
- (IBAction)showTroubleshooting:(id)sender { [[self _guideTarget] showTroubleshooting:sender]; }
- (IBAction)showHelp:(id)sender            { [[self _guideTarget] showHelp:sender]; }

@end
