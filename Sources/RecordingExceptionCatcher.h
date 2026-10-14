#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RecordingExceptionCatcher : NSObject
+ (nullable NSString *)exceptionMessageForBlock:(void (^)(void))block NS_SWIFT_NAME(exceptionMessage(for:));
+ (nullable NSNumber *)whiteBalanceTemperatureForDevice:(AVCaptureDevice *)device
                                                  error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(whiteBalanceTemperature(for:error:));
@end

/// Runtime adapter for iOS 27 Pro Video Storage while building with the iOS 26 SDK.
@interface ProVideoStorageBridge : NSObject
+ (BOOL)isSupported;
+ (BOOL)isBusy;
+ (int64_t)remainingCapacity;
+ (BOOL)isOutputSupported:(AVCaptureMovieFileOutput *)output;
+ (nullable NSString *)configureOutput:(AVCaptureMovieFileOutput *)output enabled:(BOOL)enabled;
+ (void)openSettings;
@end

NS_ASSUME_NONNULL_END
