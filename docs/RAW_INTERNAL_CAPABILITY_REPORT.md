# RAW storage capability — 2026-10-11

- Removed the Settings requirement to select SSD before choosing RAW/HQ. Codec availability still follows the physical camera's RAW formats.
- Reconfigure probes the specific active codec, format and local Documents URL through recommendedVideoSettings and AVAssetWriter.canApply. Failure to query is kept distinct from unsupported settings; it does not silently redirect output.
- Public iOS 27 Pro Video Storage properties are queried at runtime because the installed build SDK is iOS 26. Only if the writer reports support is usesProVideoStorage enabled, before writing. Older systems without those selectors safely skip this path.
- Local RAW recording writes to its final Documents URL; SSD RAW keeps the system external URL flow. Start-time recommended settings/canApply/startWriting checks remain active for the actual target URL.
- Changing lens, codec or capture mode resets and rechecks capability. Detection does not depend on a model-name allowlist or SSD presence. An explicitly selected SSD destination still requires the actual SSD and folder permission.
- Positive capability means settings accepted, not completed recording. It does not guarantee sustained throughput, available preallocated capacity, or future OS behavior.

## Verification
- Signed iOS build passed: /tmp/gyro-raw-capability-build.log.
- 45 unit tests passed: /tmp/gyro-raw-capability-tests.log. Includes absence of newer public selectors on older systems.
- Phone currently unavailable; this change is not installed or device-validated.
- iOS 27 Pro Video Storage and successful local RAW/HQ captures are unverified. System storage setup may be needed before capability is available.

## Apple API references
- https://developer.apple.com/documentation/avfoundation/avassetwriter/isprovideostoragesupported
- https://developer.apple.com/documentation/avfoundation/avassetwriter/usesprovideostorage
- https://developer.apple.com/documentation/avfoundation/avprovideostorage
- https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/recommendedvideosettings(forvideocodectype:assetwriteroutputfiletype:outputfileurl:)
