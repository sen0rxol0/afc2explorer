#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FileSafetyLayer : NSObject

+ (instancetype)sharedLayer;

/// Returns YES if the path is safe to write to; populates error otherwise.
- (BOOL)canWriteToPath:(NSString *)path error:(NSError **)error;

/// Returns YES if the path is safe to delete; populates error otherwise.
- (BOOL)canDeletePath:(NSString *)path error:(NSError **)error;

/// Returns YES if this path requires the user to confirm before proceeding.
- (BOOL)requiresConfirmationForPath:(NSString *)path;

/// Synchronously shows an alert on the main thread; returns YES if user confirms.
- (BOOL)presentConfirmationForPath:(NSString *)path action:(NSString *)action;

@end

NS_ASSUME_NONNULL_END
