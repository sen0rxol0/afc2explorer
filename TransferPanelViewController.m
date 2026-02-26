#import "TransferPanelViewController.h"
#import "TransferEngine.h"

@interface TransferPanelViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView              *tableView;
@property (nonatomic, strong) NSScrollView             *scrollView;
@property (nonatomic, strong) NSButton                 *clearBtn;
@property (nonatomic, strong) NSButton                 *cancelBtn;
@property (nonatomic, strong) NSTextField              *summaryLabel;
@property (nonatomic, strong) NSArray<TransferItem *>  *snapshot;
@end

@implementation TransferPanelViewController

- (void)setEngine:(TransferEngine *)engine {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_engine) [nc removeObserver:self];
    _engine = engine;
    if (engine) {
        [nc addObserver:self selector:@selector(itemUpdated:)
                   name:TransferEngineItemDidUpdateNotification object:engine];
    }
    [self refresh];
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 130)];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = [NSColor controlBackgroundColor].CGColor;

    // Top separator
    NSBox *sep = [[NSBox alloc] init];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;

    // Header
    NSTextField *header = [NSTextField labelWithString:@"Transfers"];
    header.font = [NSFont boldSystemFontOfSize:12];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    // Summary label (e.g. "2 running, 4 done, 1 failed")
    _summaryLabel = [NSTextField labelWithString:@""];
    _summaryLabel.font      = [NSFont systemFontOfSize:11];
    _summaryLabel.textColor = [NSColor secondaryLabelColor];
    _summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _clearBtn  = [NSButton buttonWithTitle:@"Clear Completed" target:self action:@selector(clearCompleted:)];
    _cancelBtn = [NSButton buttonWithTitle:@"Cancel All"      target:self action:@selector(cancelAll:)];
    for (NSButton *b in @[_clearBtn, _cancelBtn]) {
        b.bezelStyle  = NSBezelStyleInline;
        b.controlSize = NSControlSizeSmall;
        b.translatesAutoresizingMaskIntoConstraints = NO;
    }

    NSStackView *toolbar = [NSStackView stackViewWithViews:@[header, _summaryLabel]];
    toolbar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    toolbar.spacing     = 10;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    // Table
    _tableView = [[NSTableView alloc] init];
    _tableView.dataSource    = self;
    _tableView.delegate      = self;
    _tableView.rowHeight     = 20;
    _tableView.headerView    = nil;
    _tableView.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
    _tableView.target        = self;
    _tableView.doubleAction  = @selector(showItemError:);

    NSTableColumn *dirCol   = [[NSTableColumn alloc] initWithIdentifier:@"dir"];
    dirCol.width = 24; dirCol.resizingMask = NSTableColumnNoResizing;
    NSTableColumn *nameCol  = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.width = 260;
    NSTableColumn *progCol  = [[NSTableColumn alloc] initWithIdentifier:@"progress"];
    progCol.width = 180; progCol.resizingMask = NSTableColumnNoResizing;
    NSTableColumn *stateCol = [[NSTableColumn alloc] initWithIdentifier:@"state"];
    stateCol.width = 90; stateCol.resizingMask = NSTableColumnNoResizing;
    NSTableColumn *sizeCol  = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    sizeCol.width = 70; sizeCol.resizingMask = NSTableColumnNoResizing;

    for (NSTableColumn *c in @[dirCol, nameCol, progCol, stateCol, sizeCol])
        [_tableView addTableColumn:c];

    _scrollView = [[NSScrollView alloc] init];
    _scrollView.documentView      = _tableView;
    _scrollView.hasVerticalScroller   = YES;
    _scrollView.autohidesScrollers    = YES;
    _scrollView.borderType            = NSBezelBorder;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:sep];
    [self.view addSubview:toolbar];
    [self.view addSubview:_clearBtn];
    [self.view addSubview:_cancelBtn];
    [self.view addSubview:_scrollView];

    [NSLayoutConstraint activateConstraints:@[
        [sep.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [toolbar.topAnchor    constraintEqualToAnchor:sep.bottomAnchor constant:5],
        [toolbar.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_summaryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_clearBtn.leadingAnchor constant:-8],

        [_cancelBtn.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [_cancelBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_clearBtn.centerYAnchor  constraintEqualToAnchor:toolbar.centerYAnchor],
        [_clearBtn.trailingAnchor constraintEqualToAnchor:_cancelBtn.leadingAnchor constant:-6],

        [_scrollView.topAnchor    constraintEqualToAnchor:toolbar.bottomAnchor constant:4],
        [_scrollView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:4],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-4],
        [_scrollView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
    ]];
}

// ── Data ──────────────────────────────────────────────────────────────────────

- (void)itemUpdated:(NSNotification *)note { [self refresh]; }

- (void)refresh {
    self.snapshot = self.engine ? self.engine.items : @[];
    [self.tableView reloadData];
    [self updateSummary];
}

- (void)updateSummary {
    if (!self.snapshot.count) {
        _summaryLabel.stringValue = @"No transfers";
        _clearBtn.enabled  = NO;
        _cancelBtn.enabled = NO;
        return;
    }
    NSUInteger running = 0, done = 0, failed = 0, pending = 0;
    for (TransferItem *it in self.snapshot) {
        switch (it.state) {
            case TransferItemStateRunning:   running++;  break;
            case TransferItemStateCompleted: done++;     break;
            case TransferItemStateFailed:    failed++;   break;
            case TransferItemStatePending:   pending++;  break;
            default: break;
        }
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (running)  [parts addObject:[NSString stringWithFormat:@"%lu running",  (unsigned long)running]];
    if (pending)  [parts addObject:[NSString stringWithFormat:@"%lu pending",  (unsigned long)pending]];
    if (done)     [parts addObject:[NSString stringWithFormat:@"%lu done",     (unsigned long)done]];
    if (failed)   [parts addObject:[NSString stringWithFormat:@"%lu failed",   (unsigned long)failed]];
    _summaryLabel.stringValue  = [parts componentsJoinedByString:@"  ·  "];
    _summaryLabel.textColor    = failed ? [NSColor systemRedColor] : [NSColor secondaryLabelColor];
    _clearBtn.enabled  = (done > 0 || failed > 0);
    _cancelBtn.enabled = (running > 0 || pending > 0);
}

// ── NSTableView ───────────────────────────────────────────────────────────────

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)self.snapshot.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    TransferItem *item = self.snapshot[row];
    NSString     *ident = col.identifier;

    // Progress bar column
    if ([ident isEqualToString:@"progress"]) {
        NSProgressIndicator *pi = [[NSProgressIndicator alloc] init];
        pi.style        = NSProgressIndicatorStyleBar;
        pi.minValue     = 0;
        pi.maxValue     = 1;
        pi.indeterminate = (item.state == TransferItemStateRunning && item.progress < 0.01);
        pi.doubleValue  = item.progress;
        if (pi.indeterminate) [pi startAnimation:nil];
        return pi;
    }

    // Direction icon column
    if ([ident isEqualToString:@"dir"]) {
        NSTextField *tf = [tv makeViewWithIdentifier:@"dirCell" owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.alignment  = NSTextAlignmentCenter;
            tf.identifier = @"dirCell";
        }
        tf.stringValue = (item.direction == TransferDirectionUpload) ? @"↑" : @"↓";
        tf.textColor   = (item.direction == TransferDirectionUpload)
                         ? [NSColor systemBlueColor] : [NSColor systemGreenColor];
        return tf;
    }

    // Text columns
    NSTextField *tf = [tv makeViewWithIdentifier:@"cell" owner:self];
    if (!tf) {
        tf = [NSTextField labelWithString:@""];
        tf.identifier    = @"cell";
        tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }

    if ([ident isEqualToString:@"name"]) {
        tf.stringValue = item.displayName;
        tf.toolTip     = item.sourcePath;
    }
    if ([ident isEqualToString:@"state"]) {
        tf.stringValue = [self labelForState:item.state];
        tf.textColor   = [self colorForState:item.state];
    }
    if ([ident isEqualToString:@"size"]) {
        tf.stringValue  = (item.progress > 0 && item.state == TransferItemStateRunning)
                          ? [NSString stringWithFormat:@"%.0f%%", item.progress * 100]
                          : @"";
        tf.textColor    = [NSColor secondaryLabelColor];
        tf.alignment    = NSTextAlignmentRight;
    }
    return tf;
}

// Row tint for failed items
- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    if (row >= (NSInteger)self.snapshot.count) return nil;
    TransferItem *item = self.snapshot[row];
    if (item.state == TransferItemStateFailed) {
        NSTableRowView *rv = [[NSTableRowView alloc] init];
        rv.backgroundColor = [[NSColor systemRedColor] colorWithAlphaComponent:0.07];
        return rv;
    }
    return nil;
}

- (NSString *)labelForState:(TransferItemState)state {
    switch (state) {
        case TransferItemStatePending:   return @"Waiting";
        case TransferItemStateRunning:   return @"Transferring";
        case TransferItemStateCompleted: return @"Done ✓";
        case TransferItemStateFailed:    return @"Failed ✗";
        case TransferItemStateCancelled: return @"Cancelled";
    }
}

- (NSColor *)colorForState:(TransferItemState)state {
    switch (state) {
        case TransferItemStateCompleted: return [NSColor systemGreenColor];
        case TransferItemStateFailed:    return [NSColor systemRedColor];
        case TransferItemStateCancelled: return [NSColor secondaryLabelColor];
        default:                         return [NSColor labelColor];
    }
}

// ── Double-click: show error for failed items ─────────────────────────────────

- (IBAction)showItemError:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.snapshot.count) return;
    TransferItem *item = self.snapshot[row];
    if (item.state != TransferItemStateFailed || !item.error) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleWarning;
    alert.messageText   = [NSString stringWithFormat:@"Transfer Failed: %@", item.displayName];
    alert.informativeText = [NSString stringWithFormat:
        @"%@\n\nSource: %@\nDestination: %@",
        item.error.localizedDescription ?: @"Unknown error",
        item.sourcePath,
        item.destinationPath];
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

// ── Actions ───────────────────────────────────────────────────────────────────

- (IBAction)clearCompleted:(id)sender {
    [self.engine clearCompleted];
    [self refresh];
}

- (IBAction)cancelAll:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle    = NSAlertStyleWarning;
    alert.messageText   = @"Cancel All Transfers?";
    alert.informativeText = @"All running and pending transfers will be stopped.";
    [alert addButtonWithTitle:@"Cancel All"];
    [alert addButtonWithTitle:@"Keep Going"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self.engine cancelAll];
    [self refresh];
}

@end
