import CoreBluetooth
import Foundation

struct TandemScanResult: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int

    /// Which Tandem model the advertised name identifies, if it identifies one.
    var model: TandemPumpModel? {
        TandemPumpModel.from(bluetoothName: name)
    }
}

enum TandemConnectionError: LocalizedError {
    case bluetoothNotAvailable
    case peripheralNotFound
    case connectFailed(String)
    case timeout
    case notConnected
    case characteristicMissing

    var errorDescription: String? {
        switch self {
        case .bluetoothNotAvailable: return "Bluetooth is not available."
        case .peripheralNotFound: return "Could not find the pump. Make sure it is in range."
        case let .connectFailed(reason): return "Failed to connect to the pump: \(reason)"
        case .timeout: return "Timed out communicating with the pump."
        case .notConnected: return "The pump is not connected."
        case .characteristicMissing: return "The pump did not expose the expected Bluetooth services."
        }
    }
}

protocol TandemBluetoothManagerDelegate: AnyObject {
    /// Connection established, services discovered, notifications enabled.
    func bluetoothManagerReady(_ manager: TandemBluetoothManager)
    func bluetoothManager(_ manager: TandemBluetoothManager, didDisconnect error: Error?)
    func bluetoothManager(_ manager: TandemBluetoothManager, didReceive packet: Data, on characteristic: TandemCharacteristic)
    /// Qualifying events arrive as a raw uint32 LE bitmask, unframed.
    func bluetoothManager(_ manager: TandemBluetoothManager, didReceiveQualifyingEvents events: TandemQualifyingEvents)
}

/// CoreBluetooth transport for a Tandem pump: scanning, connection,
/// characteristic discovery, notification enabling, and chunked writes.
final class TandemBluetoothManager: NSObject {
    private let log = TandemLogger(category: "TandemBluetoothManager")

    let managerQueue = DispatchQueue(label: "org.nightscout.trio.TandemBluetoothManager", qos: .userInitiated)
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var notificationsPending: Set<CBUUID> = []

    weak var delegate: TandemBluetoothManagerDelegate?

    /// Peripheral identifier of the paired pump; scanning connects to any
    /// Tandem pump when nil.
    var peripheralIdentifier: UUID?

    /// Advertised name of the connected pump, used to tell a Mobi from a
    /// t:slim X2. Nil until a peripheral is known.
    var peripheralName: String? {
        peripheral?.name
    }

    private var scanCompletion: ((TandemScanResult) -> Void)?
    private var connectCompletion: ((TandemConnectionError?) -> Void)?
    private var connectTimeoutWorkItem: DispatchWorkItem?

    var isConnected: Bool {
        peripheral?.state == .connected && !characteristics.isEmpty
    }

    override init() {
        super.init()
        managerQueue.sync {
            self.manager = CBCentralManager(
                delegate: self,
                queue: managerQueue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "org.nightscout.trio.TandemBluetoothManager"]
            )
        }
    }

    // MARK: - Scanning

    func startScan(_ onDiscovery: @escaping (TandemScanResult) -> Void) {
        managerQueue.async {
            guard self.manager.state == .poweredOn else {
                self.log.error("Cannot scan: bluetooth state \(String(describing: self.manager.state))")
                return
            }
            self.scanCompletion = onDiscovery
            self.manager.scanForPeripherals(withServices: [TandemBLE.pumpServiceUUID])
            self.log.info("Started scanning for Tandem pumps")
        }
    }

    func stopScan() {
        managerQueue.async {
            if self.manager.isScanning {
                self.manager.stopScan()
            }
            self.scanCompletion = nil
        }
    }

    // MARK: - Connection

    func ensureConnected(timeout: TimeInterval = 30, _ completion: @escaping (TandemConnectionError?) -> Void) {
        managerQueue.async {
            if self.isConnected {
                completion(nil)
                return
            }

            guard self.connectCompletion == nil else {
                completion(.connectFailed("Connection already in progress"))
                return
            }

            guard self.manager.state == .poweredOn else {
                completion(.bluetoothNotAvailable)
                return
            }

            self.connectCompletion = { error in
                self.connectTimeoutWorkItem?.cancel()
                self.connectTimeoutWorkItem = nil
                self.connectCompletion = nil
                completion(error)
            }

            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.log.error("Connection attempt timed out")
                if let peripheral = self.peripheral {
                    self.manager.cancelPeripheralConnection(peripheral)
                }
                self.connectCompletion?(.timeout)
            }
            self.connectTimeoutWorkItem = timeoutItem
            self.managerQueue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

            if let peripheral = self.peripheral {
                self.connect(peripheral)
                return
            }

            if let identifier = self.peripheralIdentifier,
               let known = self.manager.retrievePeripherals(withIdentifiers: [identifier]).first
            {
                self.connect(known)
                return
            }

            if let connected = self.manager
                .retrieveConnectedPeripherals(withServices: [TandemBLE.pumpServiceUUID]).first
            {
                self.connect(connected)
                return
            }

            // Last resort: scan for the pump.
            self.scanCompletion = { [weak self] result in
                guard let self = self, result.id == self.peripheralIdentifier || self.peripheralIdentifier == nil else {
                    return
                }
                self.manager.stopScan()
                self.scanCompletion = nil
                if let found = self.manager.retrievePeripherals(withIdentifiers: [result.id]).first {
                    self.connect(found)
                }
            }
            self.manager.scanForPeripherals(withServices: [TandemBLE.pumpServiceUUID])
        }
    }

    /// Connect to a pump chosen in the pairing UI.
    func connect(identifier: UUID, timeout: TimeInterval = 30, _ completion: @escaping (TandemConnectionError?) -> Void) {
        managerQueue.async {
            self.peripheral = nil
            self.characteristics = [:]
            self.peripheralIdentifier = identifier
        }
        ensureConnected(timeout: timeout, completion)
    }

    private func connect(_ peripheral: CBPeripheral) {
        log.info("Connecting to \(peripheral.name ?? peripheral.identifier.uuidString)")
        self.peripheral = peripheral
        peripheral.delegate = self
        manager.connect(peripheral)
    }

    func disconnect() {
        managerQueue.async {
            if let peripheral = self.peripheral {
                self.manager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    // MARK: - Writes

    private func tandemCharacteristic(for characteristic: TandemCharacteristic) -> CBCharacteristic? {
        switch characteristic {
        case .currentStatus: return characteristics[TandemBLE.currentStatusCharacteristicUUID]
        case .authorization: return characteristics[TandemBLE.authorizationCharacteristicUUID]
        case .control: return characteristics[TandemBLE.controlCharacteristicUUID]
        case .historyLog: return characteristics[TandemBLE.historyLogCharacteristicUUID]
        }
    }

    /// Write the chunked packets of one message, in order, with response.
    func write(packets: [Data], to characteristic: TandemCharacteristic) throws {
        guard let peripheral = peripheral, peripheral.state == .connected else {
            throw TandemConnectionError.notConnected
        }
        guard let cbCharacteristic = tandemCharacteristic(for: characteristic) else {
            throw TandemConnectionError.characteristicMissing
        }
        for packet in packets {
            peripheral.writeValue(packet, for: cbCharacteristic, type: .withResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TandemBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log.info("Central manager state: \(String(describing: central.state.rawValue))")
        if central.state != .poweredOn, connectCompletion != nil {
            connectCompletion?(.bluetoothNotAvailable)
        }
    }

    func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first(where: { $0.identifier == peripheralIdentifier })
        {
            log.info("Restored peripheral \(restored.identifier)")
            peripheral = restored
            restored.delegate = self
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let result = TandemScanResult(
            id: peripheral.identifier,
            name: peripheral.name ?? "Tandem Pump",
            rssi: RSSI.intValue
        )
        scanCompletion?(result)
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("Connected, discovering services")
        characteristics = [:]
        peripheral.discoverServices([TandemBLE.pumpServiceUUID])
    }

    func centralManager(_: CBCentralManager, didFailToConnect _: CBPeripheral, error: Error?) {
        log.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectCompletion?(.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral _: CBPeripheral, error: Error?) {
        log.info("Disconnected: \(error?.localizedDescription ?? "no error")")
        characteristics = [:]
        if let completion = connectCompletion {
            completion(.connectFailed(error?.localizedDescription ?? "disconnected"))
        }
        delegate?.bluetoothManager(self, didDisconnect: error)
    }
}

// MARK: - CBPeripheralDelegate

extension TandemBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log.error("Service discovery failed: \(error.localizedDescription)")
            connectCompletion?(.connectFailed(error.localizedDescription))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == TandemBLE.pumpServiceUUID }) else {
            connectCompletion?(.characteristicMissing)
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log.error("Characteristic discovery failed: \(error.localizedDescription)")
            connectCompletion?(.connectFailed(error.localizedDescription))
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }

        // Enable notifications on every message-bearing characteristic
        // before any exchange (required order per pumpx2).
        notificationsPending = []
        for uuid in TandemBLE.notifiedCharacteristicUUIDs {
            if let characteristic = characteristics[uuid] {
                notificationsPending.insert(uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if notificationsPending.isEmpty {
            connectCompletion?(.characteristicMissing)
        }
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("Enabling notifications failed for \(characteristic.uuid): \(error.localizedDescription)")
            connectCompletion?(.connectFailed(error.localizedDescription))
            return
        }
        notificationsPending.remove(characteristic.uuid)
        if notificationsPending.isEmpty {
            log.info("All notifications enabled — transport ready")
            connectCompletion?(nil)
            delegate?.bluetoothManagerReady(self)
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("Characteristic update error: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }

        let target: TandemCharacteristic?
        switch characteristic.uuid {
        case TandemBLE.currentStatusCharacteristicUUID: target = .currentStatus
        case TandemBLE.authorizationCharacteristicUUID: target = .authorization
        case TandemBLE.controlCharacteristicUUID: target = .control
        case TandemBLE.historyLogCharacteristicUUID: target = .historyLog
        case TandemBLE.qualifyingEventsCharacteristicUUID:
            if value.count >= 4 {
                let events = TandemQualifyingEvents(rawValue: value.tandemUInt32(at: 0))
                delegate?.bluetoothManager(self, didReceiveQualifyingEvents: events)
            }
            return
        default: target = nil
        }

        if let target = target {
            delegate?.bluetoothManager(self, didReceive: value, on: target)
        }
    }

    func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log.error("Write failed on \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}
