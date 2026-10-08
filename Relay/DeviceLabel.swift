//
//  DeviceLabel.swift
//  Relay
//
//  The human-readable label for this device ("iPhone 17 Pro · Queensland,
//  Australia") shown in Linked Devices. It is shared ONLY with the account's
//  own other devices, sealed end-to-end (Content.device_info); the relay never
//  sees a model name or a location. The region comes from an approximate
//  (reduced-accuracy) location, reverse-geocoded on-device by Apple's geocoder,
//  and only when the user has granted location access.
//

import CoreLocation
import Foundation
import UIKit

struct DeviceLabel: Codable, Equatable {
    var model: String
    var region: String
    var updatedAt: Int64

    /// "iPhone 17 Pro · Queensland, Australia", or just the model.
    var displayName: String {
        region.isEmpty ? model : "\(model) · \(region)"
    }
}

enum DeviceModel {
    /// Marketing name for this hardware ("iPhone 17 Pro"), falling back to the
    /// generic family ("iPhone"/"iPad") for identifiers not in the table.
    static var current: String {
        let id = hardwareIdentifier
        if let name = names[id] { return name }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private static var hardwareIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static let names: [String: String] = [
        // iPhone
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        // iPad Pro
        "iPad13,4": "iPad Pro 11-inch (3rd generation)", "iPad13,5": "iPad Pro 11-inch (3rd generation)",
        "iPad13,6": "iPad Pro 11-inch (3rd generation)", "iPad13,7": "iPad Pro 11-inch (3rd generation)",
        "iPad13,8": "iPad Pro 12.9-inch (5th generation)", "iPad13,9": "iPad Pro 12.9-inch (5th generation)",
        "iPad13,10": "iPad Pro 12.9-inch (5th generation)", "iPad13,11": "iPad Pro 12.9-inch (5th generation)",
        "iPad14,3": "iPad Pro 11-inch (4th generation)", "iPad14,4": "iPad Pro 11-inch (4th generation)",
        "iPad14,5": "iPad Pro 12.9-inch (6th generation)", "iPad14,6": "iPad Pro 12.9-inch (6th generation)",
        "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)",
        "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)",
        // iPad Air / mini / iPad
        "iPad13,16": "iPad Air (5th generation)", "iPad13,17": "iPad Air (5th generation)",
        "iPad14,8": "iPad Air 11-inch (M2)", "iPad14,9": "iPad Air 11-inch (M2)",
        "iPad14,10": "iPad Air 13-inch (M2)", "iPad14,11": "iPad Air 13-inch (M2)",
        "iPad14,1": "iPad mini (6th generation)", "iPad14,2": "iPad mini (6th generation)",
        "iPad16,1": "iPad mini (A17 Pro)", "iPad16,2": "iPad mini (A17 Pro)",
        "iPad13,18": "iPad (10th generation)", "iPad13,19": "iPad (10th generation)",
    ]
}

/// Resolves "State, Country" from an approximate location. Never prompts on
/// its own — `requestAccess()` is called from Linked Devices, where the user
/// sees why.
@MainActor
final class DeviceRegion: NSObject, CLLocationManagerDelegate {
    static let shared = DeviceRegion()

    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Region-level is all we need; never ask for precise location.
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    var canAsk: Bool { manager.authorizationStatus == .notDetermined }

    private static let enabledKey = "relay.deviceRegion.enabled"

    /// The user's explicit opt-in (from Linked Devices). Location permission
    /// granted for live-location sharing alone never enables this.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// Opts in, asking for location permission if it hasn't been decided.
    func enable() {
        isEnabled = true
        if canAsk {
            manager.requestWhenInUseAuthorization()
        } else {
            NotificationCenter.default.post(name: .deviceRegionAuthorizationChanged, object: nil)
        }
    }

    func disable() {
        isEnabled = false
        NotificationCenter.default.post(name: .deviceRegionAuthorizationChanged, object: nil)
    }

    /// "Queensland, Australia", or "" when not opted in, without permission,
    /// or on failure.
    func currentRegion() async -> String {
        guard isEnabled, isAuthorized else { return "" }
        guard let location = await oneLocation(),
              let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        else { return "" }
        let state = placemark.administrativeArea.map {
            placemark.isoCountryCode == "AU" ? Self.expandAustralianState($0) : $0
        } ?? ""
        let country = placemark.country ?? ""
        return [state, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func oneLocation() async -> CLLocation? {
        if let recent = manager.location, recent.timestamp.timeIntervalSinceNow > -3600 { return recent }
        return await withCheckedContinuation { continuation in
            pending?.resume(returning: nil)
            pending = continuation
            manager.requestLocation()
        }
    }

    /// The geocoder abbreviates Australian states ("QLD"); spell them out.
    private static func expandAustralianState(_ area: String) -> String {
        let au = ["QLD": "Queensland", "NSW": "New South Wales", "VIC": "Victoria",
                  "SA": "South Australia", "WA": "Western Australia", "TAS": "Tasmania",
                  "NT": "Northern Territory", "ACT": "Australian Capital Territory"]
        return au[area] ?? area
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in
            pending?.resume(returning: location)
            pending = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            pending?.resume(returning: nil)
            pending = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .deviceRegionAuthorizationChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let deviceRegionAuthorizationChanged = Notification.Name("relay.deviceRegionAuthorizationChanged")
}
