#import <Foundation/Foundation.h>
@interface ExceptionGuard : NSObject
+ (NSString * _Nullable)run:(void (^ _Nonnull)(void))block;
@end
