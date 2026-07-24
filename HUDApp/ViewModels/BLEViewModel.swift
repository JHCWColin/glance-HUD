import Combine
import SwiftUI
import UIKit

@MainActor
final class BLEViewModel: ObservableObject {
    @Published var connectionStatus = "Disconnected"
    @Published var connectedDeviceName = "No Device"
    @Published var currentTime = "--:--"
    @Published var currentDate = "---- -- --"
    @Published var weatherDisplay = "--"
    @Published var batteryDisplay = "Battery --%"
    @Published var customMessage = ""
    @Published var logs: [BLELogEntry] = []
    @Published var isConnected = false

    private let bleService: BLEService
    private let weatherService: WeatherService
    private let locationService: LocationService
    private var clockCancellable: AnyCancellable?
    private var weatherCancellable: AnyCancellable?
    private var weatherTask: Task<Void, Never>?
    private var startCompleted = false
    private var lastMinuteToken: String?
    private var latestWeather: WeatherSnapshot?

    init() {
        self.bleService = BLEService()
        self.weatherService = WeatherService()
        self.locationService = LocationService()
        configureServices()
    }

    init(
        bleService: BLEService,
        weatherService: WeatherService,
        locationService: LocationService
    ) {
        self.bleService = bleService
        self.weatherService = weatherService
        self.locationService = locationService
        configureServices()
    }

    private func configureServices() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        bleService.delegate = self
    }

    func start() {
        guard !startCompleted else {
            return
        }

        startCompleted = true
        appendLocalLog("App started on \(Date.now.formatted(date: .abbreviated, time: .standard)).", level: .info)
        updateClockAndStatus(sendPackets: false)
        bleService.start()
        startTimers()
        refreshWeather()
    }

    func scanForDevices() {
        bleService.startScan()
    }

    func disconnect() {
        bleService.disconnect()
    }

    func refreshWeather() {
        weatherTask?.cancel()
        weatherTask = Task {
            do {
                appendLocalLog("Refreshing weather from Open-Meteo.", level: .info)
                let coordinate = try await locationService.requestCurrentLocation()
                let weather = try await weatherService.fetchWeather(for: coordinate)
                latestWeather = weather
                weatherDisplay = weather.displayText
                appendLocalLog("Weather updated to \(weather.displayText).", level: .success)

                if bleService.isReadyToSend {
                    bleService.send(packet: HUDPacket(type: .weather, text: weather.hudText))
                }
            } catch is CancellationError {
                return
            } catch {
                appendLocalLog("Weather refresh failed: \(error.localizedDescription)", level: .error)
            }
        }
    }

    func sendCustomMessage() {
        let trimmed = customMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLocalLog("Custom message is empty.", level: .warning)
            return
        }

        guard bleService.isReadyToSend else {
            appendLocalLog("Cannot send custom text while BLE is disconnected.", level: .warning)
            return
        }

        bleService.send(packet: HUDPacket(type: .message, text: trimmed))
        customMessage = ""
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            appendLocalLog("App became active. Refreshing BLE and weather.", level: .info)
            updateClockAndStatus(sendPackets: false)
            bleService.resumeConnectionFlow()
            refreshWeather()
        case .background:
            appendLocalLog("App moved to background.", level: .info)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func startTimers() {
        clockCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateClockAndStatus(sendPackets: true)
            }

        weatherCancellable = Timer.publish(every: 900, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshWeather()
            }
    }

    private func updateClockAndStatus(sendPackets: Bool) {
        let now = Date()
        currentTime = Self.clockFormatter.string(from: now)

        if sendPackets && bleService.isReadyToSend {
            bleService.send(packet: HUDPacket(type: .clock, text: currentTime))
        }

        let minuteToken = Self.minuteTokenFormatter.string(from: now)
        guard minuteToken != lastMinuteToken else {
            return
        }

        lastMinuteToken = minuteToken
        currentDate = Self.dateFormatter.string(from: now)
        batteryDisplay = formattedBatteryDisplay()

        if sendPackets && bleService.isReadyToSend {
            bleService.send(packet: HUDPacket(type: .date, text: currentDate))

            if let batteryText = batteryPayloadText() {
                bleService.send(packet: HUDPacket(type: .battery, text: batteryText))
            }
        }
    }

    private func sendSnapshotToHUD() {
        updateClockAndStatus(sendPackets: false)

        guard bleService.isReadyToSend else {
            return
        }

        bleService.send(packet: HUDPacket(type: .clock, text: currentTime))
        bleService.send(packet: HUDPacket(type: .date, text: currentDate))

        if let batteryText = batteryPayloadText() {
            bleService.send(packet: HUDPacket(type: .battery, text: batteryText))
        }

        if let latestWeather {
            bleService.send(packet: HUDPacket(type: .weather, text: latestWeather.hudText))
        }
    }

    private func batteryPayloadText() -> String? {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else {
            return nil
        }

        return "\(Int((level * 100).rounded()))%"
    }

    private func formattedBatteryDisplay() -> String {
        guard let batteryPayloadText = batteryPayloadText() else {
            return "Battery --%"
        }

        return "Battery \(batteryPayloadText)"
    }

    private func appendLocalLog(_ message: String, level: BLELogLevel) {
        logs.append(BLELogEntry(timestamp: Date(), level: level, message: message))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let minuteTokenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

extension BLEViewModel: BLEServiceDelegate {
    func bleService(_ service: BLEService, didUpdateConnectionState state: BLEConnectionState) {
        switch state {
        case .idle:
            connectionStatus = "Idle"
            isConnected = false

        case .bluetoothUnavailable(let reason):
            connectionStatus = reason
            isConnected = false

        case .scanning:
            connectionStatus = "Scanning"
            isConnected = false

        case .connecting(let deviceName):
            connectionStatus = "Connecting"
            connectedDeviceName = deviceName
            isConnected = false

        case .connected(let deviceName):
            connectionStatus = "Connected"
            connectedDeviceName = deviceName
            isConnected = true

        case .disconnected:
            connectionStatus = "Disconnected"
            isConnected = false
        }
    }

    func bleService(_ service: BLEService, didLog entry: BLELogEntry) {
        logs.append(entry)
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    func bleServiceDidBecomeReady(_ service: BLEService) {
        appendLocalLog("BLE link is ready for HUD sync.", level: .success)
        sendSnapshotToHUD()
    }
}
