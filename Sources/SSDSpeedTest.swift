import Foundation

final class SSDSpeedCancellation {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct SSDSpeedReport {
    enum Assessment { case usable, risky, insufficient }
    let drive: String
    let driveID: String?
    var configuration: String
    var requiredMBps: Double
    var fps: Double
    var bufferedFrameLimit: Int? = nil
    let averageMBps: Double
    let sustainedMBps: Double
    let maximumWriteMS: Double
    let maximumFlushMS: Double
    let date = Date()
    var assessment: Assessment {
        Self.assess(sustained: sustainedMBps, required: requiredMBps, stallMS: maximumWriteMS, fps: fps, bufferedFrameLimit: bufferedFrameLimit)
    }
    static func assess(sustained: Double, required: Double, stallMS: Double, fps: Double, bufferedFrameLimit: Int? = nil) -> Assessment {
        guard sustained.isFinite, required.isFinite, required > 0, sustained >= required else { return .insufficient }
        if sustained < required * 1.3 { return .risky }
        // Only the native RAW writer has our known ten-frame ingress limit.
        // MovieFileOutput buffering is managed by AVFoundation; do not invent its limit.
        if let limit = bufferedFrameLimit,
           !stallMS.isFinite || stallMS > Double(limit) * 1000 / max(fps, 1) { return .risky }
        return .usable
    }
}

enum SSDSpeedTest {
    static let bytes: Int64 = 8_589_934_592
    struct Measurement {
        let average: Double
        let sustained: Double
        let maxWriteMS: Double
        let maxFlushMS: Double
    }
    /// The caller owns security scope. Only a newly, exclusively created file is ever removed.
    static func run(url: URL, cancellation: SSDSpeedCancellation,
                    progress: (Double, Double) -> Void) throws -> Measurement {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var outcome: Result<Measurement, Error>
        do {
            var block = Data(count: 8 * 1024 * 1024)
            block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
            let start = ProcessInfo.processInfo.systemUptime
            var windows: [Double] = []
            var maxWrite = 0.0, maxFlush = 0.0
            for window in 0..<16 {
                let windowStart = ProcessInfo.processInfo.systemUptime
                for chunk in 0..<64 {
                    if cancellation.isCancelled { throw CancellationError() }
                    if ProcessInfo.processInfo.systemUptime - start > 180 {
                        throw NSError(domain: "GyroCine.SSDSpeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "测速超时 / Speed test timed out"])
                    }
                    let before = ProcessInfo.processInfo.systemUptime
                    try handle.write(contentsOf: block)
                    maxWrite = max(maxWrite, (ProcessInfo.processInfo.systemUptime - before) * 1000)
                    if chunk % 8 == 7 { progress(Double(window * 64 + chunk + 1) / 1024, windows.last ?? 0) }
                }
                let beforeFlush = ProcessInfo.processInfo.systemUptime
                try handle.synchronize()
                let end = ProcessInfo.processInfo.systemUptime
                maxFlush = max(maxFlush, (end - beforeFlush) * 1000)
                let rate = 536_870_912 / (end - windowStart) / 1_000_000
                windows.append(rate)
                progress(Double(window + 1) / 16, rate)
            }
            if cancellation.isCancelled { throw CancellationError() }
            outcome = .success(.init(average: Double(bytes) / (ProcessInfo.processInfo.systemUptime - start) / 1_000_000,
                sustained: windows.suffix(8).min() ?? 0, maxWriteMS: maxWrite, maxFlushMS: maxFlush))
        } catch { outcome = .failure(error) }
        try? handle.close()
        do { try FileManager.default.removeItem(at: url) }
        catch {
            throw NSError(domain: "GyroCine.SSDSpeed", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "测速临时文件未能清理，请重新连接 SSD 后删除：\(url.lastPathComponent) / Could not remove test file: \(url.lastPathComponent)"])
        }
        return try outcome.get()
    }
}

import SwiftUI

struct SSDSpeedTestView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private func t(_ zh: String, _ en: String) -> String { AppText.value(zh, en, locale: locale) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(t("写入约 8.6 GB 临时数据，测试持续速度和停顿，完成或取消后删除。需要至少 14 GB 可用空间。", "Writes about 8.6 GB of temporary data to measure sustained speed and stalls. Removed after completion or cancellation. Requires 14 GB free."))
                        .font(.footnote).foregroundStyle(.secondary)
                    if camera.ssdSpeedTesting {
                        ProgressView(value: camera.ssdSpeedProgress)
                        HStack {
                            Text(String(format: "%.0f%%", camera.ssdSpeedProgress * 100))
                            Spacer()
                            Text(String(format: "%.0f MB/s", camera.ssdSpeedCurrentMBps)).monospacedDigit()
                        }
                        Button(t("取消测速", "Cancel test"), role: .cancel) { camera.cancelSSDSpeedTest() }
                            .accessibilityIdentifier("ssdSpeedCancel")
                    } else {
                        Button { camera.startSSDSpeedTest() } label: {
                            Label(t("开始测速", "Start speed test"), systemImage: "speedometer")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.disabled(camera.recording || camera.finalizing || camera.preparingRecording)
                            .accessibilityIdentifier("ssdSpeedStart")
                    }
                    if let error = camera.ssdSpeedError { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("ssdSpeedError") }
                }
                if let report = camera.ssdSpeedReport {
                    Section(t("当前录制配置判断", "Assessment for current recording configuration")) {
                        Label(assessmentTitle(report), systemImage: report.assessment == .usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(assessmentColor(report)).accessibilityIdentifier("ssdSpeedAssessment")
                        Text(report.drive).font(.subheadline)
                        Text(report.configuration).font(.footnote).foregroundStyle(.secondary)
                        metric(t("所需速度（估算）", "Required (estimated)"), report.requiredMBps, "MB/s")
                        metric(t("后半段最低速度", "Lowest second-half speed"), report.sustainedMBps, "MB/s")
                        metric(t("全程平均速度", "Overall average speed"), report.averageMBps, "MB/s")
                        metric(t("最长写入停顿", "Longest write stall"), report.maximumWriteMS, "ms")
                        metric(t("最长落盘耗时", "Longest flush"), report.maximumFlushMS, "ms")
                        Text(report.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        Text(report.assessment == .usable
                             ? (report.bufferedFrameLimit == nil
                                ? t("持续速度满足当前配置，留有至少 30% 余量。写入停顿单独列出，实际录制表现仍需验证。", "Sustained throughput has at least 30% headroom for this configuration. Stalls are listed separately; verify actual recording performance.")
                                : t("速度留有至少 30% 余量，写入停顿未超过当前帧率的 10 帧缓冲时间。", "At least 30% throughput headroom; write stalls stayed within ten frame periods."))
                             : report.assessment == .risky
                                ? t("速度余量不足或有较长写入停顿，建议降低录制规格并实录验证。", "Limited throughput headroom or long write stalls. Lower recording settings and verify with a recording.")
                                : t("持续速度低于当前配置的估算需求，建议降低规格或更换 SSD。", "Sustained speed is below the estimated requirement. Lower recording settings or use another SSD."))
                            .font(.footnote)
                    }
                }
                Section {
                    Text(t("判断适用于上方当前录制配置。所需速度根据本机录制统计或保守估算；画面内容、温度、剩余空间会影响结果。测速通过不代表无限时长录制保证。", "Assessment applies to the current recording configuration shown above. Required speed uses on-device recording statistics or a conservative estimate. Scene content, temperature and free space affect results. Passing is not an unlimited-duration guarantee."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(t("SSD 测速", "SSD speed test"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { dismiss() }.disabled(camera.ssdSpeedTesting) } }
            .interactiveDismissDisabled(camera.ssdSpeedTesting)
            .onAppear { camera.refreshSSDSpeedAssessment() }
            .onChange(of: camera.selectedEncoding) { _, _ in camera.refreshSSDSpeedAssessment() }
            .onChange(of: camera.selectedFormatIndex) { _, _ in camera.refreshSSDSpeedAssessment() }
            .onChange(of: camera.fps) { _, _ in camera.refreshSSDSpeedAssessment() }
            .onDisappear { if camera.ssdSpeedTesting { camera.cancelSSDSpeedTest() } }
        }
    }
    private func metric(_ name: String, _ value: Double, _ unit: String) -> some View {
        HStack { Text(name); Spacer(); Text(String(format: "%.0f %@", value, unit)).foregroundStyle(.secondary).monospacedDigit() }
    }
    private func assessmentColor(_ result: SSDSpeedReport) -> Color {
        switch result.assessment { case .usable: return .green; case .risky: return .orange; case .insufficient: return .red }
    }
    private func assessmentTitle(_ result: SSDSpeedReport) -> String {
        switch result.assessment {
        case .usable: return t("可用", "Usable")
        case .risky: return t("有风险", "At risk")
        case .insufficient: return t("不够用（按估算）", "Insufficient (estimated)")
        }
    }
}
