#import "TransferEngine.h"
#import "AFC2Client.h"

NSNotificationName const TransferEngineItemDidUpdateNotification = @"TransferEngineItemDidUpdateNotification";
NSString *const TransferEngineItemKey = @"TransferEngineItemKey";

static const int kMaxRetries = 3;

// ── Mutable TransferItem ──────────────────────────────────────────────────────

@interface TransferItem ()
@property (nonatomic, readwrite) TransferItemState  state;
@property (nonatomic, readwrite) double             progress;
@property (nonatomic, readwrite, nullable) NSError *error;
@property (nonatomic, copy) dispatch_block_t cancelBlock;
@end

@implementation TransferItem

- (instancetype)initWithDirection:(TransferDirection)direction
                       sourcePath:(NSString *)src
                  destinationPath:(NSString *)dst {
    if (!(self = [super init])) return nil;
    _identifier      = [NSUUID UUID];
    _direction       = direction;
    _sourcePath      = src.copy;
    _destinationPath = dst.copy;
    _state           = TransferItemStatePending;
    _displayName     = src.lastPathComponent;
    return self;
}

- (void)cancel {
    self.state = TransferItemStateCancelled;
    if (self.cancelBlock) self.cancelBlock();
}

@end

// ── TransferEngine ────────────────────────────────────────────────────────────

@interface TransferEngine ()
@property (nonatomic, strong) AFC2Client           *client;
@property (nonatomic, strong) NSOperationQueue     *queue;
@property (nonatomic, strong) NSMutableArray<TransferItem *> *mutableItems;
@end

@implementation TransferEngine

- (instancetype)initWithAFC2Client:(AFC2Client *)client {
    if (!(self = [super init])) return nil;
    _client       = client;
    _mutableItems = [NSMutableArray array];
    _queue        = [[NSOperationQueue alloc] init];
    _queue.maxConcurrentOperationCount = 1;   // serial — one transfer at a time for USB
    _queue.qualityOfService            = NSQualityOfServiceUtility;
    _queue.name                        = @"com.afc2util.transfers";
    return self;
}

- (NSArray<TransferItem *> *)items {
    @synchronized(self) { return [self.mutableItems copy]; }
}

// ── Enqueue ───────────────────────────────────────────────────────────────────

- (TransferItem *)enqueueUploadFromLocalPath:(NSString *)localPath toDevicePath:(NSString *)devicePath {
    TransferItem *item = [[TransferItem alloc] initWithDirection:TransferDirectionUpload
                                                      sourcePath:localPath
                                                 destinationPath:devicePath];
    [self addAndSchedule:item];
    return item;
}

- (TransferItem *)enqueueDownloadFromDevicePath:(NSString *)devicePath toLocalPath:(NSString *)localPath {
    TransferItem *item = [[TransferItem alloc] initWithDirection:TransferDirectionDownload
                                                      sourcePath:devicePath
                                                 destinationPath:localPath];
    [self addAndSchedule:item];
    return item;
}

- (void)addAndSchedule:(TransferItem *)item {
    @synchronized(self) { [self.mutableItems addObject:item]; }
    [self notifyUpdate:item];

    __weak typeof(self) wself = self;
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        [wself executeItem:item retryCount:0];
    }];

    __weak NSBlockOperation *wop = op;
    item.cancelBlock = ^{ [wop cancel]; };
    [self.queue addOperation:op];
}

// ── Execution (runs on NSOperationQueue thread) ───────────────────────────────

- (void)executeItem:(TransferItem *)item retryCount:(int)retry {
    if (item.state == TransferItemStateCancelled) return;

    item.state    = TransferItemStateRunning;
    item.progress = 0;
    [self notifyUpdate:item];

    __weak typeof(self) wself = self;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSError *resultError = nil;

    AFC2ProgressHandler progressHandler = ^(int64_t done, int64_t total) {
        item.progress = total > 0 ? (double)done / total : 0;
        [wself notifyUpdate:item];
    };

    AFC2CompletionHandler completion = ^(NSError *err) {
        resultError = err;
        dispatch_semaphore_signal(sema);
    };

    if (item.direction == TransferDirectionUpload) {
        [self.client uploadLocalFile:item.sourcePath
                        toDevicePath:item.destinationPath
                            progress:progressHandler
                          completion:completion];
    } else {
        [self.client downloadDeviceFile:item.sourcePath
                            toLocalPath:item.destinationPath
                               progress:progressHandler
                             completion:completion];
    }

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);

    if (item.state == TransferItemStateCancelled) return;

    if (resultError && [self isTransientError:resultError] && retry < kMaxRetries) {
        NSLog(@"[TransferEngine] Retrying %@ (attempt %d)", item.displayName, retry + 1);
        [NSThread sleepForTimeInterval:1.0 * (retry + 1)];
        [self executeItem:item retryCount:retry + 1];
        return;
    }

    item.state    = resultError ? TransferItemStateFailed : TransferItemStateCompleted;
    item.progress = resultError ? item.progress : 1.0;
    item.error    = resultError;
    [self notifyUpdate:item];
}

- (BOOL)isTransientError:(NSError *)error {
    // FIX (BUG): AFC_E_IO_ERROR = 18 per libimobiledevice enum, not -6.
    // Code -6 was wrong (that's AFC_E_OP_WOULD_BLOCK). Retry on real I/O errors
    // and on device-connection errors (code -1 from invalidatedError).
    return error.code == AFC_E_IO_ERROR || error.code == -1;
}

// ── Control ───────────────────────────────────────────────────────────────────

- (void)cancelAll {
    NSArray *snapshot;
    @synchronized(self) { snapshot = [self.mutableItems copy]; }
    for (TransferItem *item in snapshot) {
        if (item.state == TransferItemStatePending || item.state == TransferItemStateRunning)
            [item cancel];
    }
    [self.queue cancelAllOperations];
}

- (void)clearCompleted {
    NSArray *removed;
    @synchronized(self) {
        NSArray *before = [self.mutableItems copy];
        [self.mutableItems filterUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(TransferItem *item, id _) {
                return item.state != TransferItemStateCompleted &&
                       item.state != TransferItemStateFailed   &&
                       item.state != TransferItemStateCancelled;
            }]];
        // Collect anything that was removed so we can fire one notification
        NSMutableArray *r = [NSMutableArray array];
        for (TransferItem *it in before)
            if (![self.mutableItems containsObject:it]) [r addObject:it];
        removed = r;
    }
    // FIX (BUG): notify observers so UI and any future listener updates.
    if (removed.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TransferEngineItemDidUpdateNotification
                              object:self
                            userInfo:@{}];
        });
    }
}

// ── Notification ──────────────────────────────────────────────────────────────

- (void)notifyUpdate:(TransferItem *)item {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TransferEngineItemDidUpdateNotification
                          object:self
                        userInfo:@{TransferEngineItemKey: item}];
    });
}

@end
