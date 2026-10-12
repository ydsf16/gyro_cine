#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RecordingExceptionCatcher : NSObject
+ (nullable NSString *)exceptionMessageForBlock:(void (^)(void))block NS_SWIFT_NAME(exceptionMessage(for:));
@end

NS_ASSUME_NONNULL_END
