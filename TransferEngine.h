#import <Foundation/Foundation.h>

@class AFC2Client;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TransferDirection) {
    TransferDirectionUpload,
    TransferDirectionDownload
};

typedef NS_ENUM(NSInteger, TransferItemState) {
    TransferItemStatePending,
    TransferItemStateRunning,
    TransferItemStateCompleted,
    TransferItemStateFailed,
    TransferItemStateCancelled
};

extern NSNotificationName const TransferEngineItemDidUpdateNotification;
extern NSString *const TransferEngineItemKey;

// ── Transfer item ─────────────────────────────────────────────────────────────

@interface TransferItem : NSObject

@property (nonatomic, readonly) NSUUID             *identifier;
@property (nonatomic, readonly) TransferDirection   direction;
@property (nonatomic, readonly, copy) NSString     *sourcePath;
@property (nonatomic, readonly, copy) NSString     *destinationPath;
@property (nonatomic, readonly) TransferItemState   state;
@property (nonatomic, readonly) double              progress;      // 0.0–1.0
@property (nonatomic, readonly, nullable) NSError  *error;
@property (nonatomic, readonly, copy) NSString     *displayName;

- (void)cancel;

@end

// ── Engine ────────────────────────────────────────────────────────────────────

@interface TransferEngine : NSObject

- (instancetype)initWithAFC2Client:(AFC2Client *)client;

@property (nonatomic, readonly) NSArray<TransferItem *> *items;

- (TransferItem *)enqueueUploadFromLocalPath:(NSString *)localPath
                                toDevicePath:(NSString *)devicePath;

- (TransferItem *)enqueueDownloadFromDevicePath:(NSString *)devicePath
                                    toLocalPath:(NSString *)localPath;

- (void)cancelAll;
- (void)clearCompleted;

@end

NS_ASSUME_NONNULL_END
