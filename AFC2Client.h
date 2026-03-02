#import <Foundation/Foundation.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/libimobiledevice.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AFC2ProgressHandler)(int64_t bytesTransferred, int64_t totalBytes);
typedef void (^AFC2CompletionHandler)(NSError * _Nullable error);

// ── File info ─────────────────────────────────────────────────────────────────

@interface AFC2FileInfo : NSObject
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, assign) BOOL      isDirectory;
@property (nonatomic, assign) uint64_t  fileSize;
@property (nonatomic, strong) NSDate   *modificationDate;
@end

// ── Client ────────────────────────────────────────────────────────────────────

@interface AFC2Client : NSObject

/// Designated initialiser – DeviceManager passes ownership of afcClient and device.
- (instancetype)initWithAFCClient:(afc_client_t)afcClient
                           device:(idevice_t)device NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Call when the device disappears; no further operations will succeed.
- (void)invalidate;

/// YES until -invalidate is called.
@property (nonatomic, readonly, getter=isValid) BOOL valid;

// ── Filesystem operations ────────────────────────────────────────────────────
// Operations execute on an internal background queue.
// All completion blocks are called on the MAIN thread.

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray<AFC2FileInfo *> * _Nullable items,
                                NSError * _Nullable error))completion;

- (void)uploadLocalFile:(NSString *)localPath
         toDevicePath:(NSString *)devicePath
             progress:(nullable AFC2ProgressHandler)progress
           completion:(AFC2CompletionHandler)completion;

- (void)downloadDeviceFile:(NSString *)devicePath
             toLocalPath:(NSString *)localPath
                progress:(nullable AFC2ProgressHandler)progress
              completion:(AFC2CompletionHandler)completion;

- (void)deletePath:(NSString *)devicePath
        recursive:(BOOL)recursive
        completion:(AFC2CompletionHandler)completion;

- (void)createDirectory:(NSString *)devicePath
             completion:(AFC2CompletionHandler)completion;

- (void)renamePath:(NSString *)devicePath
                to:(NSString *)newPath
        completion:(AFC2CompletionHandler)completion;

@end

NS_ASSUME_NONNULL_END
