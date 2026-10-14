#import "RecordingExceptionCatcher.h"

@implementation RecordingExceptionCatcher
+ (NSString *)exceptionMessageForBlock:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"No reason supplied"];
    }
}
@end
