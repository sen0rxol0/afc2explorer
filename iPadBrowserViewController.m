#import "iPadBrowserViewController.h"
#import "AFC2Client.h"
#import "TransferEngine.h"
#import "FileSafetyLayer.h"
#import "MacBrowserViewController.h"
#include <libimobiledevice/afc.h>

static NSString *const kRowType    = @"AFC2FileInfoPboardType";
static NSString *const kMacRowType = @"MacFileInfoPboardType";

// ── Lazy directory node ───────────────────────────────────────────────────────

@interface DirectoryNode : NSObject
@property (nonatomic, strong) AFC2FileInfo              *info;
@property (nonatomic, strong) NSMutableArray<DirectoryNode *> *children;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;
@end

@implementation DirectoryNode
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _children = [NSMutableArray array];
    return self;
}
- (instancetype)initWithInfo:(AFC2FileInfo *)info {
    if (!(self = [self init])) return nil;
    _info = info;
    return self;
}
@end

// ── View controller ───────────────────────────────────────────────────────────

@interface iPadBrowserViewController () {
    NSOutlineView *_outlineView;
    NSScrollView  *_scrollView;
    NSTextField   *_pathLabel;
    NSString      *_currentPath;
    DirectoryNode *_root;
    BOOL           _loading;
    NSButton      *_upBtn;
    NSProgressIndicator *_spinner;
}
@end

@implementation iPadBrowserViewController

@synthesize currentPath = _currentPath;

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 600)];
    self.view.wantsLayer = YES;

    // ── Header bar ────────────────────────────────────────────────────────────
    NSTextField *header = [NSTextField labelWithString:@"iPad"];
    header.font = [NSFont boldSystemFontOfSize:13];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _pathLabel = [NSTextField labelWithString:@""];
    _pathLabel.font         = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _pathLabel.textColor    = [NSColor secondaryLabelColor];
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _pathLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _upBtn = [NSButton buttonWithTitle:@"↑" target:self action:@selector(goUp:)];
    NSButton *newFolBtn  = [NSButton buttonWithTitle:@"New Folder" target:self action:@selector(newFolder:)];
    NSButton *refreshBtn = [NSButton buttonWithTitle:@"↻" target:self action:@selector(refresh:)];
    for (NSButton *b in @[_upBtn, newFolBtn, refreshBtn]) {
        b.bezelStyle  = NSBezelStyleInline;
        b.controlSize = NSControlSizeSmall;
        b.translatesAutoresizingMaskIntoConstraints = NO;
    }

    _spinner = [[NSProgressIndicator alloc] init];
    _spinner.style         = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize   = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[header, _upBtn, newFolBtn, refreshBtn, _spinner]];
    toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.spacing     = 6;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    // ── Outline view ──────────────────────────────────────────────────────────
    _outlineView = [[NSOutlineView alloc] init];
    _outlineView.dataSource = self;
    _outlineView.delegate   = self;
    _outlineView.headerView = nil;
    _outlineView.rowHeight  = 22;
    _outlineView.allowsMultipleSelection = YES;

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.resizingMask = NSTableColumnAutoresizingMask;
    nameCol.width = 260;
    [_outlineView addTableColumn:nameCol];
    _outlineView.outlineTableColumn = nameCol;

    NSTableColumn *sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeCol.title = @"Size";
    sizeCol.width = 72;
    sizeCol.resizingMask = NSTableColumnNoResizing;
    [_outlineView addTableColumn:sizeCol];

    // Restore column header so users can see the size column
    NSTableHeaderView *headerView = [[NSTableHeaderView alloc] init];
    _outlineView.headerView = headerView;
    nameCol.title = @"Name";

    [_outlineView registerForDraggedTypes:@[NSPasteboardTypeFileURL, kMacRowType]];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:NO];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _outlineView.menu = menu;

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.documentView      = _outlineView;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.borderType            = NSNoBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:toolbar];
    [self.view addSubview:_pathLabel];
    [self.view addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor    constraintEqualToAnchor:self.view.topAnchor constant:8],
        [toolbar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_pathLabel.topAnchor    constraintEqualToAnchor:toolbar.bottomAnchor constant:3],
        [_pathLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_pathLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_scrollView.topAnchor    constraintEqualToAnchor:_pathLabel.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

// ── Navigation ────────────────────────────────────────────────────────────────

- (void)navigateTo:(NSString *)path {
    if (!self.afc2Client) return;
    _currentPath = path;
    _pathLabel.stringValue = path;
    _upBtn.enabled = ![@[@"/"] containsObject:path];
    _loading = YES;
    [_spinner startAnimation:nil];

    __weak typeof(self) w = self;
    [self.afc2Client listDirectory:path completion:^(NSArray<AFC2FileInfo *> *items, NSError *error) {
        typeof(self) __strong s = w;
        if (!s) return;
        s->_loading = NO;
        [s->_spinner stopAnimation:nil];
        if (error) {
            [s showError:error title:@"Could Not Open Directory"];
            return;
        }
        [s rebuildRootWithItems:items path:path];
    }];
}

- (void)rebuildRootWithItems:(NSArray<AFC2FileInfo *> *)items path:(NSString *)path {
    _root = [[DirectoryNode alloc] init];
    _root.loaded = YES;
    // AFC2Client.listDirectory already returns items sorted (dirs first, then alpha).
    for (AFC2FileInfo *info in items) {
        [_root.children addObject:[[DirectoryNode alloc] initWithInfo:info]];
    }
    [_outlineView reloadData];
}

- (void)clearBrowser {
    _root        = nil;
    _currentPath = nil;
    _pathLabel.stringValue = @"";
    [_outlineView reloadData];
}

- (IBAction)goUp:(id)sender {
    if (!_currentPath || [_currentPath isEqualToString:@"/"]) return;
    [self navigateTo:[_currentPath stringByDeletingLastPathComponent]];
}

- (IBAction)refresh:(id)sender {
    if (_currentPath) [self navigateTo:_currentPath];
}

// ── NSOutlineViewDataSource ───────────────────────────────────────────────────

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    DirectoryNode *node = item ?: _root;
    if (!node) return 0;
    if (node.info.isDirectory && !node.loaded && !node.loading)
        [self loadChildrenOfNode:node];
    return node.children.count;
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((DirectoryNode *)item).info.isDirectory;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    return (item ? (DirectoryNode *)item : _root).children[index];
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    DirectoryNode *node = item;

    if ([col.identifier isEqualToString:@"size"]) {
        NSTextField *tf = [ov makeViewWithIdentifier:@"sizeCell" owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.font       = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
            tf.textColor  = [NSColor secondaryLabelColor];
            tf.alignment  = NSTextAlignmentRight;
            tf.identifier = @"sizeCell";
        }
        tf.stringValue = node.info.isDirectory ? @"—" : [self humanReadableSize:node.info.fileSize];
        return tf;
    }

    // Name column
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"ipadCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSImageView *iv = [[NSImageView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:iv]; [cell addSubview:tf];
        cell.imageView = iv; cell.textField = tf;
        cell.identifier = @"ipadCell";
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor  constraintEqualToAnchor:cell.leadingAnchor constant:2],
            [iv.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor    constraintEqualToConstant:16],
            [iv.heightAnchor   constraintEqualToConstant:16],
            [tf.leadingAnchor  constraintEqualToAnchor:iv.trailingAnchor constant:4],
            [tf.centerYAnchor  constraintEqualToAnchor:cell.centerYAnchor],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
        ]];
    }
    cell.textField.stringValue = node.info.name ?: @"";
    cell.imageView.image = [NSImage imageNamed:node.info.isDirectory
                            ? NSImageNameFolder : NSImageNameMultipleDocuments];
    return cell;
}

- (NSString *)humanReadableSize:(long long)bytes {
    if (bytes < 1024)          return [NSString stringWithFormat:@"%lld B",  bytes];
    if (bytes < 1024 * 1024)   return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    if (bytes < 1024*1024*1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0*1024)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0*1024*1024)];
}

// ── Lazy loading ──────────────────────────────────────────────────────────────

- (void)loadChildrenOfNode:(DirectoryNode *)node {
    if (!self.afc2Client || node.loading) return;
    node.loading = YES;
    __weak typeof(self) w = self;
    [self.afc2Client listDirectory:node.info.path completion:^(NSArray<AFC2FileInfo *> *items, NSError *error) {
        node.loading = NO;
        node.loaded  = YES;
        if (!error) {
            NSArray *sorted = [items sortedArrayUsingComparator:^NSComparisonResult(AFC2FileInfo *a, AFC2FileInfo *b) {
                if (a.isDirectory != b.isDirectory)
                    return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
                return [a.name localizedCaseInsensitiveCompare:b.name];
            }];
            for (AFC2FileInfo *info in sorted)
                [node.children addObject:[[DirectoryNode alloc] initWithInfo:info]];
        }
        typeof(self) __strong s = w;
        if (!s) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [s->_outlineView reloadItem:node reloadChildren:YES];
        });
    }];
}

// ── Drag source ───────────────────────────────────────────────────────────────

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    DirectoryNode *node = item;
    NSPasteboardItem *pbi = [[NSPasteboardItem alloc] init];
    [pbi setString:node.info.path forType:kRowType];
    return pbi;
}

// ── Drag destination ──────────────────────────────────────────────────────────

- (NSDragOperation)outlineView:(NSOutlineView *)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)idx {
    return [[info.draggingPasteboard types] containsObject:NSPasteboardTypeFileURL]
           ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)ov
         acceptDrop:(id<NSDraggingInfo>)info
               item:(id)item
         childIndex:(NSInteger)idx {
    // Read dragged file URLs using the modern non-deprecated type.
    NSArray<NSURL *> *draggedURLs = [info.draggingPasteboard readObjectsForClasses:@[[NSURL class]]
                                        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSArray<NSString *> *files = [draggedURLs valueForKey:@"path"];
    DirectoryNode *destNode    = item;
    NSString *destDir          = destNode ? destNode.info.path : _currentPath;

    for (NSString *localPath in files) {
        NSString *devicePath = [destDir stringByAppendingPathComponent:localPath.lastPathComponent];
        if ([[FileSafetyLayer sharedLayer] requiresConfirmationForPath:devicePath]) {
            if (![[FileSafetyLayer sharedLayer] presentConfirmationForPath:devicePath action:@"Upload to"])
                continue;
        }
        [self.transferEngine enqueueUploadFromLocalPath:localPath toDevicePath:devicePath];
    }
    return YES;
}

// ── Context menu ──────────────────────────────────────────────────────────────

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row       = _outlineView.clickedRow;
    // FIX (BUG): use itemAtRow: to test for a real item — _root.children.count
    // only covers the top level; expanded subdirectory rows are beyond that count.
    DirectoryNode *node = (row >= 0) ? [_outlineView itemAtRow:row] : nil;
    BOOL hasItem        = (node != nil && node.info != nil);
    BOOL isDir          = node.info.isDirectory;

    if (hasItem) {
        NSMenuItem *dlItem = [menu addItemWithTitle:isDir ? @"Download Folder…" : @"Download…"
                                             action:@selector(downloadSelected:)
                                      keyEquivalent:@""];
        dlItem.target = self;

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *renameItem = [menu addItemWithTitle:@"Rename…"
                                                 action:@selector(renameSelected:)
                                          keyEquivalent:@""];
        renameItem.target = self;

        NSMenuItem *deleteItem = [menu addItemWithTitle:@"Move to Trash…"
                                                 action:@selector(deleteSelected:)
                                          keyEquivalent:@""];
        deleteItem.target = self;

        [menu addItem:[NSMenuItem separatorItem]];

        // Show file info
        NSMenuItem *infoItem = [menu addItemWithTitle:@"Get Info"
                                               action:@selector(showInfo:)
                                        keyEquivalent:@""];
        infoItem.target = self;
    }

    NSMenuItem *newFolderItem = [menu addItemWithTitle:@"New Folder…"
                                                action:@selector(newFolder:)
                                         keyEquivalent:@""];
    newFolderItem.target = self;

    NSMenuItem *refreshItem = [menu addItemWithTitle:@"Refresh"
                                              action:@selector(refresh:)
                                       keyEquivalent:@""];
    refreshItem.target = self;
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (IBAction)downloadSelected:(id)sender {
    NSIndexSet *rows = _outlineView.selectedRowIndexes;
    if (!rows.count) return;

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles       = NO;
    panel.canChooseDirectories = YES;
    panel.prompt   = @"Download Here";
    panel.message  = @"Choose a destination folder on your Mac:";
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *destDir = panel.URL.path;

    __block NSUInteger skipped = 0;
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        DirectoryNode *node = [_outlineView itemAtRow:idx];
        if (node.info.isDirectory) {
            skipped++;
        } else {
            NSString *local = [destDir stringByAppendingPathComponent:node.info.name];
            [self.transferEngine enqueueDownloadFromDevicePath:node.info.path toLocalPath:local];
        }
    }];
    // FIX (UX): inform the user when folders were skipped instead of silently doing nothing
    if (skipped > 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.alertStyle = NSAlertStyleInformational;
        a.messageText = skipped == 1 ? @"Folder Download Not Supported" : @"Folders Skipped";
        a.informativeText = [NSString stringWithFormat:
            @"%lu folder%@ cannot be downloaded directly. "
            @"Open the folder first and download the individual files inside it.",
            (unsigned long)skipped, skipped == 1 ? @"" : @"s"];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

- (IBAction)deleteSelected:(id)sender {
    NSIndexSet *rows = _outlineView.selectedRowIndexes;
    NSMutableArray<DirectoryNode *> *toDelete = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [toDelete addObject:[_outlineView itemAtRow:idx]];
    }];
    if (!toDelete.count) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    if (toDelete.count == 1) {
        alert.messageText     = [NSString stringWithFormat:@"Delete %@ ?", toDelete[0].info.name];
        alert.informativeText = @"This item will be permanently deleted from the device. "
                                @"This cannot be undone.";
    } else {
        alert.messageText     = [NSString stringWithFormat:@"Delete %lu items?", (unsigned long)toDelete.count];
        alert.informativeText = @"These items will be permanently deleted from the device. "
                                @"This cannot be undone.";
    }
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if (@available(macOS 12.0, *)) {
//        alert.buttons[0].hasDestructiveAction = YES;
    }
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    __block NSUInteger completed = 0;
    for (DirectoryNode *node in toDelete) {
        [self.afc2Client deletePath:node.info.path recursive:node.info.isDirectory
                         completion:^(NSError *err) {
            completed++;
            if (err) {
                [self showError:err title:[NSString stringWithFormat:
                    @"Could Not Delete \"%@\"", node.info.name]];
            }
            if (completed == toDelete.count)
                dispatch_async(dispatch_get_main_queue(), ^{ [self navigateTo:_currentPath]; });
        }];
    }
}

- (IBAction)newFolder:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText   = @"New Folder";
    alert.informativeText = [NSString stringWithFormat:@"Creating in: %@", _currentPath ?: @"/"];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    tf.placeholderString = @"Folder name";
    alert.accessoryView  = tf;
    [alert addButtonWithTitle:@"Create"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert.window makeFirstResponder:tf];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = [tf.stringValue stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceCharacterSet]];
    if (!name.length) return;

    NSString *path = [_currentPath stringByAppendingPathComponent:name];
    [self.afc2Client createDirectory:path completion:^(NSError *err) {
        if (err) [self showError:err title:@"Could Not Create Folder"];
        else     dispatch_async(dispatch_get_main_queue(), ^{ [self navigateTo:_currentPath]; });
    }];
}

- (IBAction)renameSelected:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    DirectoryNode *node = [_outlineView itemAtRow:row];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Rename \"%@\"", node.info.name];
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    tf.stringValue = node.info.name;
    alert.accessoryView = tf;
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert.window makeFirstResponder:tf];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    NSString *newName = [tf.stringValue stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
    if (!newName.length || [newName isEqualToString:node.info.name]) return;

    NSString *newPath = [node.info.path.stringByDeletingLastPathComponent
                         stringByAppendingPathComponent:newName];
    [self.afc2Client renamePath:node.info.path to:newPath completion:^(NSError *err) {
        if (err) [self showError:err title:[NSString stringWithFormat:
                    @"Could Not Rename \"%@\"", node.info.name]];
        else     dispatch_async(dispatch_get_main_queue(), ^{ [self navigateTo:_currentPath]; });
    }];
}

- (IBAction)showInfo:(id)sender {
    NSInteger row = _outlineView.clickedRow;
    if (row < 0) return;
    DirectoryNode *node = [_outlineView itemAtRow:row];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle  = NSAlertStyleInformational;
    alert.messageText = node.info.name;
    alert.informativeText = [NSString stringWithFormat:
        @"Path: %@\n"
        @"Type: %@\n"
        @"Size: %@",
        node.info.path,
        node.info.isDirectory ? @"Folder" : @"File",
        node.info.isDirectory ? @"—" : [self humanReadableSize:node.info.fileSize]];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

// ── Error presentation ────────────────────────────────────────────────────────

/// Serialised on main thread — only one alert shown at a time to avoid
/// stacking multiple modal dialogs if a burst of errors arrives.
- (void)showError:(NSError *)error title:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        // If a modal is already running (e.g. the user hasn't dismissed a
        // previous error), queue this one to run afterward instead of stacking.
        if ([NSApp modalWindow]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self showError:error title:title];
            });
            return;
        }

        NSString *reason = error.localizedDescription ?: @"An unknown error occurred.";
        NSString *hint   = @"";

        // Add actionable hints for common AFC errors.
        if ([error.domain isEqualToString:@"AFC2ClientErrorDomain"]) {
            switch ((afc_error_t)error.code) {
                case 8:  // AFC_E_PERM_DENIED
                    hint = @"\n\nThis path is protected. Writes to system directories "
                           @"(/System, /bin, /usr, /sbin) are blocked for safety.";
                    break;
                case 6:  // AFC_E_OBJECT_NOT_FOUND
                    hint = @"\n\nThe file or directory no longer exists. "
                           @"Try refreshing the iPad browser (\u21bb).";
                    break;
                case 7:  // AFC_E_OBJECT_EXISTS
                    hint = @"\n\nA file or folder with that name already exists. "
                           @"Rename or delete the existing item first.";
                    break;
                case -1: // invalidated (device disconnected mid-op)
                    hint = @"\n\nThe device was disconnected during the operation. "
                           @"Reconnect the iPad and try again.";
                    break;
                default:
                    break;
            }
        }

        NSAlert *a = [[NSAlert alloc] init];
        a.alertStyle    = NSAlertStyleWarning;
        a.messageText   = title;
        a.informativeText = [reason stringByAppendingString:hint];
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    });
}

// keep old call-site signature used internally
- (void)showError:(NSError *)error {
    [self showError:error title:@"Error"];
}

@end
