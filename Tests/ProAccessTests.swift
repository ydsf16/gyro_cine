import XCTest
import StoreKit
import StoreKitTest
import MarketplaceKit
import UIKit
@testable import GyroCine

final class ProAccessTests: XCTestCase {
    func testAllProResFormatsHaveFreeLimit() {
        for codec in ["aprn", "aprh", "apch", "apcn", "apcs", "apco"] {
            XCTAssertEqual(ProRecordingAccess.freeLimit(codec: codec, purchased: false, bypass: false), 120)
            XCTAssertNil(ProRecordingAccess.freeLimit(codec: codec, purchased: true, bypass: false))
            XCTAssertNil(ProRecordingAccess.freeLimit(codec: codec, purchased: false, bypass: true))
        }
        for codec in ["hvc1", "avc1", "hevc", ""] {
            XCTAssertNil(ProRecordingAccess.freeLimit(codec: codec, purchased: false, bypass: false))
        }
    }

    func testOnlyTestFlightDistributorUnlocksWithBuildFlag() {
        for distributor in [AppDistributor.appStore, .other, .web, .marketplace("example.marketplace")] {
            XCTAssertFalse(ProRecordingAccess.permitsBypass(enabled: true, distributor: distributor))
        }
        XCTAssertFalse(ProRecordingAccess.permitsBypass(enabled: false, distributor: .testFlight))
        XCTAssertTrue(ProRecordingAccess.permitsBypass(enabled: true, distributor: .testFlight))
    }

    #if TESTFLIGHT_FREE
    func testFreeTestFlightBuildCannotReenableRAWLimit() {
        XCTAssertTrue(ProRecordingAccess.shared.unlimited)
        ProRecordingAccess.shared.update(unlimited: false)
        XCTAssertTrue(ProRecordingAccess.shared.unlimited)
    }
    #else
    @MainActor
    func testLocalStoreKitPurchaseRestoreAndRefund() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.arguments.contains("--commerce-tests"),
            "Run the CommerceQA scheme to bind the local StoreKit configuration.")
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "GyroCine", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.disableDialogs = true
        try XCTSkipUnless(session.disableDialogs, "StoreKitTest service could not apply its local configuration.")
        session.clearTransactions()
        defer { session.clearTransactions() }
        let store = ProStore()
        await store.refreshEntitlements()
        XCTAssertFalse(store.purchased)
        await store.completeRedemption(.success(()))
        XCTAssertFalse(store.purchased, "Closing redemption without a transaction must not unlock Pro")
        await store.completeRedemption(.failure(SKError(.paymentCancelled)))
        XCTAssertFalse(store.purchased)
        XCTAssertNil(store.message)
        await store.loadProduct()
        XCTAssertEqual(store.product?.id, ProStore.productID)
        await ProStore.shared.loadProduct()
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) {
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "pro-local-storekit-review"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // The test host can start before SwiftUI has attached its purchase anchor.
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .contains(where: { $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .seconds(1))
        await store.purchase()
        XCTAssertTrue(store.purchased, store.message ?? "No verified entitlement")
        let redeemed = ProStore()
        for await result in StoreKit.Transaction.currentEntitlements {
            await redeemed.acceptRedemption(.success(result))
        }
        XCTAssertTrue(redeemed.purchased, "Verified Pro transaction should unlock redemption")
        let refreshed = ProStore()
        await refreshed.completeRedemption(.success(()))
        XCTAssertTrue(refreshed.purchased, "Legacy redemption must refresh verified entitlements")
        let restored = ProStore()
        await restored.restore()
        XCTAssertTrue(restored.purchased, restored.message ?? "Restore failed")
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        // StoreKit publishes a revocation asynchronously after the refund call.
        for _ in 0..<100 {
            await restored.refreshEntitlements()
            if !restored.purchased { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(restored.purchased)
        XCTAssertFalse(ProRecordingAccess.shared.unlimited)
    }
    #endif
}
