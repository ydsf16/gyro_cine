#import "RecordingExceptionCatcher.h"
#import <math.h>

@implementation RecordingExceptionCatcher
+ (NSString *)exceptionMessageForBlock:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"No reason supplied"];
    }
}

+ (NSNumber *)whiteBalanceTemperatureForDevice:(AVCaptureDevice *)device
                                          error:(NSString * _Nullable * _Nullable)error {
    @try {
        AVCaptureWhiteBalanceGains gains = device.deviceWhiteBalanceGains;
        float maximum = device.maxWhiteBalanceGain;
        if (!isfinite(maximum) || maximum < 1.0f ||
            !isfinite(gains.redGain) || !isfinite(gains.greenGain) || !isfinite(gains.blueGain) ||
            gains.redGain < 1.0f || gains.greenGain < 1.0f || gains.blueGain < 1.0f ||
            gains.redGain > maximum || gains.greenGain > maximum || gains.blueGain > maximum) {
            if (error) *error = @"Camera reported out-of-range white balance gains";
            return nil;
        }
        AVCaptureWhiteBalanceTemperatureAndTintValues values =
            [device temperatureAndTintValuesForDeviceWhiteBalanceGains:gains];
        if (!isfinite(values.temperature)) {
            if (error) *error = @"Camera reported non-finite white balance temperature";
            return nil;
        }
        return @(values.temperature);
    } @catch (NSException *exception) {
        if (error) *error = [NSString stringWithFormat:@"%@: %@", exception.name,
                              exception.reason ?: @"No reason supplied"];
        return nil;
    }
}
@end


@implementation ProVideoStorageBridge

+ (id)sharedStorage {
    Class storageClass = NSClassFromString(@"AVProVideoStorage");
    SEL supported = NSSelectorFromString(@"isSupported");
    SEL shared = NSSelectorFromString(@"sharedStorage");
    if (!storageClass || ![storageClass respondsToSelector:supported] ||
        ![storageClass respondsToSelector:shared]) return nil;
    BOOL (*supports)(id, SEL) = (void *)[storageClass methodForSelector:supported];
    if (!supports(storageClass, supported)) return nil;
    id (*getShared)(id, SEL) = (void *)[storageClass methodForSelector:shared];
    return getShared(storageClass, shared);
}

+ (BOOL)isSupported { return [self sharedStorage] != nil; }

+ (BOOL)isBusy {
    id storage = [self sharedStorage];
    SEL selector = NSSelectorFromString(@"busyReasons");
    if (!storage || ![storage respondsToSelector:selector]) return YES;
    id (*getReasons)(id, SEL) = (void *)[storage methodForSelector:selector];
    return [getReasons(storage, selector) count] != 0;
}

+ (int64_t)remainingCapacity {
    id storage = [self sharedStorage];
    SEL selector = NSSelectorFromString(@"remainingCapacity");
    if (!storage || ![storage respondsToSelector:selector]) return 0;
    NSInteger (*getCapacity)(id, SEL) = (void *)[storage methodForSelector:selector];
    return getCapacity(storage, selector);
}

+ (BOOL)isOutputSupported:(AVCaptureMovieFileOutput *)output {
    SEL selector = NSSelectorFromString(@"isProVideoStorageSupported");
    if (![self isSupported] || ![output respondsToSelector:selector]) return NO;
    BOOL (*supports)(id, SEL) = (void *)[output methodForSelector:selector];
    return supports(output, selector);
}

+ (NSDictionary<NSString *, id> *)diagnosticsForOutput:(AVCaptureMovieFileOutput *)output {
    SEL getter = NSSelectorFromString(@"usesProVideoStorage");
    BOOL enabled = NO;
    if ([output respondsToSelector:getter]) {
        BOOL (*getEnabled)(id, SEL) = (void *)[output methodForSelector:getter];
        enabled = getEnabled(output, getter);
    }
    return @{@"deviceSupported": @([self isSupported]),
             @"outputSupported": @([self isOutputSupported:output]),
             @"outputSupportSelectorPresent": @([output respondsToSelector:NSSelectorFromString(@"isProVideoStorageSupported")]),
             @"outputSetterPresent": @([output respondsToSelector:NSSelectorFromString(@"setUsesProVideoStorage:")]),
             @"usesProVideoStorage": @(enabled),
             @"remainingBytes": @([self remainingCapacity]),
             @"busy": @([self isBusy])};
}

+ (NSString *)configureOutput:(AVCaptureMovieFileOutput *)output enabled:(BOOL)enabled {
    SEL selector = NSSelectorFromString(@"setUsesProVideoStorage:");
    if (![output respondsToSelector:selector]) {
        return enabled ? @"当前系统不支持专用视频存储" : nil;
    }
    if (enabled && ![self isOutputSupported:output]) {
        return @"当前镜头、编码或分辨率不支持专用视频存储";
    }
    @try {
        void (*setEnabled)(id, SEL, BOOL) = (void *)[output methodForSelector:selector];
        setEnabled(output, selector, enabled);
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"专用视频存储配置失败：%@", exception.reason ?: exception.name];
    }
}

+ (void)openSettings {
    id storage = [self sharedStorage];
    SEL selector = NSSelectorFromString(@"openSettings");
    if (storage && [storage respondsToSelector:selector]) {
        void (*open)(id, SEL) = (void *)[storage methodForSelector:selector];
        open(storage, selector);
    }
}

@end
