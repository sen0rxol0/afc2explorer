#import "TransferPanelViewController.h"
#import "TransferEngine.h"

@interface TransferPanelViewController () <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) NSTableView   *tableView;
@property (nonatomic, strong) NSScrollView  *scrollView;
@property (nonatomic, strong) NSButton      *clearBtn;
@property (nonatomic, strong) NSButton      *cancelBtn;
@property (nonatomic, strong) NSArray<TransferItem *> *snapshot;

@end

@implementation TransferPanelViewController

- (void)setEngine:(TransferEngine *)engine {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_engine) [nc removeObserver:self];
    _engine = engine;
    if (engine) {
        [nc addObserver:self
               selector:@selector(itemUpdated:)
                   name:TransferEngineItemDidUpdateNotification
                 object:engine];
    }
    [self refresh];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 130)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

    NSTextField *header = [NSTextField labelWithString:@"Transfers"];
    header.font = [NSFont boldSystemFontOfSize:12];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _clearBtn  = [NSButton buttonWithTitle:@"Clear Done" target:self action:@selector(clearCompleted:)];
    _cancelBtn = [NSButton buttonWithTitle:@"Cancel All" target:self action:@selector(cancelAll:)];
    _clearBtn.translatesAutoresizingMaskIntoConstraints  = NO;
    _cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[header, _clearBtn, _cancelBtn]];
    toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.spacing = 8;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    _tableView = [[NSTableView alloc] init];
    _tableView.dataSource = self;
    _tableView.delegate   = self;
    _tableView.rowHeight  = 20;
    _tableView.headerView = nil;
    _tableView.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;

    NSTableColumn *nameCol  = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"File"; nameCol.width = 250;
    NSTableColumn *dirCol   = [[NSTableColumn alloc] initWithIdentifier:@"dir"];
    dirCol.title = @"Direction"; dirCol.width = 80;
    NSTableColumn *progCol  = [[NSTableColumn alloc] initWithIdentifier:@"progress"];
    progCol.title = @"Progress"; progCol.width = 200;
    NSTableColumn *stateCol = [[NSTableColumn alloc] initWithIdentifier:@"state"];
    stateCol.title = @"State"; stateCol.width = 100;

    [_tableView addTableColumn:nameCol];
    [_tableView addTableColumn:dirCol];
    [_tableView addTableColumn:progCol];
    [_tableView addTableColumn:stateCol];

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.borderType            = NSBezelBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:toolbar];
    [self.view addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [toolbar.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:6],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_scrollView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:4],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
    ]];
}

- (void)itemUpdated:(NSNotification *)note { [self refresh]; }

- (void)refresh {
    self.snapshot = self.engine ? self.engine.items : @[];
    [self.tableView reloadData];
}

// ── NSTableView DataSource ────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)self.snapshot.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    TransferItem *item = self.snapshot[row];
    NSString *ident    = col.identifier;

    if ([ident isEqualToString:@"progress"]) {
        NSProgressIndicator *pi = [[NSProgressIndicator alloc] init];
        pi.style            = NSProgressIndicatorStyleBar;
        pi.minValue         = 0; pi.maxValue = 1;
        pi.indeterminate    = NO;
        pi.doubleValue      = item.progress;
        return pi;
    }

    NSTextField *tf = [tv makeViewWithIdentifier:@"cell" owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier = @"cell";
    }

    if ([ident isEqualToString:@"name"])  tf.stringValue = item.displayName;
    if ([ident isEqualToString:@"dir"])   tf.stringValue = item.direction == TransferDirectionUpload ? @"↑ Upload" : @"↓ Download";
    if ([ident isEqualToString:@"state"]) tf.stringValue = [self labelForState:item.state];

    return tf;
}

- (NSString *)labelForState:(TransferItemState)state {
    switch (state) {
        case TransferItemStatePending:   return @"Pending";
        case TransferItemStateRunning:   return @"Running";
        case TransferItemStateCompleted: return @"Done ✓";
        case TransferItemStateFailed:    return @"Failed ✗";
        case TransferItemStateCancelled: return @"Cancelled";
    }
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (IBAction)clearCompleted:(id)sender {
    [self.engine clearCompleted];
    [self refresh];
}
- (IBAction)cancelAll:(id)sender {
    [self.engine cancelAll];
    [self refresh];
}

@end
