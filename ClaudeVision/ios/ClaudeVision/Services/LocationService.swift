import Foundation
import CoreLocation

/// One-shot location fetches for Trip mode. The glasses have no GPS —
/// coordinates always come from the paired iPhone.
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    enum LocationError: LocalizedError {
        case denied
        case unavailable

        var errorDescription: String? {
            switch self {
            case .denied: return "Location access denied — enable it in iOS Settings"
            case .unavailable: return "Couldn't determine your location"
            }
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func currentLocation() async throws -> CLLocation {
        // A fix from the last 2 minutes is plenty for a walking-radius search
        if let cached = manager.location, cached.timestamp.timeIntervalSinceNow > -120 {
            return cached
        }

        var status = manager.authorizationStatus
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                authContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            throw LocationError.denied
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authContinuation?.resume(returning: manager.authorizationStatus)
        authContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        locationContinuation?.resume(returning: location)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: LocationError.unavailable)
        locationContinuation = nil
    }
}
