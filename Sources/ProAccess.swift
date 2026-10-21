import StoreKit
import MarketplaceKit
import SwiftUI
import OSLog

/// Camera queues read only this small locked snapshot, never StoreKit or UI state.
final class ProRecordingAccess {
    static let shared = ProRecordingAccess()
    private let lock = NSLock()
    #if TESTFLIGHT_FREE
    private var value = true
    #else
    private var value = false
    #endif
    var unlimited: Bool {
        #if DEBUG && !TESTFLIGHT_FREE
        // Exercise the full recording deadline without changing sandbox purchases.
        if ProcessInfo.processInfo.arguments.contains("--pro-free-limit-realtime-qa") { return false }
        #endif
        lock.lock(); defer { lock.unlock() }; return value
    }
    func update(unlimited: Bool) {
        lock.lock()
        #if TESTFLIGHT_FREE
        value = true
        #else
        value = unlimited
        #endif
        lock.unlock()
    }

    static func freeLimit(codec: String, purchased: Bool, bypass: Bool) -> TimeInterval? {
        ["aprn", "aprh", "apch", "apcn", "apcs", "apco"].contains(codec) && !purchased && !bypass ? 120 : nil
    }

    static func permitsBypass(enabled: Bool, distributor: AppDistributor) -> Bool {
        guard enabled else { return false }
        if case .testFlight = distributor { return true }
        return false
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
        #if TESTFLIGHT_FREE
        testFlightBypass = true
        publishAccess()
        return
        #else
        guard !prepared else {
            await refreshEntitlements()
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
        #endif
    }

    #if !TESTFLIGHT_FREE
    private func refreshTestFlightBypass() async {
        // StoreKit's purchase environment isn't an installation-source signal.
        // MarketplaceKit identifies TestFlight directly and keeps App Store
        // installs subject to the normal RAW limit.
        let configuredBypass = Bundle.main.object(forInfoDictionaryKey: "GyroCineTestFlightProBypass")
        let bypassEnabled = (configuredBypass as? Bool == true) ||
            (configuredBypass as? String).map { ["YES", "TRUE", "1"].contains($0.uppercased()) } == true
        guard bypassEnabled else { return }
        do {
            let distributor = try await AppDistributor.current
            testFlightBypass = ProRecordingAccess.permitsBypass(enabled: true, distributor: distributor)
            publishAccess()
            recordDistributorDiagnostic(source: String(describing: distributor))
            logger.info("App distributor: \(String(describing: distributor), privacy: .public); TestFlight RAW bypass active: \(self.testFlightBypass)")
        } catch {
            recordDistributorDiagnostic(source: "error: \(error.localizedDescription)")
            logger.error("App distributor unavailable; RAW free limit remains active: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordDistributorDiagnostic(source: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let payload: [String: Any] = [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "source": source,
            "testFlightBypass": testFlightBypass,
            "checkedAt": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("pro_access.json"), options: .atomic)
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--pro-sandbox-diagnostic") {
            NSLog("GyroCine verified Pro entitlement: %@", active ? "yes" : "no")
            if let latest = await Transaction.latest(for: Self.productID) {
                switch latest {
                case .verified(let transaction):
                    NSLog("GyroCine latest Pro transaction: verified, environment=%@, revoked=%@, type=%@",
                          String(describing: transaction.environment),
                          transaction.revocationDate == nil ? "no" : "yes",
                          String(describing: transaction.productType))
                case .unverified: NSLog("GyroCine latest Pro transaction: unverified")
                }
            } else { NSLog("GyroCine latest Pro transaction: none") }
        }
        #endif
    }
    #endif

    private func publishAccess() {
        ProRecordingAccess.shared.update(unlimited: purchased || testFlightBypass)
    }

    #if !TESTFLIGHT_FREE
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

    func completeRedemption(_ result: Result<Void, Error>) async {
        // Closing a redemption sheet is not proof of purchase.
        if case .failure(let error) = result {
            if (error as? SKError)?.code != .paymentCancelled { message = error.localizedDescription }
        }
        await refreshEntitlements()
    }

    func acceptRedemption(_ result: Result<VerificationResult<StoreKit.Transaction>, Error>) async {
        switch result {
        case .success(.verified(let transaction)):
            guard transaction.productID == Self.productID,
                  transaction.productType == .nonConsumable,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { return }
            purchased = true
            publishAccess()
            await transaction.finish()
        case .success(.unverified):
            message = AppText.value("无法验证兑换结果，请稍后恢复购买。", "Unable to verify redemption. Please try Restore Purchases later.", locale: .current)
        case .failure(let error): await completeRedemption(.failure(error))
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        // A verified current entitlement already proves ownership. Avoid an
        // unnecessary authentication prompt after a successful redemption.
        await refreshEntitlements()
        if purchased {
            message = AppText.value("已恢复 Pro 购买。", "Pro purchase restored.", locale: .current)
            return
        }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            message = purchased
                ? AppText.value("已恢复 Pro 购买。", "Pro purchase restored.", locale: .current)
                : AppText.value("此 Apple 账户暂无 Pro 购买记录。", "No Pro purchase was found for this Apple Account.", locale: .current)
        } catch {
            message = error.localizedDescription
            var details: [String] = []
            var current: NSError? = error as NSError
            if let storeError = error as? StoreKitError {
                switch storeError {
                case .systemError(let underlying): current = underlying as NSError
                case .networkError(let underlying): current = underlying as NSError
                default: break
                }
            }
            for _ in 0..<6 {
                guard let item = current else { break }
                details.append("\(item.domain):\(item.code)")
                current = item.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            // Log codes only; StoreKit userInfo can contain account and signed data.
            logger.error("Restore failed: \(details.joined(separator: " -> "), privacy: .public)")
            #if DEBUG
            NSLog("GyroCine restore failed: %@", details.joined(separator: " -> "))
            #endif
        }
    }
    #endif
}

#if TESTFLIGHT_FREE
struct ProAccessView: View {
    @Environment(\.dismiss) private var dismiss
    var limitReached = false

    var body: some View {
        NavigationStack {
            Form {
                Label("TestFlight · ProRes 长录制已开放", systemImage: "testtube.2")
                    .foregroundStyle(.green)
            }
            .navigationTitle("GyroCine")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
#else
struct ProAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @ObservedObject private var store = ProStore.shared
    @State private var showingRedemption = false
    var limitReached = false
    private func t(_ zh: String, _ en: String) -> String { AppText.value(zh, en, locale: locale) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("GyroCine Pro", systemImage: "camera.aperture")
                        .font(.title2.bold()).padding(.vertical, 8)
                    if limitReached {
                        Text(t("已达到本段 ProRes 的 2 分钟免费时长，录制已停止并按正常流程保存。",
                               "This ProRes clip reached the free 2-minute limit. Recording stopped and is being saved normally."))
                    }
                    if !store.purchased && !store.testFlightBypass {
                        Text(t("一次性购买，解锁所有 ProRes 及 ProRes RAW 格式的长时间录制。",
                               "A one-time purchase unlocks longer recordings in all ProRes and ProRes RAW formats."))
                        Text(t("免费版：每段 ProRes / ProRes RAW 最长 2 分钟。H.265 及其他功能免费。",
                               "Free: up to 2 minutes per ProRes / ProRes RAW clip. H.265 and all other features remain free."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
                        if !store.testFlightBypass {
                            if let product = store.product {
                                Button(t("一次性解锁 · \(product.displayPrice)", "Unlock once · \(product.displayPrice)")) {
                                    Task { await store.purchase() }
                                }.accessibilityIdentifier("purchasePro")
                            } else {
                                Text(t("购买项目暂不可用，请稍后重试。", "Purchase is temporarily unavailable. Please try again later."))
                                Button(t("重新加载", "Reload")) { Task { await store.loadProduct() } }
                            }
                        }
                    }
                    if !store.purchased {
                        Button {
                            store.message = nil
                            showingRedemption = true
                        } label: {
                            Label(t("兑换优惠码", "Redeem Offer Code"), systemImage: "gift")
                        }.accessibilityIdentifier("redeemPro")
                        Text(t("使用 GyroCine Pro 优惠码兑换永久使用权。", "Redeem a GyroCine Pro offer code for lifetime access."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !store.purchased {
                        Button(t("恢复购买", "Restore Purchases")) { Task { await store.restore() } }
                            .accessibilityIdentifier("restorePro")
                    }
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
            .modifier(ProRedemptionSheet(isPresented: $showingRedemption, store: store))
            .task { await store.prepare() }
        }
    }
}
#endif

#if !TESTFLIGHT_FREE
private struct ProRedemptionSheet: ViewModifier {
    @Binding var isPresented: Bool
    let store: ProStore
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.offerCodeRedemption(options: [], isPresented: $isPresented) { result in
                Task { await store.acceptRedemption(result) }
            }
        } else {
            content.offerCodeRedemption(isPresented: $isPresented) { result in
                Task { await store.completeRedemption(result) }
            }
        }
    }
}
#endif
