import Foundation
@preconcurrency import CoreBluetooth

enum BLERuntimeEnvironment: String, Equatable, Sendable {
    case simulator
    case physicalDevice

    static var current: BLERuntimeEnvironment {
        #if targetEnvironment(simulator)
        return .simulator
        #else
        return .physicalDevice
        #endif
    }

    var title: String {
        switch self {
        case .simulator:
            return "iOS Simulator"
        case .physicalDevice:
            return "Physical iPhone"
        }
    }

    var detail: String {
        switch self {
        case .simulator:
            return "The simulator does not expose usable CoreBluetooth hardware, so BLE scan/connect cannot start here."
        case .physicalDevice:
            return "Running on real hardware. BLE discovery and connection can proceed if Bluetooth is powered on."
        }
    }

    var supportsBLEHardware: Bool {
        self == .physicalDevice
    }
}

enum BLEWorkflowStep: Equatable, Sendable {
    case startup
    case environmentCheck
    case bluetoothStateCheck
    case scanning
    case connecting
    case serviceDiscovery
    case characteristicDiscovery
    case ready
    case disconnected
    case packetWrite

    var title: String {
        switch self {
        case .startup:
            return "Startup"
        case .environmentCheck:
            return "Environment Check"
        case .bluetoothStateCheck:
            return "Bluetooth State Check"
        case .scanning:
            return "Scanning"
        case .connecting:
            return "Connecting"
        case .serviceDiscovery:
            return "Service Discovery"
        case .characteristicDiscovery:
            return "Characteristic Discovery"
        case .ready:
            return "Ready"
        case .disconnected:
            return "Disconnected"
        case .packetWrite:
            return "Packet Write"
        }
    }
}

struct BLEDiagnosticSnapshot: Equatable, Sendable {
    let environment: BLERuntimeEnvironment
    let currentStep: BLEWorkflowStep
    let detail: String
    let analysis: String
    let failureStep: BLEWorkflowStep?
    let failureReason: String?
    let isBlocking: Bool

    static var initial: BLEDiagnosticSnapshot {
        BLEDiagnosticSnapshot(
            environment: .current,
            currentStep: .startup,
            detail: "Waiting for BLE startup.",
            analysis: "The app has not started CoreBluetooth initialization yet.",
            failureStep: nil,
            failureReason: nil,
            isBlocking: false
        )
    }
}

enum BLEConnectionState: Equatable, Sendable {
    case idle
    case bluetoothUnavailable(reason: String)
    case scanning
    case connecting(deviceName: String)
    case connected(deviceName: String)
    case disconnected
}

@MainActor
protocol BLEServiceDelegate: AnyObject {
    func bleService(_ service: BLEService, didUpdateConnectionState state: BLEConnectionState)
    func bleService(_ service: BLEService, didUpdateDiagnostic snapshot: BLEDiagnosticSnapshot)
    func bleService(_ service: BLEService, didLog entry: BLELogEntry)
    func bleServiceDidBecomeReady(_ service: BLEService)
}

@MainActor
final class BLEService: NSObject {
    weak var delegate: BLEServiceDelegate? {
        didSet {
            if let delegate {
                delegate.bleService(self, didUpdateDiagnostic: diagnosticSnapshot)
            }
        }
    }

    private lazy var centralManager: CBCentralManager = {
        CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: HUDBLEConstants.stateRestorationIdentifier
            ]
        )
    }()

    private var activePeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var hasStarted = false
    private var isScanning = false
    private var manualDisconnect = false
    private var hasSignaledReady = false
    private var outboundQueue: [PendingTransmission] = []
    private var activeTransmission: PendingTransmission?
    private let runtimeEnvironment = BLERuntimeEnvironment.current
    private var diagnosticSnapshot = BLEDiagnosticSnapshot.initial

    var isReadyToSend: Bool {
        guard let activePeripheral, let writeCharacteristic else {
            return false
        }

        let properties = writeCharacteristic.properties
        let supportsWrite = properties.contains(.write) || properties.contains(.writeWithoutResponse)
        return activePeripheral.state == .connected && supportsWrite
    }

    var connectedDeviceName: String? {
        if let name = activePeripheral?.name, !name.isEmpty {
            return name
        }

        return UserDefaults.standard.string(forKey: HUDBLEConstants.lastPeripheralNameKey)
    }

    func start() {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        updateConnectionState(.idle)

        updateDiagnostic(
            step: .environmentCheck,
            detail: "Current environment: \(runtimeEnvironment.title).",
            analysis: runtimeEnvironment.detail
        )

        guard runtimeEnvironment.supportsBLEHardware else {
            let reason = "Running in iOS Simulator"
            updateDiagnosticFailure(
                step: .environmentCheck,
                reason: reason,
                analysis: "Failure happened before scan started because the simulator cannot provide a real Bluetooth radio."
            )
            updateConnectionState(.bluetoothUnavailable(reason: reason))
            emitLog(
                "Current environment is iOS Simulator. BLE scanning and connection require a real iPhone or iPad.",
                level: .error
            )
            return
        }

        updateDiagnostic(
            step: .bluetoothStateCheck,
            detail: "Waiting for CoreBluetooth to report the radio state.",
            analysis: "The next blocking point is whether iOS reports Bluetooth as powered on."
        )
        _ = centralManager
    }

    func startScan() {
        manualDisconnect = false

        guard runtimeEnvironment.supportsBLEHardware else {
            updateDiagnosticFailure(
                step: .environmentCheck,
                reason: "Manual scan requested in iOS Simulator",
                analysis: "The request stopped before scan because there is no BLE hardware in the simulator."
            )
            emitLog("Scan request ignored because the app is running in iOS Simulator.", level: .error)
            return
        }

        guard centralManager.state == .poweredOn else {
            emitLog("Bluetooth is not powered on yet.", level: .warning)
            updateDiagnosticFailure(
                step: .bluetoothStateCheck,
                reason: "Bluetooth is not powered on yet.",
                analysis: "Failure happened before scan because iOS has not exposed a usable Bluetooth radio yet."
            )
            return
        }

        if let activePeripheral, activePeripheral.state == .connected {
            updateConnectionState(.connected(deviceName: displayName(for: activePeripheral)))
            emitLog("Already connected to \(displayName(for: activePeripheral)).", level: .info)
            updateDiagnostic(
                step: .ready,
                detail: "Already connected to \(displayName(for: activePeripheral)).",
                analysis: "BLE transport is already established. You can send packets immediately."
            )
            return
        }

        guard !isScanning else {
            return
        }

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        updateConnectionState(.scanning)
        updateDiagnostic(
            step: .scanning,
            detail: "Scanning for peripherals named GlanceHUD, HUD Glasses, or XIAO-HUD.",
            analysis: "If the app stays here, the ESP32 is not advertising, the name does not match, or the phone is out of range."
        )
        emitLog("Scanning for GlanceHUD / HUD Glasses / XIAO-HUD.", level: .info)
    }

    func disconnect() {
        manualDisconnect = true
        stopScanningIfNeeded()
        resetTransmissionState()

        guard let activePeripheral else {
            updateConnectionState(.disconnected)
            updateDiagnostic(
                step: .disconnected,
                detail: "No active peripheral to disconnect.",
                analysis: "The BLE session is already idle. Tap Scan after the ESP32 starts advertising."
            )
            return
        }

        emitLog("Disconnecting from \(displayName(for: activePeripheral)).", level: .warning)
        centralManager.cancelPeripheralConnection(activePeripheral)
    }

    func resumeConnectionFlow() {
        manualDisconnect = false

        guard runtimeEnvironment.supportsBLEHardware else {
            updateDiagnosticFailure(
                step: .environmentCheck,
                reason: "Resume requested in iOS Simulator",
                analysis: "The app cannot restore or resume BLE work in the simulator because no Bluetooth hardware exists there."
            )
            return
        }

        guard centralManager.state == .poweredOn else {
            updateDiagnosticFailure(
                step: .bluetoothStateCheck,
                reason: "Bluetooth is not powered on yet.",
                analysis: "Resume stopped before scan because iOS has not exposed a usable Bluetooth radio yet."
            )
            return
        }

        if let activePeripheral {
            switch activePeripheral.state {
            case .connected:
                activePeripheral.delegate = self
                discoverHUDServices(on: activePeripheral)
                announceReadyIfPossible(on: activePeripheral)
                updateConnectionState(.connected(deviceName: displayName(for: activePeripheral)))
                updateDiagnostic(
                    step: .serviceDiscovery,
                    detail: "Using restored connection for \(displayName(for: activePeripheral)).",
                    analysis: "A peripheral is already connected. The app is re-validating services and characteristics."
                )
                return
            case .connecting:
                updateConnectionState(.connecting(deviceName: displayName(for: activePeripheral)))
                updateDiagnostic(
                    step: .connecting,
                    detail: "Resuming connection to \(displayName(for: activePeripheral)).",
                    analysis: "The peripheral was previously selected. The next blocking point is GATT link establishment."
                )
                return
            default:
                break
            }
        }

        attemptReconnectOrScan()
    }

    func send(packet: HUDPacket) {
        guard let activePeripheral, let writeCharacteristic, isReadyToSend else {
            return
        }

        let writeType = preferredWriteType(for: writeCharacteristic)
        let maxWriteLength = max(20, activePeripheral.maximumWriteValueLength(for: writeType))

        do {
            let payload = try packet.encodedData(appendingNewline: true)
            let summary = try packet.jsonString()
            let chunks = payload.chunked(into: maxWriteLength)

            outboundQueue.append(
                PendingTransmission(
                    summary: summary,
                    chunks: chunks,
                    writeType: writeType,
                    nextChunkIndex: 0
                )
            )

            processOutboundQueue()
        } catch {
            emitLog("Failed to encode packet: \(error.localizedDescription)", level: .error)
        }
    }

    private func attemptReconnectOrScan() {
        guard centralManager.state == .poweredOn else {
            return
        }

        if let activePeripheral {
            activePeripheral.delegate = self
            emitLog("Attempting reconnect to \(displayName(for: activePeripheral)).", level: .info)
            updateConnectionState(.connecting(deviceName: displayName(for: activePeripheral)))
            updateDiagnostic(
                step: .connecting,
                detail: "Attempting reconnect to \(displayName(for: activePeripheral)).",
                analysis: "The phone already knows this peripheral. The next failure point is whether the BLE link can be re-opened."
            )
            centralManager.connect(activePeripheral, options: nil)
            return
        }

        if let storedIdentifier = UserDefaults.standard.string(forKey: HUDBLEConstants.lastPeripheralIdentifierKey),
           let uuid = UUID(uuidString: storedIdentifier) {
            let restored = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = restored.first {
                activePeripheral = peripheral
                peripheral.delegate = self
                emitLog("Found saved peripheral \(displayName(for: peripheral)).", level: .info)
                updateConnectionState(.connecting(deviceName: displayName(for: peripheral)))
                updateDiagnostic(
                    step: .connecting,
                    detail: "Found saved peripheral \(displayName(for: peripheral)). Connecting now.",
                    analysis: "Advertising lookup succeeded through CoreBluetooth restore. The next blocking point is GATT connection establishment."
                )
                centralManager.connect(peripheral, options: nil)
                return
            }
        }

        startScan()
    }

    private func discoverHUDServices(on peripheral: CBPeripheral) {
        peripheral.discoverServices([HUDBLEConstants.serviceUUID])
    }

    private func announceReadyIfPossible(on peripheral: CBPeripheral) {
        guard peripheral.state == .connected, writeCharacteristic != nil else {
            return
        }

        if !hasSignaledReady {
            hasSignaledReady = true
            updateConnectionState(.connected(deviceName: displayName(for: peripheral)))
            updateDiagnostic(
                step: .ready,
                detail: "Write characteristic is ready for \(displayName(for: peripheral)).",
                analysis: "BLE transport setup succeeded. Clock, date, weather, battery, and custom messages can now be sent."
            )
            emitLog("HUD transport is ready.", level: .success)
            delegate?.bleServiceDidBecomeReady(self)
        }

        processOutboundQueue()
    }

    private func preferredWriteType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        if characteristic.properties.contains(.write) {
            return .withResponse
        }

        return .withoutResponse
    }

    private func processOutboundQueue() {
        guard isReadyToSend, let activePeripheral, let writeCharacteristic else {
            return
        }

        if activeTransmission == nil {
            guard !outboundQueue.isEmpty else {
                return
            }

            activeTransmission = outboundQueue.removeFirst()
        }

        guard var transmission = activeTransmission else {
            return
        }

        switch transmission.writeType {
        case .withResponse:
            guard transmission.nextChunkIndex < transmission.chunks.count else {
                activeTransmission = nil
                emitLog("Sent \(transmission.summary)", level: .success)
                processOutboundQueue()
                return
            }

            let chunk = transmission.chunks[transmission.nextChunkIndex]
            activePeripheral.writeValue(chunk, for: writeCharacteristic, type: .withResponse)
            activeTransmission = transmission

        case .withoutResponse:
            while transmission.nextChunkIndex < transmission.chunks.count {
                guard activePeripheral.canSendWriteWithoutResponse else {
                    activeTransmission = transmission
                    return
                }

                let chunk = transmission.chunks[transmission.nextChunkIndex]
                activePeripheral.writeValue(chunk, for: writeCharacteristic, type: .withoutResponse)
                transmission.nextChunkIndex += 1
            }

            activeTransmission = nil
            emitLog("Sent \(transmission.summary)", level: .success)
            processOutboundQueue()

        @unknown default:
            activeTransmission = nil
            emitLog("Unsupported BLE write type.", level: .error)
        }
    }

    private func updateConnectionState(_ state: BLEConnectionState) {
        delegate?.bleService(self, didUpdateConnectionState: state)
    }

    private func emitLog(_ message: String, level: BLELogLevel) {
        delegate?.bleService(
            self,
            didLog: BLELogEntry(timestamp: Date(), level: level, message: message)
        )
    }

    private func updateDiagnostic(
        step: BLEWorkflowStep,
        detail: String,
        analysis: String,
        failureStep: BLEWorkflowStep? = nil,
        failureReason: String? = nil,
        isBlocking: Bool = false
    ) {
        let nextSnapshot = BLEDiagnosticSnapshot(
            environment: runtimeEnvironment,
            currentStep: step,
            detail: detail,
            analysis: analysis,
            failureStep: failureStep,
            failureReason: failureReason,
            isBlocking: isBlocking
        )

        guard nextSnapshot != diagnosticSnapshot else {
            return
        }

        diagnosticSnapshot = nextSnapshot
        delegate?.bleService(self, didUpdateDiagnostic: nextSnapshot)
    }

    private func updateDiagnosticFailure(step: BLEWorkflowStep, reason: String, analysis: String, isBlocking: Bool = true) {
        updateDiagnostic(
            step: step,
            detail: "Blocked at \(step.title).",
            analysis: analysis,
            failureStep: step,
            failureReason: reason,
            isBlocking: isBlocking
        )
    }

    private func resetCharacteristicState() {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        hasSignaledReady = false
    }

    private func resetTransmissionState() {
        outboundQueue.removeAll()
        activeTransmission = nil
    }

    private func clearConnectionState(keepPeripheral: Bool) {
        stopScanningIfNeeded()
        resetCharacteristicState()
        resetTransmissionState()

        if !keepPeripheral {
            activePeripheral = nil
        }
    }

    private func stopScanningIfNeeded() {
        guard isScanning else {
            return
        }

        centralManager.stopScan()
        isScanning = false
    }

    private func persist(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: HUDBLEConstants.lastPeripheralIdentifierKey)
        if let name = peripheral.name {
            UserDefaults.standard.set(name, forKey: HUDBLEConstants.lastPeripheralNameKey)
        }
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        if let name = peripheral.name, !name.isEmpty {
            return name
        }

        if let savedName = UserDefaults.standard.string(forKey: HUDBLEConstants.lastPeripheralNameKey),
           peripheral.identifier.uuidString == UserDefaults.standard.string(forKey: HUDBLEConstants.lastPeripheralIdentifierKey) {
            return savedName
        }

        return peripheral.identifier.uuidString
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.manualDisconnect else {
                return
            }

            self.attemptReconnectOrScan()
        }
    }

    private func stateDescription(for state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "Bluetooth state is unknown."
        case .resetting:
            return "Bluetooth is resetting."
        case .unsupported:
            return "Bluetooth LE is unsupported on this device."
        case .unauthorized:
            return "Bluetooth permission was not granted."
        case .poweredOff:
            return "Bluetooth is powered off."
        case .poweredOn:
            return "Bluetooth is ready."
        @unknown default:
            return "Bluetooth is unavailable."
        }
    }
}

@MainActor
extension BLEService: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let description = stateDescription(for: central.state)

        switch central.state {
        case .poweredOn:
            emitLog(description, level: .success)
            updateDiagnostic(
                step: .bluetoothStateCheck,
                detail: description,
                analysis: "Bluetooth is ready. The app can now reconnect to a saved device or start scanning for a matching advertisement."
            )
            attemptReconnectOrScan()

        case .unknown, .resetting:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
            updateDiagnosticFailure(
                step: .bluetoothStateCheck,
                reason: description,
                analysis: "Failure happened before scan because the Bluetooth stack is not stable enough yet to start discovery."
            )
            emitLog(description, level: .warning)

        case .unsupported, .unauthorized, .poweredOff:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
            updateDiagnosticFailure(
                step: .bluetoothStateCheck,
                reason: description,
                analysis: "Failure happened before scan because the phone cannot currently offer an enabled BLE radio to the app."
            )
            emitLog(description, level: .error)

        @unknown default:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
            updateDiagnosticFailure(
                step: .bluetoothStateCheck,
                reason: description,
                analysis: "Failure happened before scan because the Bluetooth stack returned an unknown state."
            )
            emitLog(description, level: .error)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            activePeripheral = peripheral
            peripheral.delegate = self
            persist(peripheral)
            emitLog("Restored BLE state for \(displayName(for: peripheral)).", level: .info)
            updateDiagnostic(
                step: .connecting,
                detail: "Restored BLE state for \(displayName(for: peripheral)).",
                analysis: "State restoration succeeded. The app is re-entering the connection pipeline from an already known peripheral."
            )

            if peripheral.state == .connected {
                discoverHUDServices(on: peripheral)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        guard let name = peripheral.name, HUDBLEConstants.allowedDeviceNames.contains(name) else {
            return
        }

        if activePeripheral?.identifier == peripheral.identifier,
           activePeripheral?.state == .connected {
            return
        }

        persist(peripheral)
        activePeripheral = peripheral
        peripheral.delegate = self
        stopScanningIfNeeded()
        updateConnectionState(.connecting(deviceName: name))
        updateDiagnostic(
            step: .connecting,
            detail: "Found target \(name). Opening the BLE link.",
            analysis: "Advertising succeeded. The next blocking point is whether the GATT connection can be established."
        )
        emitLog("Found target \(name) (RSSI \(RSSI)).", level: .success)
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        persist(peripheral)
        resetCharacteristicState()
        emitLog("Connected to \(displayName(for: peripheral)).", level: .success)
        updateConnectionState(.connected(deviceName: displayName(for: peripheral)))
        updateDiagnostic(
            step: .serviceDiscovery,
            detail: "Connected to \(displayName(for: peripheral)). Discovering service \(HUDBLEConstants.serviceUUID.uuidString).",
            analysis: "The BLE link is up. The next blocking point is whether the ESP32 exposes the expected service UUID."
        )
        discoverHUDServices(on: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let detail = error?.localizedDescription ?? "Unknown error"
        clearConnectionState(keepPeripheral: true)
        updateDiagnosticFailure(
            step: .connecting,
            reason: "Failed to connect to \(displayName(for: peripheral)): \(detail)",
            analysis: "Advertising succeeded, but the BLE link failed to open. Common causes are unstable firmware, insufficient power, or the peripheral stopping advertisement too early."
        )
        emitLog("Failed to connect to \(displayName(for: peripheral)): \(detail)", level: .error)
        updateConnectionState(.disconnected)
        if !manualDisconnect {
            scheduleReconnect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = displayName(for: peripheral)
        clearConnectionState(keepPeripheral: !manualDisconnect)

        if let error {
            updateDiagnosticFailure(
                step: .ready,
                reason: "Disconnected from \(name): \(error.localizedDescription)",
                analysis: "The BLE session was established, then dropped. Common causes are ESP32 reset, low power, firmware crash, or moving out of radio range."
            )
            emitLog("Disconnected from \(name): \(error.localizedDescription)", level: .warning)
        } else {
            updateDiagnostic(
                step: .disconnected,
                detail: "Disconnected from \(name).",
                analysis: manualDisconnect
                    ? "The session was closed from the app side. Tap Scan to restart discovery."
                    : "The BLE session ended cleanly. If this was unexpected, inspect ESP32 power, firmware stability, and radio range."
            )
            emitLog("Disconnected from \(name).", level: .warning)
        }

        updateConnectionState(.disconnected)

        if !manualDisconnect {
            activePeripheral = peripheral
            updateConnectionState(.connecting(deviceName: name))
            updateDiagnostic(
                step: .connecting,
                detail: "Attempting automatic reconnect to \(name).",
                analysis: "The previous session ended. The app is now retrying GATT connection establishment."
            )
            scheduleReconnect()
        } else {
            activePeripheral = nil
        }
    }

}

@MainActor
extension BLEService: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            updateDiagnosticFailure(
                step: .serviceDiscovery,
                reason: "Service discovery failed: \(error.localizedDescription)",
                analysis: "The BLE link exists, but iOS could not read the GATT service table from the peripheral."
            )
            emitLog("Service discovery failed: \(error.localizedDescription)", level: .error)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == HUDBLEConstants.serviceUUID }) else {
            updateDiagnosticFailure(
                step: .serviceDiscovery,
                reason: "Expected service UUID \(HUDBLEConstants.serviceUUID.uuidString) was not found.",
                analysis: "The phone connected successfully, but the firmware is not exposing the service UUID that this app expects."
            )
            emitLog("HUD service UUID not found on \(displayName(for: peripheral)).", level: .error)
            return
        }

        updateDiagnostic(
            step: .characteristicDiscovery,
            detail: "Found service \(service.uuid.uuidString). Discovering characteristics.",
            analysis: "Connection and service discovery succeeded. The next blocking point is whether the write characteristic exists."
        )
        emitLog("HUD service discovered.", level: .success)
        peripheral.discoverCharacteristics(
            [
                HUDBLEConstants.writeCharacteristicUUID,
                HUDBLEConstants.notifyCharacteristicUUID
            ],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            updateDiagnosticFailure(
                step: .characteristicDiscovery,
                reason: "Characteristic discovery failed: \(error.localizedDescription)",
                analysis: "The service exists, but iOS could not enumerate the characteristics required by the app."
            )
            emitLog("Characteristic discovery failed: \(error.localizedDescription)", level: .error)
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == HUDBLEConstants.writeCharacteristicUUID {
                writeCharacteristic = characteristic
                emitLog("Write characteristic ready.", level: .success)
            } else if characteristic.uuid == HUDBLEConstants.notifyCharacteristicUUID {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                emitLog("Notify characteristic ready.", level: .success)
            }
        }

        if writeCharacteristic == nil {
            updateDiagnosticFailure(
                step: .characteristicDiscovery,
                reason: "Expected write characteristic UUID \(HUDBLEConstants.writeCharacteristicUUID.uuidString) was not found.",
                analysis: "The service exists, but the firmware does not expose the write endpoint that the app uses to send HUD packets."
            )
            emitLog("Write characteristic UUID not found.", level: .error)
            return
        }

        announceReadyIfPossible(on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDiagnostic(
                step: .characteristicDiscovery,
                detail: "Notify subscription failed for \(characteristic.uuid.uuidString).",
                analysis: "The outbound write path may still work, but inbound notify data will not arrive until the firmware accepts notification subscription.",
                failureStep: .characteristicDiscovery,
                failureReason: "Notify subscription failed: \(error.localizedDescription)",
                isBlocking: false
            )
            emitLog("Notify subscription failed: \(error.localizedDescription)", level: .error)
            return
        }

        let stateText = characteristic.isNotifying ? "enabled" : "disabled"
        emitLog("Notify \(stateText) for \(characteristic.uuid.uuidString).", level: .info)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDiagnosticFailure(
                step: .packetWrite,
                reason: "BLE write failed: \(error.localizedDescription)",
                analysis: "Setup succeeded, but packet transmission failed after the connection was ready. Inspect characteristic properties and ESP32 firmware handling."
            )
            emitLog("BLE write failed: \(error.localizedDescription)", level: .error)
            activeTransmission = nil
            processOutboundQueue()
            return
        }

        guard var transmission = activeTransmission else {
            return
        }

        transmission.nextChunkIndex += 1

        if transmission.nextChunkIndex >= transmission.chunks.count {
            activeTransmission = nil
            emitLog("Sent \(transmission.summary)", level: .success)
        } else {
            activeTransmission = transmission
        }

        processOutboundQueue()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            updateDiagnostic(
                step: .ready,
                detail: "Received a notify read error from \(characteristic.uuid.uuidString).",
                analysis: "The BLE session is up, but one inbound notify read failed. Inspect the firmware payload path if this repeats.",
                failureStep: .packetWrite,
                failureReason: "Notify read failed: \(error.localizedDescription)",
                isBlocking: false
            )
            emitLog("Notify read failed: \(error.localizedDescription)", level: .error)
            return
        }

        guard let value = characteristic.value, !value.isEmpty else {
            return
        }

        let text = String(data: value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? value.base64EncodedString()
        emitLog("Notify \(characteristic.uuid.uuidString): \(text)", level: .info)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        processOutboundQueue()
    }
}

private struct PendingTransmission {
    let summary: String
    let chunks: [Data]
    let writeType: CBCharacteristicWriteType
    var nextChunkIndex: Int
}

private extension Data {
    func chunked(into size: Int) -> [Data] {
        guard size > 0 else {
            return [self]
        }

        guard count > size else {
            return [self]
        }

        var chunks: [Data] = []
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(self[index ..< nextIndex])
            index = nextIndex
        }

        return chunks
    }
}
