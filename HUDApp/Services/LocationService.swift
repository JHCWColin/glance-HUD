import Foundation
@preconcurrency import CoreLocation

enum LocationServiceError: LocalizedError, Sendable {
    case servicesDisabled
    case denied
    case restricted
    case noLocation

    var errorDescription: String? {
        switch self {
        case .servicesDisabled:
            return "Location Services is disabled."
        case .denied:
            return "Location permission was denied."
        case .restricted:
            return "Location permission is restricted."
        case .noLocation:
            return "Unable to determine the current location."
        }
    }
}

@MainActor
final class LocationService: NSObject {
    private let locationManager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestCurrentLocation() async throws -> CLLocationCoordinate2D {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationServiceError.servicesDisabled
        }

        let status = locationManager.authorizationStatus
        let resolvedStatus: CLAuthorizationStatus

        if status == .notDetermined {
            resolvedStatus = await requestAuthorization()
        } else {
            resolvedStatus = status
        }

        switch resolvedStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return try await withCheckedThrowingContinuation { continuation in
                locationContinuation = continuation
                locationManager.requestLocation()
            }
        case .denied:
            throw LocationServiceError.denied
        case .restricted:
            throw LocationServiceError.restricted
        case .notDetermined:
            throw LocationServiceError.noLocation
        @unknown default:
            throw LocationServiceError.noLocation
        }
    }

    private func requestAuthorization() async -> CLAuthorizationStatus {
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            locationManager.requestWhenInUseAuthorization()
        }
    }
}

@MainActor
extension LocationService: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationContinuation?.resume(returning: manager.authorizationStatus)
        authorizationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.first?.coordinate else {
            locationContinuation?.resume(throwing: LocationServiceError.noLocation)
            locationContinuation = nil
            return
        }

        locationContinuation?.resume(returning: coordinate)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }
}
