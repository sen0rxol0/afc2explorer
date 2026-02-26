#import "AppDelegate.h"
#import "MainWindowController.h"
#import "DeviceManager.h"

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMenuBar];
    self.mainWindowController = [[MainWindowController alloc] init];
    [self.mainWindowController showWindow:nil];
    [[DeviceManager sharedManager] startMonitoring];
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
    [[fileMenu addItemWithTitle:@"Upload Files to iPad…"
                         action:@selector(triggerUpload:)
                  keyEquivalent:@"u"] setTarget:self];
    [[fileMenu addItemWithTitle:@"Download Selected from iPad…"
                         action:@selector(triggerDownload:)
                  keyEquivalent:@"d"] setTarget:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [[fileMenu addItemWithTitle:@"New Folder on iPad…"
                         action:@selector(triggerNewFolder:)
                  keyEquivalent:@"N"] setTarget:self];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [[fileMenu addItemWithTitle:@"Refresh iPad"
                         action:@selector(triggerRefresh:)
                  keyEquivalent:@"r"] setTarget:self];
    fileItem.submenu = fileMenu;
    [mainMenu addItem:fileItem];

    // Device menu
    NSMenuItem *deviceItem = [[NSMenuItem alloc] init];
    NSMenu *deviceMenu = [[NSMenu alloc] initWithTitle:@"Device"];
    [[deviceMenu addItemWithTitle:@"Reconnect"
                           action:@selector(reconnectDevice:)
                    keyEquivalent:@"k"] setTarget:self];
    [deviceMenu addItem:[NSMenuItem separatorItem]];
    [[deviceMenu addItemWithTitle:@"AFC2 Installation Guide…"
                           action:@selector(showAFC2Guide:)
                    keyEquivalent:@""] setTarget:self];
    [[deviceMenu addItemWithTitle:@"Jailbreak Guide…"
                           action:@selector(showJailbreakGuide:)
                    keyEquivalent:@""] setTarget:self];
    [deviceMenu addItem:[NSMenuItem separatorItem]];
    [[deviceMenu addItemWithTitle:@"Connection Troubleshooting…"
                           action:@selector(showTroubleshooting:)
                    keyEquivalent:@""] setTarget:self];
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
    [[helpMenu addItemWithTitle:@"AFC2 Utility Help"
                         action:@selector(showHelp:)
                  keyEquivalent:@"?"] setTarget:self];
    helpItem.submenu = helpMenu;
    [NSApp setHelpMenu:helpMenu];
    [mainMenu addItem:helpItem];

    [NSApp setMainMenu:mainMenu];
}

// ── Menu actions (forward to main window controller) ──────────────────────────

- (IBAction)triggerUpload:(id)sender    { [self.mainWindowController triggerUpload]; }
- (IBAction)triggerDownload:(id)sender  { [self.mainWindowController triggerDownload]; }
- (IBAction)triggerNewFolder:(id)sender { [self.mainWindowController triggerNewFolder]; }
- (IBAction)triggerRefresh:(id)sender   { [self.mainWindowController triggerRefresh]; }

- (IBAction)reconnectDevice:(id)sender {
    [[DeviceManager sharedManager] disconnect];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[DeviceManager sharedManager] startMonitoring];
    });
}

- (IBAction)showAFC2Guide:(id)sender        { [self.mainWindowController showAFC2InstallGuide:nil]; }
- (IBAction)showJailbreakGuide:(id)sender   { [self.mainWindowController showJailbreakGuide:nil]; }
- (IBAction)showTroubleshooting:(id)sender  { [self.mainWindowController showTroubleshooting:nil]; }
- (IBAction)showHelp:(id)sender             { [self.mainWindowController showHelp:nil]; }

@end
