#import "MacBrowserViewController.h"
#import "TransferEngine.h"
#import "iPadBrowserViewController.h"

static NSString *const kMacRowType = @"MacFileInfoPboardType";

@interface MacBrowserViewController () {
    NSOutlineView *_ov;
    NSScrollView  *_sv;
    NSTextField   *_pathLabel;
    NSMutableArray<NSURL *> *_items;   // contents of current directory
    NSString       *_currentPath;
}
@end

@implementation MacBrowserViewController

@synthesize currentPath = _currentPath;

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 600)];

    NSTextField *header = [NSTextField labelWithString:@"Mac"];
    header.font = [NSFont boldSystemFontOfSize:13];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _pathLabel = [NSTextField labelWithString:@"~"];
    _pathLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _pathLabel.textColor = [NSColor secondaryLabelColor];
    _pathLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *homeBtn = [NSButton buttonWithTitle:@"🏠" target:self action:@selector(goHome:)];
    NSButton *upBtn   = [NSButton buttonWithTitle:@"↑"  target:self action:@selector(goUp:)];
    homeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    upBtn.translatesAutoresizingMaskIntoConstraints   = NO;

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[header, homeBtn, upBtn]];
    toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.spacing = 8;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    _ov = [[NSOutlineView alloc] init];
    _ov.dataSource = self;
    _ov.delegate   = self;
    _ov.headerView = nil;
    _ov.rowHeight  = 20;
    _ov.allowsMultipleSelection = YES;
    _ov.target = self;
    _ov.doubleAction = @selector(doubleClicked:);

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_ov addTableColumn:col];
    _ov.outlineTableColumn = col;

    // Register as drag source
    [_ov setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [_ov setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _ov.menu = menu;

    _sv = [[NSScrollView alloc] init];
    _sv.documentView = _ov;
    _sv.hasVerticalScroller = YES;
    _sv.autohidesScrollers = YES;
    _sv.borderType = NSNoBorder;
    _sv.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:toolbar];
    [self.view addSubview:_pathLabel];
    [self.view addSubview:_sv];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_pathLabel.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:4],
        [_pathLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_pathLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_sv.topAnchor constraintEqualToAnchor:_pathLabel.bottomAnchor constant:4],
        [_sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self navigateTo:NSHomeDirectory()];
}

// ── Navigation ────────────────────────────────────────────────────────────────

- (void)navigateTo:(NSString *)path {
    _currentPath = path;
    _pathLabel.stringValue = [path stringByAbbreviatingWithTildeInPath];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:nil] ?: @[];

    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        [items addObject:[NSURL fileURLWithPath:[path stringByAppendingPathComponent:name]]];
    }
    [items sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSNumber *aDir, *bDir;
        [a getResourceValue:&aDir forKey:NSURLIsDirectoryKey error:nil];
        [b getResourceValue:&bDir forKey:NSURLIsDirectoryKey error:nil];
        if (aDir.boolValue != bDir.boolValue) return aDir.boolValue ? NSOrderedAscending : NSOrderedDescending;
        return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
    }];

    _items = items;
    [_ov reloadData];
}

- (IBAction)goHome:(id)sender { [self navigateTo:NSHomeDirectory()]; }
- (IBAction)goUp:(id)sender {
    if (!_currentPath || [_currentPath isEqualToString:@"/"]) return;
    [self navigateTo:[_currentPath stringByDeletingLastPathComponent]];
}

- (IBAction)doubleClicked:(id)sender {
    NSInteger row = _ov.clickedRow;
    if (row < 0 || row >= (NSInteger)_items.count) return;
    NSURL *url = _items[row];
    NSNumber *isDir;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    if (isDir.boolValue) [self navigateTo:url.path];
}

// ── NSOutlineViewDataSource ───────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    return item ? 0 : (NSInteger)_items.count;
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return NO; }
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    return _items[index];
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    NSURL *url = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"macCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSImageView *iv = [[NSImageView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv]; [cell addSubview:tf];
        cell.imageView = iv; cell.textField = tf;
        cell.identifier = @"macCell";
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:16],
            [iv.heightAnchor constraintEqualToConstant:16],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        ]];
    }
    cell.textField.stringValue = url.lastPathComponent;
    cell.imageView.image = [[NSWorkspace sharedWorkspace] iconForFile:url.path];
    return cell;
}

// ── Drag source (native NSFilenamesPboardType) ────────────────────────────────

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    return (NSURL *)item;
}

// ── Context menu ──────────────────────────────────────────────────────────────

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (_ov.selectedRow >= 0) {
        NSMenuItem *sendItem = [[NSMenuItem alloc] initWithTitle:@"Send to iPad"
                                                          action:@selector(sendToiPad:)
                                                   keyEquivalent:@""];
        sendItem.target = self;
        [menu addItem:sendItem];
    }
}

- (IBAction)sendToiPad:(id)sender {
    NSIndexSet *rows = _ov.selectedRowIndexes;
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSURL *url = _items[idx];
        NSNumber *isDir;
        [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
        if (isDir.boolValue) return;  // directory upload not yet supported in this menu

        NSString *devicePath = [self.partnerBrowser.currentPath stringByAppendingPathComponent:url.lastPathComponent];
        [self.transferEngine enqueueUploadFromLocalPath:url.path toDevicePath:devicePath];
    }];
}

@end
