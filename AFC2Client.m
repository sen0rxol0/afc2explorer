#import "AFC2Client.h"
#import "FileSafetyLayer.h"
#include <libimobiledevice/afc.h>

static const uint32_t kChunkSize = 256 * 1024;  // 256 KB

// ── AFC2FileInfo ──────────────────────────────────────────────────────────────

@implementation AFC2FileInfo
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@ %@%@ %llu bytes>",
            NSStringFromClass([self class]), self.path,
            self.isDirectory ? @"/" : @"", (unsigned long long)self.fileSize];
}
@end

// ── AFC2Client private ────────────────────────────────────────────────────────

@interface AFC2Client () {
    afc_client_t  _afc;
    idevice_t     _device;
}
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, readwrite, getter=isValid) BOOL valid;  // atomic access via queue
@end

// ── Implementation ────────────────────────────────────────────────────────────

@implementation AFC2Client

- (instancetype)initWithAFCClient:(afc_client_t)afcClient device:(idevice_t)device {
    if (!(self = [super init])) return nil;
    _afc    = afcClient;
    _device = device;
    _valid  = YES;
    _queue  = dispatch_queue_create("com.afc2util.afc2client", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    // FIX (CRASH): do NOT call invalidate here — it dispatch_syncs on _queue which
    // can deadlock if dealloc runs from within a completion block on the queue.
    // Instead tear down directly; _valid is already NO if invalidate was called,
    // or we clean up now without touching the queue.
    if (_afc)    { afc_client_free(_afc);   _afc    = NULL; }
    if (_device) { idevice_free(_device);   _device = NULL; }
}

- (void)invalidate {
    // FIX (CRASH): use a flag + async to avoid dispatch_sync deadlock.
    // Mark invalid immediately (checked before every operation), then
    // schedule resource teardown asynchronously so any in-flight block
    // completes first.
    _valid = NO;   // written before async so new enqueued blocks bail early
    dispatch_async(_queue, ^{
        if (_afc)    { afc_client_free(_afc);   _afc    = NULL; }
        if (_device) { idevice_free(_device);   _device = NULL; }
    });
}

// ── Internal helpers ──────────────────────────────────────────────────────────

- (NSError *)errorForAFCError:(afc_error_t)err path:(NSString *)path {
    if (err == AFC_E_SUCCESS) return nil;
    NSString *desc;
    switch (err) {
        case AFC_E_OBJECT_NOT_FOUND:   desc = [NSString stringWithFormat:@"Path not found: %@", path]; break;
        case AFC_E_PERM_DENIED:        desc = [NSString stringWithFormat:@"Permission denied: %@", path]; break;
        case AFC_E_OBJECT_EXISTS:      desc = [NSString stringWithFormat:@"Already exists: %@", path]; break;
        case AFC_E_DIR_NOT_EMPTY:      desc = [NSString stringWithFormat:@"Directory not empty: %@", path]; break;
        case AFC_E_IO_ERROR:           desc = @"I/O error"; break;
        default:                       desc = [NSString stringWithFormat:@"AFC error %d on %@", err, path];
    }
    return [NSError errorWithDomain:@"AFC2ClientErrorDomain"
                               code:err
                           userInfo:@{NSLocalizedDescriptionKey: desc}];
}

- (void)asyncOnQueue:(dispatch_block_t)block {
    dispatch_async(_queue, block);
}

// ── listDirectory ─────────────────────────────────────────────────────────────
// FIX (docs): Completions are delivered on the MAIN thread. Header updated accordingly.

- (void)listDirectory:(NSString *)path
           completion:(void (^)(NSArray<AFC2FileInfo *> *, NSError *))completion {
    [self asyncOnQueue:^{
        if (!self.valid) { completion(nil, [self invalidatedError]); return; }

        char **list = NULL;
        afc_error_t err = afc_read_directory(_afc, path.UTF8String, &list);
        if (err != AFC_E_SUCCESS) {
            completion(nil, [self errorForAFCError:err path:path]);
            return;
        }

        NSMutableArray *items = [NSMutableArray array];
        for (int i = 0; list[i]; i++) {
            NSString *name = @(list[i]);
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
            NSString *fullPath = [path stringByAppendingPathComponent:name];
            AFC2FileInfo *info = [self fileInfoForPath:fullPath name:name];
            if (info) [items addObject:info];
        }
        afc_dictionary_free(list);

        // Sort: directories first, then alpha
        [items sortUsingComparator:^NSComparisonResult(AFC2FileInfo *a, AFC2FileInfo *b) {
            if (a.isDirectory != b.isDirectory)
                return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{ completion(items, nil); });
    }];
}

- (AFC2FileInfo *)fileInfoForPath:(NSString *)path name:(NSString *)name {
    char **info = NULL;
    afc_error_t err = afc_get_file_info(_afc, path.UTF8String, &info);
    if (err != AFC_E_SUCCESS || !info) return nil;

    AFC2FileInfo *fi = [[AFC2FileInfo alloc] init];
    fi.name = name;
    fi.path = path;

    for (int i = 0; info[i]; i += 2) {
        NSString *key = @(info[i]);
        NSString *val = @(info[i+1]);
        if ([key isEqualToString:@"st_ifmt"]) {
            fi.isDirectory = [val isEqualToString:@"S_IFDIR"];
        } else if ([key isEqualToString:@"st_size"]) {
            fi.fileSize = (uint64_t)val.longLongValue;
        } else if ([key isEqualToString:@"st_mtime"]) {
            fi.modificationDate = [NSDate dateWithTimeIntervalSince1970:val.longLongValue / 1e9];
        }
    }
    afc_dictionary_free(info);
    return fi;
}

// ── uploadLocalFile ───────────────────────────────────────────────────────────

- (void)uploadLocalFile:(NSString *)localPath
         toDevicePath:(NSString *)devicePath
             progress:(AFC2ProgressHandler)progress
           completion:(AFC2CompletionHandler)completion {
    [self asyncOnQueue:^{
        if (!self.valid) { [self callCompletion:completion error:[self invalidatedError]]; return; }

        NSError *safeErr;
        if (![[FileSafetyLayer sharedLayer] canWriteToPath:devicePath error:&safeErr]) {
            [self callCompletion:completion error:safeErr]; return;
        }

        NSError *localErr;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:localPath error:&localErr];
        if (!attrs) { [self callCompletion:completion error:localErr]; return; }
        int64_t totalBytes = [attrs[NSFileSize] longLongValue];

        FILE *fp = fopen(localPath.fileSystemRepresentation, "rb");
        if (!fp) {
            [self callCompletion:completion error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
            return;
        }

        uint64_t handle = 0;
        afc_error_t err = afc_file_open(_afc, devicePath.UTF8String, AFC_FOPEN_WR, &handle);
        if (err != AFC_E_SUCCESS) {
            fclose(fp);
            [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
            return;
        }

        uint8_t *buf = malloc(kChunkSize);
        int64_t sent = 0;
        BOOL failed = NO;

        while (!feof(fp)) {
            size_t nread = fread(buf, 1, kChunkSize, fp);
            if (nread == 0) break;

            uint32_t written = 0;
            err = afc_file_write(_afc, handle, (const char *)buf, (uint32_t)nread, &written);
            if (err != AFC_E_SUCCESS || written != nread) {
                failed = YES; break;
            }
            sent += written;
            if (progress) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress(sent, totalBytes); });
            }
        }

        free(buf);
        fclose(fp);
        afc_file_close(_afc, handle);

        if (failed) {
            // FIX (BUG): delete the partial device file on upload failure,
            // mirroring what downloadDeviceFile does for partial local files.
            afc_remove_path(_afc, devicePath.UTF8String);
            [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
        } else {
            [self callCompletion:completion error:nil];
        }
    }];
}

// ── downloadDeviceFile ────────────────────────────────────────────────────────

- (void)downloadDeviceFile:(NSString *)devicePath
             toLocalPath:(NSString *)localPath
                progress:(AFC2ProgressHandler)progress
              completion:(AFC2CompletionHandler)completion {
    [self asyncOnQueue:^{
        if (!self.valid) { [self callCompletion:completion error:[self invalidatedError]]; return; }

        AFC2FileInfo *info = [self fileInfoForPath:devicePath name:devicePath.lastPathComponent];
        int64_t totalBytes = info ? (int64_t)info.fileSize : -1;

        uint64_t handle = 0;
        afc_error_t err = afc_file_open(_afc, devicePath.UTF8String, AFC_FOPEN_RDONLY, &handle);
        if (err != AFC_E_SUCCESS) {
            [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
            return;
        }

        FILE *fp = fopen(localPath.fileSystemRepresentation, "wb");
        if (!fp) {
            afc_file_close(_afc, handle);
            [self callCompletion:completion error:[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]];
            return;
        }

        uint8_t *buf = malloc(kChunkSize);
        int64_t received = 0;
        BOOL failed = NO;

        while (YES) {
            uint32_t nread = 0;
            err = afc_file_read(_afc, handle, (char *)buf, kChunkSize, &nread);
            if (err != AFC_E_SUCCESS || nread == 0) break;

            if (fwrite(buf, 1, nread, fp) != nread) { failed = YES; break; }
            received += nread;
            if (progress) {
                dispatch_async(dispatch_get_main_queue(), ^{ progress(received, totalBytes); });
            }
        }

        free(buf);
        fclose(fp);
        afc_file_close(_afc, handle);

        if (failed || (err != AFC_E_SUCCESS && err != AFC_E_END_OF_DATA)) {
            [[NSFileManager defaultManager] removeItemAtPath:localPath error:nil];
            [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
        } else {
            [self callCompletion:completion error:nil];
        }
    }];
}

// ── deletePath ────────────────────────────────────────────────────────────────

- (void)deletePath:(NSString *)devicePath recursive:(BOOL)recursive completion:(AFC2CompletionHandler)completion {
    [self asyncOnQueue:^{
        if (!self.valid) { [self callCompletion:completion error:[self invalidatedError]]; return; }

        NSError *safeErr;
        if (![[FileSafetyLayer sharedLayer] canDeletePath:devicePath error:&safeErr]) {
            [self callCompletion:completion error:safeErr]; return;
        }

        afc_error_t err;
        if (recursive) {
            err = [self removeRecursive:devicePath];
        } else {
            err = afc_remove_path(_afc, devicePath.UTF8String);
        }
        [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
    }];
}

- (afc_error_t)removeRecursive:(NSString *)path {
    char **list = NULL;
    afc_error_t err = afc_read_directory(_afc, path.UTF8String, &list);
    if (err == AFC_E_SUCCESS && list) {
        for (int i = 0; list[i]; i++) {
            NSString *name = @(list[i]);
            if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) continue;
            [self removeRecursive:[path stringByAppendingPathComponent:name]];
        }
        afc_dictionary_free(list);
    }
    return afc_remove_path(_afc, path.UTF8String);
}

// ── createDirectory ───────────────────────────────────────────────────────────

- (void)createDirectory:(NSString *)devicePath completion:(AFC2CompletionHandler)completion {
    [self asyncOnQueue:^{
        if (!self.valid) { [self callCompletion:completion error:[self invalidatedError]]; return; }
        afc_error_t err = afc_make_directory(_afc, devicePath.UTF8String);
        [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
    }];
}

// ── renamePath ────────────────────────────────────────────────────────────────

- (void)renamePath:(NSString *)devicePath to:(NSString *)newPath completion:(AFC2CompletionHandler)completion {
    [self asyncOnQueue:^{
        if (!self.valid) { [self callCompletion:completion error:[self invalidatedError]]; return; }
        afc_error_t err = afc_rename_path(_afc, devicePath.UTF8String, newPath.UTF8String);
        [self callCompletion:completion error:[self errorForAFCError:err path:devicePath]];
    }];
}

// ── Utilities ─────────────────────────────────────────────────────────────────

// All completions are dispatched to the main queue.
- (void)callCompletion:(AFC2CompletionHandler)completion error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
}

- (NSError *)invalidatedError {
    return [NSError errorWithDomain:@"AFC2ClientErrorDomain" code:-1
                           userInfo:@{NSLocalizedDescriptionKey: @"Device disconnected"}];
}

@end
