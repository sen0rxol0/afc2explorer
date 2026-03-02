#import "FileSafetyLayer.h"
#import <AppKit/AppKit.h>

// Hard blocks – operations on or inside these trees are always rejected.
static NSArray<NSString *> *blockedPrefixes(void) {
    return @[@"/System", @"/bin", @"/usr", @"/sbin", @"/boot", @"/dev"];
}

// Soft warns – user must confirm before proceeding.
static NSArray<NSString *> *warnedPrefixes(void) {
    return @[@"/Library", @"/etc", @"/private"];
}

@implementation FileSafetyLayer

+ (instancetype)sharedLayer {
    static FileSafetyLayer *s;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [[self alloc] init]; });
    return s;
}

// ── Path classification ────────────────────────────────────────────────────────

- (BOOL)isPathBlocked:(NSString *)path {
    NSString *normal = [self normalize:path];
    for (NSString *prefix in blockedPrefixes()) {
        if ([normal isEqualToString:prefix] || [normal hasPrefix:[prefix stringByAppendingString:@"/"]]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)requiresConfirmationForPath:(NSString *)path {
    if ([self isPathBlocked:path]) return NO;  // already blocked outright
    NSString *normal = [self normalize:path];
    // Root-level write (e.g. /newfile or /newfolder)
    if ([normal componentsSeparatedByString:@"/"].count <= 2) return YES;
    for (NSString *prefix in warnedPrefixes()) {
        if ([normal isEqualToString:prefix] || [normal hasPrefix:[prefix stringByAppendingString:@"/"]]) {
            return YES;
        }
    }
    return NO;
}

// ── Public API ────────────────────────────────────────────────────────────────

- (BOOL)canWriteToPath:(NSString *)path error:(NSError **)error {
    if ([self isPathBlocked:path]) {
        if (error) *error = [self blockedErrorForPath:path];
        return NO;
    }
    return YES;  // caller shows confirmation dialog separately if needed
}

- (BOOL)canDeletePath:(NSString *)path error:(NSError **)error {
    if ([self isPathBlocked:path]) {
        if (error) *error = [self blockedErrorForPath:path];
        return NO;
    }
    return YES;
}

/// Must be called from main thread. Returns YES if user clicked Proceed.
- (BOOL)presentConfirmationForPath:(NSString *)path action:(NSString *)action {
    NSAssert([NSThread isMainThread], @"Must be called on main thread");

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText    = [NSString stringWithFormat:@"%@ sensitive path?", action];
    alert.informativeText = [NSString stringWithFormat:
        @"\"%@\" is in a sensitive location.\n\nProceeding may affect system stability. Are you sure?", path];
    alert.alertStyle     = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Proceed"];
    [alert addButtonWithTitle:@"Cancel"];

    return [alert runModal] == NSAlertFirstButtonReturn;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

- (NSString *)normalize:(NSString *)path {
    // Collapse // and resolve . without hitting the real filesystem
    return path.stringByStandardizingPath ?: path;
}

- (NSError *)blockedErrorForPath:(NSString *)path {
    return [NSError errorWithDomain:@"AFC2SafetyErrorDomain"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                               [NSString stringWithFormat:@"Access to \"%@\" is blocked for safety.", path]}];
}

@end
