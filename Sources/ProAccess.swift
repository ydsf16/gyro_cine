import StoreKit
import SwiftUI
import OSLog

/// Camera queues read only this small locked snapshot, never StoreKit or UI state.
final class ProRecordingAccess {
    static let shared = ProRecordingAccess()
    private let lock = NSLock()
    private var value = false
    var unlimited: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func update(unlimited: Bool) { lock.lock(); value = unlimited; lock.unlock() }

    static func freeLimit(codec: String, purchased: Bool, bypass: Bool) -> TimeInterval? {
        ["aprn", "aprh"].contains(codec) && !purchased && !bypass ? 120 : nil
    }

    static func permitsBypass(enabled: Bool, verifiedEnvironment: String) -> Bool {
        enabled && verifiedEnvironment == "Sandbox"
    }
}

@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.tinygrape.gyrocine.pro"
    private let logger = Logger(subsystem: "com.tinygrape.RawMotionRecorder", category: "ProAccess")
    @Published private(set) var product: Product?
    @Published private(set) var purchased = false
    @Published private(set) var testFlightBypass = false
    @Published private(set) var busy = false
    @Published var message: String?
    private var updates: Task<Void, Never>?
    private var prepared = false

    func prepare() async {
        guard !prepared else {
            await refreshTestFlightBypass()
            return
        }
        prepared = true
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result,
                      transaction.productID == Self.productID else { continue }
                if transaction.revocationDate != nil {
                    self?.purchased = false
                    self?.publishAccess()
                } else {
                    await self?.refreshEntitlements()
                }
                await transaction.finish()
            }
        }
        await refreshEntitlements()
        await refreshTestFlightBypass()
        await loadProduct()
    }

    private func refreshTestFlightBypass() async {
        // The signed app transaction is the authority. The legacy receipt file
        // may be absent even for a valid TestFlight installation.
        let configuredBypass = Bundle.main.object(forInfoDictionaryKey: "GyroCineTestFlightProBypass")
        let bypassEnabled = (configuredBypass as? Bool == true) ||
            (configuredBypass as? String).map { ["YES", "TRUE", "1"].contains($0.uppercased()) } == true
        guard bypassEnabled else { return }
        do {
            switch try await AppTransaction.shared {
            case .verified(let transaction):
                testFlightBypass = ProRecordingAccess.permitsBypass(enabled: true,
                    verifiedEnvironment: transaction.environment == .sandbox ? "Sandbox" : "Production")
                publishAccess()
                logger.info("App transaction verified; sandbox bypass active: \(self.testFlightBypass)")
            case .unverified:
                logger.error("App transaction unverified; RAW free limit remains active")
            }
        } catch {
            logger.error("App transaction unavailable; RAW free limit remains active: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadProduct() async {
        do { product = try await Product.products(for: [Self.productID]).first }
        catch { message = error.localizedDescription }
    }

    func refreshEntitlements() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil, !transaction.isUpgraded,
               transaction.productType == .nonConsumable { active = true }
        }
        purchased = active
        publishAccess()
    }

    private func publishAccess() {
        ProRecordingAccess.shared.update(unlimited: purchased || testFlightBypass)
    }

    func purchase() async {
        guard !busy, let product else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                guard transaction.productID == Self.productID,
                      transaction.revocationDate == nil,
                      transaction.productType == .nonConsumable else { return }
                purchased = true; publishAccess()
                await transaction.finish()
            case .success(.unverified):
                message = AppText.value("无法验证购买，请稍后重试。", "Unable to verify this purchase. Please try again.", locale: .current)
            case .pending:
                message = AppText.value("购买等待批准，批准后会自动解锁。", "Purchase pending approval. Pro unlocks automatically after approval.", locale: .current)
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = purchased
                ? AppText.value("已恢复 Pro 购买。", "Pro purchase restored.", locale: .current)
                : AppText.value("此 Apple 账户暂无 Pro 购买记录。", "No Pro purchase was found for this Apple Account.", locale: .current)
        } catch { message = error.localizedDescription }
    }
}

struct ProAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ObservedObject private var store = ProStore.shared
    var limitReached = false
    private func t(_ zh: String, _ en: String) -> String { AppText.value(zh, en, locale: locale) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("GyroCine Pro", systemImage: "camera.aperture")
                        .font(.title2.bold()).padding(.vertical, 8)
                    if limitReached {
                        Text(t("已达到本段 RAW 的 2 分钟免费时长，录制已停止并按正常流程保存。",
                               "This RAW clip reached the free 2-minute limit. Recording stopped and is being saved normally."))
                    }
                    Text(t("一次性购买，解锁 ProRes RAW 与 ProRes RAW HQ 长时间录制。",
                           "A one-time purchase unlocks longer ProRes RAW and ProRes RAW HQ recordings."))
                    Text(t("免费版：每段 RAW 最长 2 分钟。H.265 及其他功能免费。",
                           "Free: up to 2 minutes per RAW clip. H.265 and all other features remain free."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if store.purchased {
                        Label(t("Pro 已解锁", "Pro unlocked"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        if store.testFlightBypass {
                            Label(t("TestFlight 测试：长录制已开放", "TestFlight: longer recordings enabled"), systemImage: "testtube.2")
                            Text(t("此测试构建已跳过免费时长限制；仍可测试沙盒购买与恢复。",
                                   "This test build bypasses the free limit. Sandbox purchase and restore remain available."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let product = store.product {
                            Button(t("一次性解锁 · \(product.displayPrice)", "Unlock once · \(product.displayPrice)")) {
                                Task { await store.purchase() }
                            }.accessibilityIdentifier("purchasePro")
                        } else {
                            Text(t("购买项目暂不可用，请稍后重试。", "Purchase is temporarily unavailable. Please try again later."))
                            Button(t("重新加载", "Reload")) { Task { await store.loadProduct() } }
                        }
                    }
                    Button(t("恢复购买", "Restore Purchases")) { Task { await store.restore() } }
                        .accessibilityIdentifier("restorePro")
                    if store.busy { ProgressView() }
                    if let message = store.message { Text(message).font(.footnote) }
                }.disabled(store.busy)
                Section {
                    Text(t("长录制仍受设备、温度、存储容量及持续写入速度限制。",
                           "Recording length remains subject to device, temperature, available space and sustained write speed."))
                        .font(.footnote).foregroundStyle(.secondary)
                    Link(t("隐私政策", "Privacy Policy"), destination: URL(string: "https://tinygrapelab.com/gyro_cine/privacy.html")!)
                    Link(t("帮助与支持", "Help & Support"), destination: URL(string: "https://tinygrapelab.com/gyro_cine/")!)
                }
            }
            .navigationTitle("GyroCine Pro").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(t("完成", "Done")) { dismiss() } } }
            .task { await store.prepare() }
        }
    }
}
