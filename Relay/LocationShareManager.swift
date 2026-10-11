//
//  LocationShareManager.swift
//  Relay
//
//  Live location sharing within one conversation. Coordinates go out as
//  encrypted messages: the body prefix "__relay_loc__" followed by JSON,
//  {"lat":0.0,"lng":0.0,"exp":1234567890,"stop":false}
//    lat/lng: WGS84 decimal degrees
//    exp:     Unix time (ms) when sharing expires
//    stop:    true when the sender has stopped sharing
//

import CoreLocation
import Foundation
import Observation

let locationPrefix = "__relay_loc__"

// MARK: - Payload

struct LocationPayload: Codable {
    var lat: Double
    var lng: Double
    var exp: Int64
    var stop: Bool

    var isExpired: Bool {
        Int64(Date().timeIntervalSince1970 * 1000) > exp
    }

    static func decode(_ body: String) -> LocationPayload? {
        guard body.hasPrefix(locationPrefix) else { return nil }
        let json = String(body.dropFirst(locationPrefix.count))
        return try? JSONDecoder().decode(LocationPayload.self, from: Data(json.utf8))
    }

    func encode() -> String {
        let json = (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return locationPrefix + json
    }
}

// MARK: - Manager

@Observable
final class LocationShareManager: NSObject, CLLocationManagerDelegate {

    static let shared = LocationShareManager()

    private(set) var sharingConversationId: String?
    private(set) var expiresAt: Date?
    private(set) var latestLocation: CLLocation?

    // Latest known location per conversation, for rendering bubbles.
    private(set) var peerLocations: [String: LocationPayload] = [:]

    private let clManager = CLLocationManager()
    /// Keeps updates flowing (with the blue indicator) while Relay is in the
    /// background, for as long as a share is running.
    private var backgroundSession: CLBackgroundActivitySession?
    private var updateTask: Task<Void, Never>?
    private weak var service: MessagingService?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    // MARK: - Start / stop

    func start(in conversationId: String, duration: TimeInterval, service: MessagingService) {
        guard sharingConversationId == nil else { return }
        self.service = service
        sharingConversationId = conversationId
        expiresAt = Date().addingTimeInterval(duration)
        clManager.requestWhenInUseAuthorization()
        backgroundSession = CLBackgroundActivitySession()
        clManager.allowsBackgroundLocationUpdates = true
        clManager.showsBackgroundLocationIndicator = true
        clManager.startUpdatingLocation()
        scheduleUpdates()
    }


    func stop(in conversationId: String) {
        guard sharingConversationId == conversationId else { return }
        sendStop(conversationId: conversationId)
        teardown()
    }

    /// Sign-out or wipe: stop GPS and the background session without sending.
    func stopAll() {
        teardown()
    }

    private func teardown() {
        clManager.stopUpdatingLocation()
        clManager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        updateTask?.cancel()
        updateTask = nil
        sharingConversationId = nil
        expiresAt = nil
    }

    // MARK: - Periodic sends

    private func scheduleUpdates() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if let exp = self.expiresAt, Date() > exp {
                    if let convId = self.sharingConversationId {
                        self.sendStop(conversationId: convId)
                    }
                    self.teardown()
                    return
                }
                await self.sendCurrentLocation()
            }
        }
    }

    private func sendCurrentLocation() async {
        guard let convId = sharingConversationId,
              let loc = latestLocation,
              let exp = expiresAt,
              let service else { return }
        let payload = LocationPayload(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            exp: Int64(exp.timeIntervalSince1970 * 1000),
            stop: false
        )
        await service.sendLiveLocation(payload.encode(), in: convId)
    }

    private func sendStop(conversationId: String) {
        guard let service else { return }
        let loc = latestLocation ?? CLLocation(latitude: 0, longitude: 0)
        let payload = LocationPayload(
            lat: loc.coordinate.latitude,
            lng: loc.coordinate.longitude,
            exp: Int64(Date().timeIntervalSince1970 * 1000),
            stop: true
        )
        Task { await service.sendLiveLocation(payload.encode(), in: conversationId) }
    }

    // MARK: - Incoming payloads

    func handleIncoming(payload: LocationPayload, fromConversation conversationId: String) {
        if payload.stop || payload.isExpired {
            peerLocations.removeValue(forKey: conversationId)
        } else {
            peerLocations[conversationId] = payload
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
    }
}
