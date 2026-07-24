import Foundation
@preconcurrency import CoreBluetooth

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
    func bleService(_ service: BLEService, didLog entry: BLELogEntry)
    func bleServiceDidBecomeReady(_ service: BLEService)
}

@MainActor
final class BLEService: NSObject {
    weak var delegate: BLEServiceDelegate?

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
        _ = centralManager
    }

    func startScan() {
        manualDisconnect = false

        guard centralManager.state == .poweredOn else {
            emitLog("Bluetooth is not powered on yet.", level: .warning)
            return
        }

        if let activePeripheral, activePeripheral.state == .connected {
            updateConnectionState(.connected(deviceName: displayName(for: activePeripheral)))
            emitLog("Already connected to \(displayName(for: activePeripheral)).", level: .info)
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
        emitLog("Scanning for HUD Glasses / XIAO-HUD.", level: .info)
    }

    func disconnect() {
        manualDisconnect = true
        stopScanningIfNeeded()
        resetTransmissionState()

        guard let activePeripheral else {
            updateConnectionState(.disconnected)
            return
        }

        emitLog("Disconnecting from \(displayName(for: activePeripheral)).", level: .warning)
        centralManager.cancelPeripheralConnection(activePeripheral)
    }

    func resumeConnectionFlow() {
        manualDisconnect = false

        guard centralManager.state == .poweredOn else {
            return
        }

        if let activePeripheral {
            switch activePeripheral.state {
            case .connected:
                activePeripheral.delegate = self
                discoverHUDServices(on: activePeripheral)
                announceReadyIfPossible(on: activePeripheral)
                updateConnectionState(.connected(deviceName: displayName(for: activePeripheral)))
                return
            case .connecting:
                updateConnectionState(.connecting(deviceName: displayName(for: activePeripheral)))
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

extension BLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let description = stateDescription(for: central.state)

        switch central.state {
        case .poweredOn:
            emitLog(description, level: .success)
            attemptReconnectOrScan()

        case .unknown, .resetting:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
            emitLog(description, level: .warning)

        case .unsupported, .unauthorized, .poweredOff:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
            emitLog(description, level: .error)

        @unknown default:
            clearConnectionState(keepPeripheral: true)
            updateConnectionState(.bluetoothUnavailable(reason: description))
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
        discoverHUDServices(on: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let detail = error?.localizedDescription ?? "Unknown error"
        clearConnectionState(keepPeripheral: true)
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
            emitLog("Disconnected from \(name): \(error.localizedDescription)", level: .warning)
        } else {
            emitLog("Disconnected from \(name).", level: .warning)
        }

        updateConnectionState(.disconnected)

        if !manualDisconnect {
            activePeripheral = peripheral
            updateConnectionState(.connecting(deviceName: name))
            scheduleReconnect()
        } else {
            activePeripheral = nil
        }
    }

}

extension BLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            emitLog("Service discovery failed: \(error.localizedDescription)", level: .error)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == HUDBLEConstants.serviceUUID }) else {
            emitLog("HUD service UUID not found on \(displayName(for: peripheral)).", level: .error)
            return
        }

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
            emitLog("Write characteristic UUID not found.", level: .error)
        }

        announceReadyIfPossible(on: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            emitLog("Notify subscription failed: \(error.localizedDescription)", level: .error)
            return
        }

        let stateText = characteristic.isNotifying ? "enabled" : "disabled"
        emitLog("Notify \(stateText) for \(characteristic.uuid.uuidString).", level: .info)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
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
