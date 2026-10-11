#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface RAWSettingsProbe : NSObject
+ (nullable NSDictionary<NSString *, id> *)settingsForOutput:(AVCaptureVideoDataOutput *)output
                                                     codec:(AVVideoCodecType)codec
                                                       url:(NSURL *)url
                                                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(settings(output:codec:url:));
+ (nullable NSArray<AVMetadataItem *> *)metadataForOutput:(AVCaptureVideoDataOutput *)output
                                                   codec:(AVVideoCodecType)codec
                                                   error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(metadata(output:codec:)) API_AVAILABLE(ios(26.0));
@end
NS_ASSUME_NONNULL_END
