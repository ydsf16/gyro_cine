#import "ExceptionGuard.h"
@implementation ExceptionGuard
+ (NSString *)run:(void (^)(void))block {
    @try { block(); return nil; }
    @catch (NSException *e) { return [NSString stringWithFormat:@"%@: %@", e.name, e.reason]; }
}
@end
