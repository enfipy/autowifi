import AccessorySetupKit
import CoreBluetooth
import Foundation
import WiFiInfrastructure

@MainActor
final class AccessorySessionModel: ObservableObject {
    enum State: Equatable {
        case starting
        case noSpark
        case pairing
        case paired(count: Int)
        case failed(code: String)

        var title: String {
            switch self {
            case .starting: "Starting"
            case .noSpark: "No Spark paired"
            case .pairing: "Looking for Spark"
            case .paired(let count): count == 1 ? "1 Spark paired" : "\(count) Sparks paired"
            case .failed: "Needs attention"
            }
        }

        var detail: String {
            switch self {
            case .starting:
                "Activating AccessorySetupKit"
            case .noSpark:
                "Start the Autowifi daemon on each Spark, then add it here."
            case .pairing:
                "Keep the iPhone close to the Spark you are adding."
            case .paired(let count):
                "Select any of the \(count) paired \(count == 1 ? "Spark" : "Sparks") for Wi-Fi sharing."
            case .failed(let code):
                "Redacted error: \(code)"
            }
        }
    }

    enum WiFiSharingState: Equatable {
        case notRequested
        case requesting
        case undetermined
        case denied
        case askToShare
        case automatic
        case failed(code: String)

        var title: String {
            switch self {
            case .notRequested: "Wi-Fi sharing not requested"
            case .requesting: "Requesting Wi-Fi sharing"
            case .undetermined: "Wi-Fi sharing is undetermined"
            case .denied: "Wi-Fi sharing denied"
            case .askToShare: "Ask every time"
            case .automatic: "Automatically share"
            case .failed(let code): "Wi-Fi sharing failed: \(code)"
            }
        }

        var isRequesting: Bool { self == .requesting }
    }

    enum ManualShareState: Equatable {
        case notRequested
        case requesting
        case approved
        case automatic
        case denied
        case undetermined
        case failed(code: String)

        var title: String {
            switch self {
            case .notRequested: "No network requested"
            case .requesting: "Requesting current network"
            case .approved: "Current network approved for delivery"
            case .automatic: "Automatic sharing is enabled"
            case .denied: "Current network not shared"
            case .undetermined: "Network sharing is undetermined"
            case .failed(let code): "Network request failed: \(code)"
            }
        }

        var isRequesting: Bool { self == .requesting }
    }

    struct Spark: Identifiable {
        let id: UUID
        var name: String
        var isSelected: Bool
        var transportState: SparkBLEPingTransport.State = .disconnected
        var wiFiSharingState: WiFiSharingState = .notRequested
        var manualShareState: ManualShareState = .notRequested
        var isRemoving = false
        var removalErrorCode: String?
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var sparks: [Spark] = []
    @Published private(set) var removalRecoverySeconds = 0

    var selectedCount: Int { sparks.count(where: \.isSelected) }
    var areAllSelected: Bool { !sparks.isEmpty && selectedCount == sparks.count }
    var selectedIDs: [UUID] { sparks.filter(\.isSelected).map(\.id) }
    var isSharingWithSelection: Bool {
        sparks.contains { spark in
            spark.isSelected
                && (spark.wiFiSharingState.isRequesting || spark.manualShareState.isRequesting)
        }
    }

    private let session = ASAccessorySession()
    private var selection = SparkSelection()
    private var accessories: [UUID: ASAccessory] = [:]
    private var transports: [UUID: SparkBLEPingTransport] = [:]
    private var removalTransports: [UUID: SparkBLEPingTransport] = [:]
    private var sharingConnectionTransports: [UUID: SparkBLEPingTransport] = [:]
    private var sharingConnectionContinuations: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var sharingControllers: [UUID: WINetworkSharingController] = [:]
    private var automaticProbeIDs: Set<UUID> = []
    private lazy var removalRecovery = RemovalRecovery { [weak self] seconds in
        self?.removalRecoverySeconds = seconds
    }

    private let shouldRunAutomaticProbe =
        ProcessInfo.processInfo.environment["AUTOWIFI_AUTOMATIC_PROBE"] == "1"

    init() {
        removalRecovery.restore()
        session.activate(on: .main) { [weak self] event in
            self?.handle(event)
        }
    }

    func presentPicker() async {
        if sparks.isEmpty { state = .pairing }
        do {
            try await session.showPicker(for: AccessoryCatalog.pickerItems())
        } catch {
            state = .failed(code: "picker-\((error as NSError).code)")
        }
    }

    func toggleSelection(_ identifier: UUID) {
        selection.toggle(identifier)
        applySelection()
    }

    func toggleAllSelection() {
        if areAllSelected {
            selection.deselectAll()
        } else {
            selection.selectAll()
        }
        applySelection()
    }

    func removeSpark(_ identifier: UUID) async {
        guard
            let accessory = accessories[identifier],
            sparks[id: identifier]?.isRemoving == false
        else { return }

        transports.removeValue(forKey: identifier)?.cancel()
        automaticProbeIDs.remove(identifier)
        removalTransports.removeValue(forKey: identifier)?.cancel()
        updateSpark(identifier) {
            $0.transportState = .disconnected
            $0.removalErrorCode = nil
            $0.isRemoving = true
        }
        removalRecovery.start()

        do {
            let requestID = UUID()
            let frame = try AutoWiFiFrameCodec.frame(
                AutoWiFiForgetRequestMessage(requestID: requestID)
            )
            let removalTransport = SparkBLEPingTransport(
                identifier: identifier,
                operation: .forget(frame: frame, requestID: requestID)
            ) { [weak self] transportState in
                DispatchQueue.main.async {
                    guard let self, self.sparks[id: identifier]?.isRemoving == true else { return }
                    switch transportState {
                    case .succeeded:
                        Task { await self.finishRemovingSpark(accessory, identifier: identifier) }
                    case .failed(let code):
                        self.removalTransports.removeValue(forKey: identifier)
                        self.updateSpark(identifier) {
                            $0.isRemoving = false
                            $0.removalErrorCode = code
                        }
                    default:
                        break
                    }
                }
            }
            removalTransports[identifier] = removalTransport
            removalTransport.start()
        } catch {
            updateSpark(identifier) {
                $0.isRemoving = false
                $0.removalErrorCode = "encode"
            }
        }
    }

    private func finishRemovingSpark(_ accessory: ASAccessory, identifier: UUID) async {
        removalTransports.removeValue(forKey: identifier)
        do {
            // The encrypted acknowledgement schedules removal of only this iPhone bond on
            // this Spark. Each Spark is removed independently; another Spark is never used
            // as a credential or ownership relay.
            try await session.removeAccessory(accessory)
            cleanup(identifier)
            reconcileAccessories(session.accessories)
        } catch {
            updateSpark(identifier) {
                $0.isRemoving = false
                $0.removalErrorCode = "ios-remove-\((error as NSError).code)"
            }
        }
    }

    /// Recovery for a split-brain pairing: iOS still restores the accessory, but the Spark
    /// has already lost its BlueZ bond, so the normal encrypted forget handshake cannot run.
    /// Keep this explicit; silently falling back could leave a real, still-present Spark bond.
    func forgetSparkOnIPhone(_ identifier: UUID) async {
        guard let accessory = accessories[identifier] else { return }
        transports.removeValue(forKey: identifier)?.cancel()
        removalTransports.removeValue(forKey: identifier)?.cancel()
        releaseSecureConnectionForSharing(identifier)
        updateSpark(identifier) {
            $0.isRemoving = true
            $0.removalErrorCode = nil
        }
        do {
            try await session.removeAccessory(accessory)
            cleanup(identifier)
            reconcileAccessories(session.accessories)
        } catch {
            updateSpark(identifier) {
                $0.isRemoving = false
                $0.removalErrorCode = "ios-remove-\((error as NSError).code)"
            }
        }
    }

    func testSecureTransport(_ identifier: UUID) {
        guard accessories[identifier] != nil else {
            updateSpark(identifier) { $0.transportState = .failed(code: "accessory-not-restored") }
            return
        }

        automaticProbeIDs.insert(identifier)
        transports.removeValue(forKey: identifier)?.cancel()
        let transport = SparkBLEPingTransport(identifier: identifier) { [weak self] state in
            DispatchQueue.main.async {
                self?.updateSpark(identifier) { $0.transportState = state }
            }
        }
        transports[identifier] = transport
        transport.start()
    }

    /// Request Apple's per-accessory sharing policy sequentially. System sheets must not be
    /// presented concurrently, and each selected Spark receives its own authorization.
    func requestWiFiSharingForSelection() async {
        for identifier in selectedIDs {
            guard let accessory = accessories[identifier] else {
                updateSpark(identifier) {
                    $0.wiFiSharingState = .failed(code: "accessory-not-restored")
                }
                continue
            }

            updateSpark(identifier) { $0.wiFiSharingState = .requesting }
            do {
                let controller = try await WINetworkSharingController(for: accessory)
                sharingControllers[identifier] = controller
                let authorization = try await controller.requestAuthorization()
                updateAuthorization(identifier, authorization)
            } catch {
                updateSpark(identifier) {
                    $0.wiFiSharingState = .failed(code: Self.sharingErrorCode(error))
                }
            }
        }
    }

    /// Ask iOS to share the current network separately with every selected Spark.
    func shareCurrentNetworkWithSelection() async {
        for identifier in selectedIDs {
            guard let accessory = accessories[identifier] else {
                updateSpark(identifier) {
                    $0.manualShareState = .failed(code: "accessory-not-restored")
                }
                continue
            }

            updateSpark(identifier) { $0.manualShareState = .requesting }
            do {
                let controller: WINetworkSharingController
                if let existing = sharingControllers[identifier] {
                    controller = existing
                } else {
                    controller = try await WINetworkSharingController(for: accessory)
                    sharingControllers[identifier] = controller
                }

                var action = AutoWiFiManualSharePolicy.action(
                    for: sharingAuthorization(of: identifier)
                )
                if action == .requestAuthorization {
                    let authorization = try await controller.requestAuthorization()
                    updateAuthorization(identifier, authorization)
                    action = AutoWiFiManualSharePolicy.action(
                        for: sharingAuthorization(of: identifier)
                    )
                }

                switch action {
                case .askToShare:
                    try await establishSecureConnectionForSharing(identifier)
                    defer { releaseSecureConnectionForSharing(identifier) }
                    let result = try await controller.askToShare()
                    updateSpark(identifier) {
                        switch result {
                        case .approved: $0.manualShareState = .approved
                        case .denied: $0.manualShareState = .denied
                        case .undetermined: $0.manualShareState = .undetermined
                        @unknown default: $0.manualShareState = .failed(code: "share-state")
                        }
                    }
                case .alreadyAutomatic:
                    updateSpark(identifier) { $0.manualShareState = .automatic }
                case .authorizationDenied:
                    updateSpark(identifier) { $0.manualShareState = .denied }
                case .requestAuthorization:
                    updateSpark(identifier) { $0.manualShareState = .undetermined }
                }
            } catch {
                updateSpark(identifier) {
                    $0.manualShareState = .failed(code: Self.sharingErrorCode(error, prefix: "share"))
                }
            }
        }
    }

    private func sharingAuthorization(of identifier: UUID) -> AutoWiFiSharingAuthorization {
        guard let state = sparks[id: identifier]?.wiFiSharingState else { return .failed }
        switch state {
        case .notRequested, .requesting: return .notRequested
        case .undetermined: return .undetermined
        case .denied: return .denied
        case .askToShare: return .askToShare
        case .automatic: return .automatic
        case .failed: return .failed
        }
    }

    private enum SharingConnectionError: Error {
        case failed(code: String)
    }

    /// Hold the encrypted BLE link while the container asks iOS to start the transport
    /// extension. Pairing alone is not a connected accessory, and without this lease iOS can
    /// return the framework's unhelpful general error before it launches the extension.
    private func establishSecureConnectionForSharing(_ identifier: UUID) async throws {
        releaseSecureConnectionForSharing(identifier)
        try await withCheckedThrowingContinuation { continuation in
            sharingConnectionContinuations[identifier] = continuation
            let transport = SparkBLEPingTransport(
                identifier: identifier,
                operation: .holdConnection
            ) { [weak self] transportState in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch transportState {
                    case .ready:
                        self.finishSharingConnection(identifier, result: .success(()))
                    case .failed(let code):
                        self.finishSharingConnection(
                            identifier,
                            result: .failure(SharingConnectionError.failed(code: code))
                        )
                    default:
                        break
                    }
                }
            }
            sharingConnectionTransports[identifier] = transport
            transport.start()
        }
    }

    private func finishSharingConnection(
        _ identifier: UUID,
        result: Result<Void, any Error>
    ) {
        guard let continuation = sharingConnectionContinuations.removeValue(forKey: identifier)
        else { return }
        continuation.resume(with: result)
    }

    private func releaseSecureConnectionForSharing(_ identifier: UUID) {
        sharingConnectionTransports.removeValue(forKey: identifier)?.cancel()
        if let continuation = sharingConnectionContinuations.removeValue(forKey: identifier) {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func updateAuthorization(
        _ identifier: UUID,
        _ authorization: WINetworkSharingController.AuthorizationState
    ) {
        updateSpark(identifier) {
            switch authorization {
            case .undetermined: $0.wiFiSharingState = .undetermined
            case .denied: $0.wiFiSharingState = .denied
            case .askToShare: $0.wiFiSharingState = .askToShare
            case .automatic: $0.wiFiSharingState = .automatic
            @unknown default: $0.wiFiSharingState = .failed(code: "authorization-state")
            }
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated, .accessoryAdded, .accessoryChanged, .accessoryRemoved:
            reconcileAccessories(session.accessories)
        case .pickerDidPresent:
            if sparks.isEmpty { state = .pairing }
        case .pickerDidDismiss:
            state = sparks.isEmpty ? .noSpark : .paired(count: sparks.count)
        case .invalidated:
            state = .failed(code: "session-invalidated")
        default:
            break
        }
    }

    private func reconcileAccessories(_ restored: [ASAccessory]) {
        let available = restored.compactMap { accessory -> (UUID, ASAccessory)? in
            guard let identifier = accessory.bluetoothIdentifier else { return nil }
            return (identifier, accessory)
        }
        let identifiers = available.map(\.0)
        let identifierSet = Set(identifiers)

        for identifier in Set(accessories.keys).subtracting(identifierSet) {
            cleanup(identifier)
        }
        accessories = Dictionary(uniqueKeysWithValues: available)
        selection.reconcile(available: identifiers)

        let previous = Dictionary(uniqueKeysWithValues: sparks.map { ($0.id, $0) })
        sparks = available.map { identifier, accessory in
            var spark = previous[identifier]
                ?? Spark(id: identifier, name: accessory.displayName, isSelected: true)
            spark.name = accessory.displayName
            spark.isSelected = selection.selected.contains(identifier)
            return spark
        }
        state = sparks.isEmpty ? .noSpark : .paired(count: sparks.count)

        if !sparks.isEmpty, !sparks.contains(where: \.isRemoving) {
            removalRecovery.clear()
        }
        if shouldRunAutomaticProbe {
            for identifier in identifiers where !automaticProbeIDs.contains(identifier) {
                DispatchQueue.main.async { [weak self] in
                    self?.testSecureTransport(identifier)
                }
            }
        }
    }

    private func cleanup(_ identifier: UUID) {
        transports.removeValue(forKey: identifier)?.cancel()
        removalTransports.removeValue(forKey: identifier)?.cancel()
        releaseSecureConnectionForSharing(identifier)
        sharingControllers.removeValue(forKey: identifier)
        automaticProbeIDs.remove(identifier)
        accessories.removeValue(forKey: identifier)
    }

    private func applySelection() {
        for index in sparks.indices {
            sparks[index].isSelected = selection.selected.contains(sparks[index].id)
        }
    }

    private func updateSpark(_ identifier: UUID, _ update: (inout Spark) -> Void) {
        guard let index = sparks.firstIndex(where: { $0.id == identifier }) else { return }
        update(&sparks[index])
    }

    private static func sharingErrorCode(_ error: Error, prefix: String? = nil) -> String {
        let code: String
        if case SharingConnectionError.failed(let transportCode) = error {
            code = "transport-\(transportCode)"
        } else {
            code = autoWiFiSharingErrorCode(error)
        }
        return prefix.map { "\($0)-\(code)" } ?? code
    }
}

private extension Array where Element == AccessorySessionModel.Spark {
    subscript(id identifier: UUID) -> Element? {
        first(where: { $0.id == identifier })
    }
}
