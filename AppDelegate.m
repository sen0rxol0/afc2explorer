#import "AppDelegate.h"
#import "MainWindowController.h"
#import "DeviceManager.h"
#import "StatusBarController.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenuBar];
    [StatusBarController sharedController];   // create menu bar icon early
    self.mainWindowController = [[MainWindowController alloc] init];
    [self.mainWindowController showWindow:nil];
    [[DeviceManager sharedManager] startMonitoring];

    // Keep the menu bar status item in sync with device state
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(_deviceStateChanged:)
               name:DeviceDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceStateChanged:)
               name:DeviceDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceStateChanged:)
               name:DeviceConnectionFailedNotification object:nil];
    [nc addObserver:self selector:@selector(_deviceStateChanged:)
               name:DeviceConnectionRetryingNotification object:nil];
}

- (void)_deviceStateChanged:(NSNotification *)note {
    DeviceManager *mgr = [DeviceManager sharedManager];
    [[StatusBarController sharedController]
        updateConnectionState:mgr.connectionState deviceName:mgr.deviceName];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[DeviceManager sharedManager] stopMonitoring];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// ── Menu bar ──────────────────────────────────────────────────────────────────

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"About AFC2 Utility"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Preferences\u2026" action:nil keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide AFC2 Utility" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others"
                                                action:@selector(hideOtherApplications:)
                                         keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit AFC2 Utility" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];

    // File menu
    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    NSMenuItem *uploadItem = [fileMenu addItemWithTitle:@"Upload Files to iPad\u2026"
                                                 action:@selector(triggerUpload:)
                                          keyEquivalent:@"u"];
    uploadItem.target = self;

    NSMenuItem *downloadItem = [fileMenu addItemWithTitle:@"Download Selected from iPad\u2026"
                                                   action:@selector(triggerDownload:)
                                            keyEquivalent:@"d"];
    downloadItem.target = self;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *newFolderItem = [fileMenu addItemWithTitle:@"New Folder on iPad\u2026"
                                                    action:@selector(triggerNewFolder:)
                                             keyEquivalent:@"N"];
    newFolderItem.target = self;

    [fileMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [fileMenu addItemWithTitle:@"Refresh iPad"
                                                  action:@selector(triggerRefresh:)
                                           keyEquivalent:@"r"];
    refreshItem.target = self;

    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];

    // Device menu
    NSMenuItem *deviceItem = [[NSMenuItem alloc] init];
    NSMenu *deviceMenu = [[NSMenu alloc] initWithTitle:@"Device"];

    NSMenuItem *reconItem = [deviceMenu addItemWithTitle:@"Reconnect"
                                                  action:@selector(reconnectDevice:)
                                           keyEquivalent:@"k"];
    reconItem.target = self;

    [deviceMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *afc2Item = [deviceMenu addItemWithTitle:@"AFC2 Installation Guide\u2026"
                                                 action:@selector(showAFC2Guide:)
                                          keyEquivalent:@""];
    afc2Item.target = self;

    NSMenuItem *jbItem = [deviceMenu addItemWithTitle:@"Jailbreak Guide (Ph\u0153nix)\u2026"
                                               action:@selector(showJailbreakGuide:)
                                        keyEquivalent:@""];
    jbItem.target = self;

    [deviceMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *troubleItem = [deviceMenu addItemWithTitle:@"Connection Troubleshooting\u2026"
                                                    action:@selector(showTroubleshooting:)
                                             keyEquivalent:@""];
    troubleItem.target = self;

    deviceItem.submenu = deviceMenu;
    [mainMenu addItem:deviceItem];

    // Window menu
    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom"     action:@selector(performZoom:)        keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    [NSApp setWindowsMenu:windowMenu];
    windowItem.submenu = windowMenu;
    [mainMenu addItem:windowItem];

    // Help menu
    NSMenuItem *helpItem = [[NSMenuItem alloc] init];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *helpMenuItem = [helpMenu addItemWithTitle:@"AFC2 Utility Help"
                                                   action:@selector(showHelp:)
                                            keyEquivalent:@"?"];
    helpMenuItem.target = self;
    helpItem.submenu = helpMenu;
    [NSApp setHelpMenu:helpMenu];
    [mainMenu addItem:helpItem];

    [NSApp setMainMenu:mainMenu];
}

// ── Menu validation ───────────────────────────────────────────────────────────
// File-menu actions that require an active device connection should only be
// enabled when the device is connected.

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL action = item.action;
    BOOL isConnected = ([DeviceManager sharedManager].connectionState == DeviceConnectionStateConnected);

    if (action == @selector(triggerUpload:) ||
        action == @selector(triggerDownload:) ||
        action == @selector(triggerNewFolder:) ||
        action == @selector(triggerRefresh:)) {
        return isConnected;
    }

    if (action == @selector(reconnectDevice:)) {
        // Enable reconnect whenever we are NOT currently connected.
        return !isConnected;
    }

    return YES;
}

// ── Menu actions (forward to main window controller) ──────────────────────────

- (IBAction)triggerUpload:(id)sender    { [self.mainWindowController triggerUpload]; }
- (IBAction)triggerDownload:(id)sender  { [self.mainWindowController triggerDownload]; }
- (IBAction)triggerNewFolder:(id)sender { [self.mainWindowController triggerNewFolder]; }
- (IBAction)triggerRefresh:(id)sender   { [self.mainWindowController triggerRefresh]; }

- (IBAction)reconnectDevice:(id)sender {
    [[DeviceManager sharedManager] disconnect];
    // FIX (UX): use a slightly longer delay so usbmuxd has time to stabilise
    // before we re-subscribe and re-probe for the device.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DeviceManager sharedManager] startMonitoring];
    });
}

- (IBAction)showAFC2Guide:(id)sender        { [self.mainWindowController showAFC2InstallGuide:nil]; }
- (IBAction)showJailbreakGuide:(id)sender   { [self.mainWindowController showJailbreakGuide:nil]; }
- (IBAction)showTroubleshooting:(id)sender  { [self.mainWindowController showTroubleshooting:nil]; }
- (IBAction)showHelp:(id)sender             { [self.mainWindowController showHelp:nil]; }

@end
