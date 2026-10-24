import AVFoundation
import CoreLocation
import Combine
import UIKit

/// Foreground-only location, read as a nonblocking snapshot by each recorder.
final class RecordingLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RecordingLocation()
    static let preferenceKey = "recordLocation"
    static let metadataKey = "com.apple.quicktime.location.ISO6709"
    enum Status { case off, waiting, ready, denied }
    @Published private(set) var status: Status = .off
    private var manager: CLLocationManager?
    private var active = false
    private let lock = NSLock()
    private var latest: CLLocation?
    private var authorized = false

    private override init() {
        super.init()
        DispatchQueue.main.async {
            let manager = CLLocationManager()
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
            self.manager = manager
            manager.delegate = self
            self.refresh(requestPermission: self.active)
        }
    }

    /// Called on the main thread from the app lifecycle and Settings.
    func setActive(_ active: Bool) {
        self.active = active
        refresh(requestPermission: active)
    }

    func refresh(requestPermission: Bool = false) {
        guard let manager else { return }
        let enabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        let permission = manager.authorizationStatus
        let allowed = permission == .authorizedAlways || permission == .authorizedWhenInUse
        lock.lock()
        authorized = allowed && active && enabled
        if !authorized { latest = nil }
        lock.unlock()
        guard enabled && active else {
            manager.stopUpdatingLocation(); status = .off; return
        }
        if allowed {
            status = snapshot().isEmpty ? .waiting : .ready
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
            status = permission == .denied || permission == .restricted ? .denied : .waiting
            if requestPermission && permission == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { refresh() }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lock.lock()
        if authorized { latest = location }
        lock.unlock()
        status = snapshot().isEmpty ? .waiting : .ready
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lock.lock(); latest = nil; lock.unlock()
        status = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted ? .denied : .waiting
    }

    func snapshot() -> [AVMetadataItem] {
        lock.lock(); let location = latest; let allowed = authorized; lock.unlock()
        return Self.metadata(location, enabled: UserDefaults.standard.bool(forKey: Self.preferenceKey), authorized: allowed)
    }

    /// Never attach stale, invalid or unauthorized coordinates. No GPS wait on the capture queue.
    static func metadata(_ location: CLLocation?, enabled: Bool, authorized: Bool, now: Date = Date()) -> [AVMetadataItem] {
        guard enabled, authorized, let location,
              CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
              (-5...60).contains(now.timeIntervalSince(location.timestamp)) else { return [] }
        func component(_ value: Double, digits: Int) -> String {
            let text = String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), abs(value))
            return (value.sign == .minus ? "-" : "+") + String(repeating: "0", count: max(0, digits + 6 - text.count)) + text
        }
        let value = component(location.coordinate.latitude, digits: 2) + component(location.coordinate.longitude, digits: 3) + "/"
        return RecordingMetadata.items([metadataKey: value])
    }
}
