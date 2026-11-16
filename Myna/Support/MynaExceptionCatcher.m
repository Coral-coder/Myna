#import "MynaExceptionCatcher.h"

@implementation MynaExceptionCatcher

+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: exception.name;
        return reason ?: @"unknown NSException";
    }
}

@end
