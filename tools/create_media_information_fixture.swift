// Test fixture only. Usage: swift tools/create_media_information_fixture.swift input.mov output.mov
// Output must not exist. The generated metadata is synthetic, not camera evidence.
import AVFoundation
guard CommandLine.arguments.count == 3 else { fatalError("Expected input.mov output.mov") }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let exporter = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetPassthrough)!
exporter.outputURL = output; exporter.outputFileType = .mov
let capture: [String: Any] = ["model":"iPhone Test", "lensName":"Back Camera", "lensType":AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue, "position":"back", "iso":100, "aperture":1.8, "exposureSeconds":1.0/60, "whiteBalanceKelvin":5600, "tint":-3, "zoom":1, "scope":"recordingStart", "colorSpace":"Rec.709"]
let json = String(data: try! JSONSerialization.data(withJSONObject: capture), encoding: .utf8)!
exporter.metadata = ["com.tinygrape.gyrocine.capture":json, "com.apple.quicktime.creationdate":"2026-10-24T09:30:00+08:00", "com.apple.quicktime.description":"测试备注 / Notes"].map { key,value in
 let item=AVMutableMetadataItem();item.keySpace = .quickTimeMetadata;item.key=key as NSString;item.value=value as NSString;item.dataType=kCMMetadataBaseDataType_UTF8 as String;return item
}
exporter.exportAsynchronously { print(exporter.status.rawValue, exporter.error as Any); exit(exporter.status == .completed ? 0 : 1) }
dispatchMain()
