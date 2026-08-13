import CoreBluetooth
import Foundation

/// Encrypted GATT transport for an AccessorySetupKit-authorized accessory.
/// Credential success means NetworkManager reported an activated connection.
final class SparkBLEPingTransport: NSObject {
    private enum ExpectedResponse: Equatable {
        case pong
        case credentialConnected
        case forgetReady
    }

    enum State: Equatable {
        case disconnected
        case waitingForBluetooth
        case connecting(attempt: Int)
        case discovering
        case ready
        case sending
        case succeeded(milliseconds: Int)
        case failed(code: String)

        var title: String {
            switch self {
            case .disconnected: "Not tested"
            case .waitingForBluetooth: "Waiting for Bluetooth"
            case .connecting(let attempt): "Connecting (attempt \(attempt))"
            case .discovering: "Discovering secure GATT service"
            case .ready: "Encrypted transport ready"
            case .sending: "Waiting for matching pong"
            case .succeeded(let milliseconds): "Secure ping passed in \(milliseconds) ms"
            case .failed(let code): "Secure ping failed: \(code)"
            }
        }

        var isRunning: Bool {
            switch self {
            case .waitingForBluetooth, .connecting, .discovering, .ready, .sending:
                true
            default:
                false
            }
        }

        var succeeded: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }

    private static let serviceUUID = CBUUID(nsuuid: AutoWiFiConstants.serviceUUID)
    private static let credentialRXUUID = CBUUID(nsuuid: AutoWiFiConstants.credentialRXUUID)
    private static let statusTXUUID = CBUUID(nsuuid: AutoWiFiConstants.statusTXUUID)
    private static let maximumAttempts = 2
    private static let attemptTimeout: TimeInterval = 12
    private static let networkActivationTimeout: TimeInterval = 55

    private let identifier: UUID
    private let update: (State) -> Void
    private let configuredFrame: Data?
    private let configuredRequestID: UUID?
    private let expectedResponse: ExpectedResponse
    private let holdConnectionWhenReady: Bool
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var credentialRX: CBCharacteristic?
    private var statusTX: CBCharacteristic?
    private var decoder = AutoWiFiFrameDecoder()
    private var pendingChunks: [Data] = []
    private var requestID: UUID?
    private var startedAt: Date?
    private var attempts = 0
    private var timeout: DispatchWorkItem?
    private var completed = false

    init(identifier: UUID, update: @escaping (State) -> Void) {
        self.identifier = identifier
        self.update = update
        configuredFrame = nil
        configuredRequestID = nil
        expectedResponse = .pong
        holdConnectionWhenReady = false
        super.init()
    }

    /// Establishes and retains an encrypted GATT connection without sending a protocol frame.
    /// Wi-Fi Infrastructure only shares with a currently connected accessory, so the container
    /// app uses this mode as a short-lived lease while `askToShare()` wakes the extension.
    init(
        identifier: UUID,
        holdConnectionWhenReady: Bool,
        update: @escaping (State) -> Void
    ) {
        self.identifier = identifier
        self.update = update
        configuredFrame = nil
        configuredRequestID = nil
        expectedResponse = .pong
        self.holdConnectionWhenReady = holdConnectionWhenReady
        super.init()
    }

    init(
        identifier: UUID,
        credentialFrame: Data,
        requestID: UUID,
        update: @escaping (State) -> Void
    ) {
        self.identifier = identifier
        self.update = update
        configuredFrame = credentialFrame
        configuredRequestID = requestID
        expectedResponse = .credentialConnected
        holdConnectionWhenReady = false
        super.init()
    }

    init(
        identifier: UUID,
        forgetFrame: Data,
        requestID: UUID,
        update: @escaping (State) -> Void
    ) {
        self.identifier = identifier
        self.update = update
        configuredFrame = forgetFrame
        configuredRequestID = requestID
        expectedResponse = .forgetReady
        holdConnectionWhenReady = false
        super.init()
    }

    func start() {
        guard central == nil else { return }
        publish(.disconnected)
        scheduleTimeout(code: "bluetooth-unavailable")
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        completed = true
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func connect() {
        guard !completed else { return }
        guard let central else {
            fail("bluetooth-manager-missing")
            return
        }
        guard central.state == .poweredOn else {
            publish(.waitingForBluetooth)
            if timeout == nil {
                scheduleTimeout(code: "bluetooth-unavailable")
            }
            return
        }
        guard attempts < Self.maximumAttempts else {
            fail("retries-exhausted")
            return
        }

        if peripheral == nil {
            peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first
            peripheral?.delegate = self
        }
        guard let peripheral else {
            fail("accessory-not-restored")
            return
        }

        attempts += 1
        resetAttemptState()
        publish(.connecting(attempt: attempts))
        scheduleTimeout()
        central.connect(peripheral)
    }

    private func resetAttemptState() {
        credentialRX = nil
        statusTX = nil
        decoder = AutoWiFiFrameDecoder()
        pendingChunks.removeAll(keepingCapacity: false)
        requestID = nil
        startedAt = nil
    }

    private func scheduleTimeout(code: String = "timeout") {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fail(code)
        }
        timeout = work
        let interval = expectedResponse == .credentialConnected
            ? Self.networkActivationTimeout
            : Self.attemptTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func retryOrFail(_ code: String) {
        timeout?.cancel()
        timeout = nil
        guard !completed else { return }
        guard attempts < Self.maximumAttempts else {
            fail(code)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.completed else { return }
            self.connect()
        }
    }

    private func preparePing() {
        guard let peripheral, let credentialRX else {
            fail("characteristic-missing")
            return
        }
        do {
            let requestID = configuredRequestID ?? UUID()
            let frame = try configuredFrame
                ?? AutoWiFiFrameCodec.frame(AutoWiFiPingMessage(requestID: requestID))
            let chunkSize = max(1, peripheral.maximumWriteValueLength(for: .withResponse))
            pendingChunks = stride(from: 0, to: frame.count, by: chunkSize).map { offset in
                frame.subdata(in: offset ..< min(offset + chunkSize, frame.count))
            }
            self.requestID = requestID
            startedAt = Date()
            publish(.sending)
            writeNextChunk(to: credentialRX, on: peripheral)
        } catch {
            fail("encode")
        }
    }

    private func writeNextChunk(to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        guard !completed, !pendingChunks.isEmpty else { return }
        peripheral.writeValue(pendingChunks.removeFirst(), for: characteristic, type: .withResponse)
    }

    private func consumeNotification(_ data: Data) {
        do {
            for payload in try decoder.feed(data) {
                switch expectedResponse {
                case .pong:
                    let pong = try JSONDecoder().decode(AutoWiFiPongMessage.self, from: payload)
                    guard pong.requestID == requestID else {
                        fail("request-id-mismatch")
                        return
                    }
                case .credentialConnected:
                    let status = try JSONDecoder().decode(AutoWiFiStatusMessage.self, from: payload)
                    guard let requestID else {
                        fail("request-id-missing")
                        return
                    }
                    switch try status.credentialDisposition(for: requestID) {
                    case .pending:
                        scheduleTimeout(code: "network-activation-timeout")
                        continue
                    case .connected:
                        break
                    case .failed(let code):
                        fail(code)
                        return
                    }
                case .forgetReady:
                    let ready = try JSONDecoder().decode(
                        AutoWiFiForgetReadyMessage.self,
                        from: payload
                    )
                    guard ready.requestID == requestID else {
                        fail("request-id-mismatch")
                        return
                    }
                }
                let milliseconds = Int((Date().timeIntervalSince(startedAt ?? Date()) * 1_000).rounded())
                succeed(milliseconds: max(0, milliseconds))
                return
            }
        } catch {
            fail("invalid-response")
        }
    }

    private func succeed(milliseconds: Int) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        publish(.succeeded(milliseconds: milliseconds))
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func fail(_ code: String) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        publish(.failed(code: code))
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    private func publish(_ state: State) {
        update(state)
    }
}

extension SparkBLEPingTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !completed else { return }
        switch central.state {
        case .poweredOn:
            connect()
        case .poweredOff:
            publish(.waitingForBluetooth)
            if timeout == nil {
                scheduleTimeout(code: "bluetooth-off")
            }
        case .unauthorized:
            fail("bluetooth-unauthorized")
        case .unsupported:
            fail("bluetooth-unsupported")
        case .resetting, .unknown:
            publish(.waitingForBluetooth)
        @unknown default:
            fail("bluetooth-state")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !completed else { return }
        publish(.discovering)
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        retryOrFail("connect")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        retryOrFail("disconnected")
    }
}

extension SparkBLEPingTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            fail("service-discovery")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            fail("service-missing")
            return
        }
        peripheral.discoverCharacteristics(
            [Self.credentialRXUUID, Self.statusTXUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard error == nil else {
            fail("characteristic-discovery")
            return
        }
        credentialRX = service.characteristics?.first { $0.uuid == Self.credentialRXUUID }
        statusTX = service.characteristics?.first { $0.uuid == Self.statusTXUUID }
        guard credentialRX != nil, let statusTX else {
            fail("characteristic-missing")
            return
        }
        peripheral.setNotifyValue(true, for: statusTX)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == Self.statusTXUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            fail("notification-subscribe")
            return
        }
        publish(.ready)
        if holdConnectionWhenReady {
            timeout?.cancel()
            timeout = nil
            return
        }
        preparePing()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == Self.credentialRXUUID, !completed else { return }
        guard error == nil else {
            fail("encrypted-write")
            return
        }
        if !pendingChunks.isEmpty {
            writeNextChunk(to: characteristic, on: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard characteristic.uuid == Self.statusTXUUID else { return }
        guard error == nil, let value = characteristic.value else {
            fail("notification-read")
            return
        }
        consumeNotification(value)
    }
}
