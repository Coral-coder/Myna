#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a Swift closure inside an Objective-C @try/@catch so an uncaught
/// `NSException` (which Swift cannot catch and which otherwise aborts the whole
/// app) becomes a recoverable signal. Used to harden paths that call into
/// Foundation / EventKit / CoreData from fragile contexts (e.g. a notification
/// response handler during launch), where those frameworks can raise.
@interface MynaExceptionCatcher : NSObject

/// Executes `block`. Returns the caught exception's reason/name if it threw an
/// NSException, or nil on success.
+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
