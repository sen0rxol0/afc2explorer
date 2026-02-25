#import "iPadBrowserViewController.h"
#import "AFC2Client.h"
#import "TransferEngine.h"
#import "FileSafetyLayer.h"
#import "MacBrowserViewController.h"

static NSString *const kRowType     = @"AFC2FileInfoPboardType";
static NSString *const kMacRowType  = @"MacFileInfoPboardType";

// ── Lazy directory node ───────────────────────────────────────────────────────

@interface DirectoryNode : NSObject
@property (nonatomic, strong) AFC2FileInfo             *info;
@property (nonatomic, strong) NSMutableArray<DirectoryNode *> *children;
@property (nonatomic, assign) BOOL                     loaded;
@property (nonatomic, assign) BOOL                     loading;
@end
@implementation DirectoryNode
- (instancetype)initWithInfo:(AFC2FileInfo *)info {
    if (!(self = [super init])) return nil;
    _info     = info;
    _children = [NSMutableArray array];
    return self;
}
@end

// ── View controller ───────────────────────────────────────────────────────────

@interface iPadBrowserViewController () {
    NSOutlineView  *_outlineView;
    NSScrollView   *_scrollView;
    NSTextField    *_pathLabel;
    NSString       *_currentPath;
    DirectoryNode  *_root;
    BOOL            _loading;
}
@end

@implementation iPadBrowserViewController

@synthesize currentPath = _currentPath;

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 600)];
    self.view.wantsLayer = YES;

    // Header
    NSTextField *header = [NSTextField labelWithString:@"iPad"];
    header.font = [NSFont boldSystemFontOfSize:13];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _pathLabel = [NSTextField labelWithString:@"/"];
    _pathLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _pathLabel.textColor = [NSColor secondaryLabelColor];
    _pathLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Toolbar buttons
    NSButton *upBtn     = [NSButton buttonWithTitle:@"↑" target:self action:@selector(goUp:)];
    NSButton *newFolBtn = [NSButton buttonWithTitle:@"New Folder" target:self action:@selector(newFolder:)];
    NSButton *refreshBtn = [NSButton buttonWithTitle:@"↻" target:self action:@selector(refresh:)];
    upBtn.translatesAutoresizingMaskIntoConstraints     = NO;
    newFolBtn.translatesAutoresizingMaskIntoConstraints = NO;
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[header, upBtn, newFolBtn, refreshBtn]];
    toolbar.orientation  = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.spacing      = 8;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    // Outline view
    _outlineView = [[NSOutlineView alloc] init];
    _outlineView.dataSource = self;
    _outlineView.delegate   = self;
    _outlineView.headerView = nil;
    _outlineView.rowHeight  = 20;
    _outlineView.allowsMultipleSelection = YES;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;

    // Drag & drop
    [_outlineView registerForDraggedTypes:@[NSFilenamesPboardType, kMacRowType]];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:YES];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationEvery forLocal:NO];

    // Context menu
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    _outlineView.menu = menu;

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.documentView   = _outlineView;
    _scrollView.hasVerticalScroller  = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers   = YES;
    _scrollView.borderType           = NSNoBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:toolbar];
    [self.view addSubview:_pathLabel];
    [self.view addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_pathLabel.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:4],
        [_pathLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_pathLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_scrollView.topAnchor constraintEqualToAnchor:_pathLabel.bottomAnchor constant:4],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

// ── Navigation ────────────────────────────────────────────────────────────────

- (void)navigateTo:(NSString *)path {
    if (!self.afc2Client) return;
    _currentPath = path;
    _pathLabel.stringValue = path;
    _loading = YES;

    __weak typeof(self) w = self;
    [self.afc2Client listDirectory:path completion:^(NSArray<AFC2FileInfo *> *items, NSError *error) {
        typeof(self) __strong s = w;
        if (!s) return;
        s->_loading = NO;
        if (error) { [s showError:error]; return; }
        [s rebuildRootWithItems:items path:path];
    }];
}

- (void)rebuildRootWithItems:(NSArray<AFC2FileInfo *> *)items path:(NSString *)path {
    _root = [[DirectoryNode alloc] init];
    _root.loaded = YES;
    for (AFC2FileInfo *info in items) {
        DirectoryNode *child = [[DirectoryNode alloc] initWithInfo:info];
        [_root.children addObject:child];
    }
    [_outlineView reloadData];
}

- (void)clearBrowser {
    _root = nil;
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
    if (node.info.isDirectory && !node.loaded && !node.loading) {
        [self loadChildrenOfNode:node];
    }
    return node.children.count;
}

- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item {
    return ((DirectoryNode *)item).info.isDirectory;
}

- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)index ofItem:(id)item {
    DirectoryNode *node = item ?: _root;
    return node.children[index];
}

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    DirectoryNode *node = item;
    NSTableCellView *cell = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        NSImageView *iv = [[NSImageView alloc] init];
        NSTextField *tf = [NSTextField labelWithString:@""];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv]; [cell addSubview:tf];
        cell.imageView = iv; cell.textField = tf;
        cell.identifier = @"cell";
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
    cell.textField.stringValue = node.info.name ?: @"";
    NSString *iconName = node.info.isDirectory ? NSImageNameFolder : NSImageNameMultipleDocuments;
    cell.imageView.image = [NSImage imageNamed:iconName];
    return cell;
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
            for (AFC2FileInfo *info in items) {
                DirectoryNode *child = [[DirectoryNode alloc] initWithInfo:info];
                [node.children addObject:child];
            }
        }
        typeof(self) __strong s = w;
        if (!s) return;
        [s->_outlineView reloadItem:node reloadChildren:YES];
    }];
}

// ── Drag source ───────────────────────────────────────────────────────────────

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(id)item {
    DirectoryNode *node = item;
    NSPasteboardItem *pbi = [[NSPasteboardItem alloc] init];
    [pbi setString:node.info.path forType:kRowType];
    return pbi;
}

// ── Drag destination (accept from Mac browser) ────────────────────────────────

- (NSDragOperation)outlineView:(NSOutlineView *)ov validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)idx {
    if ([[info.draggingPasteboard types] containsObject:NSFilenamesPboardType]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (BOOL)outlineView:(NSOutlineView *)ov acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)idx {
    NSArray<NSString *> *files = [info.draggingPasteboard propertyListForType:NSFilenamesPboardType];
    DirectoryNode *destNode = item;
    NSString *destDir = destNode ? destNode.info.path : _currentPath;

    for (NSString *localPath in files) {
        NSString *fileName   = localPath.lastPathComponent;
        NSString *devicePath = [destDir stringByAppendingPathComponent:fileName];

        if ([[FileSafetyLayer sharedLayer] requiresConfirmationForPath:devicePath]) {
            if (![[FileSafetyLayer sharedLayer] presentConfirmationForPath:devicePath action:@"Upload to"]) continue;
        }
        [self.transferEngine enqueueUploadFromLocalPath:localPath toDevicePath:devicePath];
    }
    return YES;
}

// ── Double-click to navigate into directories ─────────────────────────────────

- (void)outlineViewDoubleClicked:(NSOutlineView *)ov {
    // Handled by disclosure triangle for directories
}

// ── Context menu ──────────────────────────────────────────────────────────────

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    BOOL hasSelection = _outlineView.selectedRow >= 0;

    [menu addItemWithTitle:@"Download" action:@selector(downloadSelected:) keyEquivalent:@""];
    [menu addItemWithTitle:@"New Folder…" action:@selector(newFolder:) keyEquivalent:@""];
    if (hasSelection) {
        [menu addItem:[NSMenuItem separatorItem]];
        [menu addItemWithTitle:@"Rename…" action:@selector(renameSelected:) keyEquivalent:@""];
        [menu addItemWithTitle:@"Delete…"  action:@selector(deleteSelected:)  keyEquivalent:@""];
    }
    for (NSMenuItem *item in menu.itemArray) item.target = self;
}

- (IBAction)downloadSelected:(id)sender {
    NSIndexSet *rows = _outlineView.selectedRowIndexes;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO; panel.canChooseDirectories = YES;
    panel.prompt = @"Download Here";
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *destDir = panel.URL.path;

    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        DirectoryNode *node = [_outlineView itemAtRow:idx];
        if (!node.info.isDirectory) {
            NSString *localPath = [destDir stringByAppendingPathComponent:node.info.name];
            [self.transferEngine enqueueDownloadFromDevicePath:node.info.path toLocalPath:localPath];
        }
    }];
}

- (IBAction)deleteSelected:(id)sender {
    NSIndexSet *rows = _outlineView.selectedRowIndexes;
    NSMutableArray<DirectoryNode *> *toDelete = [NSMutableArray array];
    [rows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [toDelete addObject:[_outlineView itemAtRow:idx]];
    }];
    if (!toDelete.count) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText    = [NSString stringWithFormat:@"Delete %lu item(s)?", toDelete.count];
    alert.informativeText = @"This cannot be undone.";
    [alert addButtonWithTitle:@"Delete"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    for (DirectoryNode *node in toDelete) {
        [self.afc2Client deletePath:node.info.path recursive:node.info.isDirectory completion:^(NSError *err) {
            if (!err) [self navigateTo:_currentPath];
            else [self showError:err];
        }];
    }
}

- (IBAction)newFolder:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"New Folder Name:";
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,200,24)];
    alert.accessoryView = tf;
    [alert addButtonWithTitle:@"Create"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *name = tf.stringValue;
    if (!name.length) return;
    NSString *path = [_currentPath stringByAppendingPathComponent:name];
    [self.afc2Client createDirectory:path completion:^(NSError *err) {
        if (!err) [self navigateTo:_currentPath];
        else [self showError:err];
    }];
}

- (IBAction)renameSelected:(id)sender {
    NSInteger row = _outlineView.selectedRow;
    if (row < 0) return;
    DirectoryNode *node = [_outlineView itemAtRow:row];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Rename:";
    NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0,0,200,24)];
    tf.stringValue = node.info.name;
    alert.accessoryView = tf;
    [alert addButtonWithTitle:@"Rename"]; [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *newName = tf.stringValue;
    if (!newName.length || [newName isEqualToString:node.info.name]) return;
    NSString *newPath = [node.info.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:newName];
    [self.afc2Client renamePath:node.info.path to:newPath completion:^(NSError *err) {
        if (!err) [self navigateTo:_currentPath];
        else [self showError:err];
    }];
}

// ── Utilities ─────────────────────────────────────────────────────────────────

- (void)showError:(NSError *)error {
    NSAlert *a = [NSAlert alertWithError:error];
    [a runModal];
}

@end
