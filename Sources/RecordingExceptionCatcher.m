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

+ (BOOL)isSupported {
    if (@available(iOS 27.0, *)) {
        return AVProVideoStorage.isSupported && AVProVideoStorage.sharedStorage != nil;
    }
    return NO;
}

+ (BOOL)isBusy {
    if (@available(iOS 27.0, *)) {
        AVProVideoStorage *storage = AVProVideoStorage.sharedStorage;
        return storage == nil || storage.busyReasons.count != 0;
    }
    return YES;
}

+ (int64_t)remainingCapacity {
    if (@available(iOS 27.0, *)) {
        return AVProVideoStorage.sharedStorage.remainingCapacity;
    }
    return 0;
}

+ (BOOL)isOutputSupported:(AVCaptureMovieFileOutput *)output {
    if (@available(iOS 27.0, *)) {
        return [self isSupported] && output.isProVideoStorageSupported;
    }
    return NO;
}

+ (NSDictionary<NSString *, id> *)diagnosticsForOutput:(AVCaptureMovieFileOutput *)output {
    BOOL enabled = NO;
    NSArray *busyReasons = @[];
    NSInteger initialCapacity = 0;
    if (@available(iOS 27.0, *)) {
        enabled = output.usesProVideoStorage;
        AVProVideoStorage *storage = AVProVideoStorage.sharedStorage;
        busyReasons = storage.busyReasons.allObjects ?: @[];
        initialCapacity = storage.initialCapacity;
    }
    return @{@"apiBinding": @"native-sdk27",
             @"deviceSupported": @([self isSupported]),
             @"outputSupported": @([self isOutputSupported:output]),
             @"usesProVideoStorage": @(enabled),
             @"initialBytes": @(initialCapacity),
             @"remainingBytes": @([self remainingCapacity]),
             @"busyReasons": busyReasons,
             @"busy": @([self isBusy])};
}

+ (NSString *)configureOutput:(AVCaptureMovieFileOutput *)output enabled:(BOOL)enabled {
    if (@available(iOS 27.0, *)) {
        if (enabled && ![self isOutputSupported:output]) {
            return @"当前镜头、编码或分辨率不支持专用视频存储";
        }
        @try {
            output.usesProVideoStorage = enabled;
            return nil;
        } @catch (NSException *exception) {
            return [NSString stringWithFormat:@"专用视频存储配置失败：%@", exception.reason ?: exception.name];
        }
    }
    return enabled ? @"当前系统不支持专用视频存储" : nil;
}

+ (void)openSettings {
    if (@available(iOS 27.0, *)) {
        [AVProVideoStorage.sharedStorage openSettings];
    }
}

@end
