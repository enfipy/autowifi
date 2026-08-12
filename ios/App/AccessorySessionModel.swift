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
        case paired(name: String)
        case failed(code: String)

        var title: String {
            switch self {
            case .starting: "Starting"
            case .noSpark: "No Spark paired"
            case .pairing: "Looking for Spark"
            case .paired: "Spark paired"
            case .failed: "Needs attention"
            }
        }

        var detail: String {
            switch self {
            case .starting:
                "Activating AccessorySetupKit"
            case .noSpark:
                "Start the Autowifi daemon on the Spark, then add it here."
            case .pairing:
                "Keep the iPhone close to the Spark."
            case .paired(let name):
                "\(name) is authorized for this app."
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
            case .askToShare: "Wi-Fi sharing: ask every time"
            case .automatic: "Wi-Fi sharing: automatic"
            case .failed(let code): "Wi-Fi sharing failed: \(code)"
            }
        }

        var isRequesting: Bool {
            self == .requesting
        }
    }

    enum ManualShareState: Equatable {
        case notRequested
        case requesting
        case approved
        case denied
        case undetermined
        case failed(code: String)

        var title: String {
            switch self {
            case .notRequested: "No network requested"
            case .requesting: "Requesting current network"
            case .approved: "Current network shared"
            case .denied: "Current network not shared"
            case .undetermined: "Network sharing is undetermined"
            case .failed(let code): "Network request failed: \(code)"
            }
        }

        var isRequesting: Bool { self == .requesting }
    }

    @Published private(set) var state: State = .starting
    @Published private(set) var bluetoothIdentifier: UUID?
    @Published private(set) var transportState: SparkBLEPingTransport.State = .disconnected
    @Published private(set) var wiFiSharingState: WiFiSharingState = .notRequested
    @Published private(set) var manualShareState: ManualShareState = .notRequested
    @Published private(set) var isRemovingSpark = false
    @Published private(set) var removalErrorCode: String?
    @Published private(set) var removalRecoverySeconds = 0

    private let session = ASAccessorySession()
    private var currentAccessory: ASAccessory?
    private var transport: SparkBLEPingTransport?
    private var removalTransport: SparkBLEPingTransport?
    private var hasStartedAutomaticProbe = false
    private var sharingController: WINetworkSharingController?
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
        state = .pairing
        do {
            try await session.showPicker(for: AccessoryCatalog.pickerItems())
        } catch {
            state = .failed(code: "picker-\((error as NSError).code)")
        }
    }

    func removeSpark() async {
        guard let currentAccessory, let bluetoothIdentifier, !isRemovingSpark else { return }
        transport?.cancel()
        transport = nil
        transportState = .disconnected
        hasStartedAutomaticProbe = false
        removalTransport?.cancel()
        removalErrorCode = nil
        isRemovingSpark = true
        removalRecovery.start()

        do {
            let requestID = UUID()
            let frame = try AutoWiFiFrameCodec.frame(
                AutoWiFiForgetRequestMessage(requestID: requestID)
            )
            let removalTransport = SparkBLEPingTransport(
                identifier: bluetoothIdentifier,
                forgetFrame: frame,
                requestID: requestID
            ) { [weak self] transportState in
                DispatchQueue.main.async {
                    guard let self, self.isRemovingSpark else { return }
                    switch transportState {
                    case .succeeded:
                        Task { await self.finishRemovingSpark(currentAccessory) }
                    case .failed(let code):
                        self.removalTransport = nil
                        self.isRemovingSpark = false
                        self.removalErrorCode = code
                    default:
                        break
                    }
                }
            }
            self.removalTransport = removalTransport
            removalTransport.start()
        } catch {
            isRemovingSpark = false
            removalErrorCode = "encode"
        }
    }

    private func finishRemovingSpark(_ accessory: ASAccessory) async {
        removalTransport = nil
        do {
            // Ordering is security-critical: the encrypted GATT acknowledgement means the
            // Spark has scheduled removal of this iPhone's BlueZ bond and reopened owner
            // onboarding. Removing the iOS record first recreates an asymmetric stale bond.
            try await session.removeAccessory(accessory)
            currentAccessory = nil
            bluetoothIdentifier = nil
            sharingController = nil
            wiFiSharingState = .notRequested
            manualShareState = .notRequested
            isRemovingSpark = false
            removalErrorCode = nil
            state = .noSpark
        } catch {
            isRemovingSpark = false
            removalErrorCode = "ios-remove-\((error as NSError).code)"
        }
    }

    func testSecureTransport() {
        guard let bluetoothIdentifier else {
            transportState = .failed(code: "accessory-not-restored")
            return
        }

        hasStartedAutomaticProbe = true
        transport?.cancel()
        let transport = SparkBLEPingTransport(identifier: bluetoothIdentifier) { [weak self] state in
            DispatchQueue.main.async {
                self?.transportState = state
            }
        }
        self.transport = transport
        transport.start()
    }

    func requestWiFiSharing() async {
        guard let currentAccessory else {
            wiFiSharingState = .failed(code: "accessory-not-restored")
            return
        }

        wiFiSharingState = .requesting
        do {
            let controller = try await WINetworkSharingController(for: currentAccessory)
            sharingController = controller
            switch try await controller.requestAuthorization() {
            case .undetermined:
                wiFiSharingState = .undetermined
            case .denied:
                wiFiSharingState = .denied
            case .askToShare:
                wiFiSharingState = .askToShare
            case .automatic:
                wiFiSharingState = .automatic
            @unknown default:
                wiFiSharingState = .failed(code: "authorization-state")
            }
        } catch let error as WINetworkSharingError {
            wiFiSharingState = .failed(code: Self.wiFiSharingErrorCode(error))
        } catch {
            let diagnostic = error as NSError
            let domain = diagnostic.domain
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9.-]", with: "-", options: .regularExpression)
            wiFiSharingState = .failed(code: "\(domain)-\(diagnostic.code)")
        }
    }

    func shareCurrentNetwork() async {
        guard let sharingController else {
            manualShareState = .failed(code: "authorization-required")
            return
        }
        manualShareState = .requesting
        do {
            switch try await sharingController.askToShare() {
            case .approved:
                manualShareState = .approved
            case .denied:
                manualShareState = .denied
            case .undetermined:
                manualShareState = .undetermined
            @unknown default:
                manualShareState = .failed(code: "share-state")
            }
        } catch let error as WINetworkSharingError {
            manualShareState = .failed(code: Self.wiFiSharingErrorCode(error))
        } catch {
            let diagnostic = error as NSError
            manualShareState = .failed(code: "share-\(diagnostic.code)")
        }
    }

    private func handle(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            if let accessory = session.accessories.first {
                use(accessory)
            } else {
                state = .noSpark
            }
        case .accessoryAdded, .accessoryChanged:
            if let accessory = event.accessory {
                use(accessory)
            }
        case .accessoryRemoved:
            transport?.cancel()
            transport = nil
            removalTransport?.cancel()
            removalTransport = nil
            currentAccessory = nil
            bluetoothIdentifier = nil
            transportState = .disconnected
            hasStartedAutomaticProbe = false
            sharingController = nil
            wiFiSharingState = .notRequested
            manualShareState = .notRequested
            isRemovingSpark = false
            removalErrorCode = nil
            state = .noSpark
        case .pickerDidPresent:
            state = .pairing
        case .pickerDidDismiss:
            if currentAccessory == nil, case .pairing = state {
                state = .noSpark
            }
        case .invalidated:
            state = .failed(code: "session-invalidated")
        default:
            break
        }
    }

    private func use(_ accessory: ASAccessory) {
        if !isRemovingSpark {
            removalRecovery.clear()
        }
        let identifierChanged = bluetoothIdentifier != accessory.bluetoothIdentifier
        if identifierChanged {
            transport?.cancel()
            transport = nil
            transportState = .disconnected
            hasStartedAutomaticProbe = false
        }
        currentAccessory = accessory
        bluetoothIdentifier = accessory.bluetoothIdentifier
        state = .paired(name: accessory.displayName)

        if shouldRunAutomaticProbe,
           accessory.bluetoothIdentifier != nil,
           !hasStartedAutomaticProbe {
            hasStartedAutomaticProbe = true
            DispatchQueue.main.async { [weak self] in
                self?.testSecureTransport()
            }
        }
    }

    private static func wiFiSharingErrorCode(_ error: WINetworkSharingError) -> String {
        switch error {
        case .error: "error"
        case .timeout: "timeout"
        case .communicationFailure: "communication-failure"
        case .wifiNetworkSharingUnsupported: "unsupported"
        case .appNotPermitted: "app-not-permitted"
        case .appNotInForeground: "app-not-foreground"
        case .accessoryTransportNotSecured: "accessory-transport-not-secured"
        case .accessoryNotConfigured: "accessory-not-configured"
        case .accessoryNotAuthorized: "accessory-not-authorized"
        case .accessoryNotConnected: "accessory-not-connected"
        case .noAvailableNetworks: "no-networks"
        case .tooManyRequests: "too-many-requests"
        case .noAccessoryScanResponse: "no-scan-response"
        case .noMatchingAccessoryScanRequest: "no-matching-scan-request"
        @unknown default: "unknown"
        }
    }
}
