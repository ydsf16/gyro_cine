#import "RAWSettingsProbe.h"

@implementation RAWSettingsProbe
+ (NSDictionary<NSString *, id> *)settingsForOutput:(AVCaptureVideoDataOutput *)output
                                           codec:(AVVideoCodecType)codec
                                             url:(NSURL *)url
                                           error:(NSError **)error {
    @try {
        NSDictionary *settings = [output recommendedVideoSettingsForVideoCodecType:codec
                                      assetWriterOutputFileType:AVFileTypeQuickTimeMovie
                                                  outputFileURL:url];
        if (!settings && error) *error = [NSError errorWithDomain:@"GyroCine.RAWSettingsProbe" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No RAW settings for this destination"}];
        return settings;
    } @catch (NSException *exception) {
        // AVFoundation capability queries can raise rather than return nil, e.g.
        // when a RAW output destination is unsupported. Surface the exact reason.
        if (error) *error = [NSError errorWithDomain:@"GyroCine.RAWSettingsProbe" code:1
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        return nil;
    }
}
+ (NSArray<AVMetadataItem *> *)metadataForOutput:(AVCaptureVideoDataOutput *)output
                                         codec:(AVVideoCodecType)codec
                                         error:(NSError **)error {
    @try {
        NSArray *metadata = [output recommendedMovieMetadataForVideoCodecType:codec assetWriterOutputFileType:AVFileTypeQuickTimeMovie];
        if (!metadata && error) *error = [NSError errorWithDomain:@"GyroCine.RAWSettingsProbe" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Missing RAW movie metadata"}];
        return metadata;
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"GyroCine.RAWSettingsProbe" code:2
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
        return nil;
    }
}
@end
