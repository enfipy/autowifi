import Foundation
import AccessorySetupKit
import WiFiInfrastructure

@available(iOS 26.2, *)
enum AutoWiFiNetworkMappingError: Error {
    case unsupportedSecurity
    case unsupportedCredential
}

@available(iOS 26.2, *)
extension AutoWiFiCredentialMessage {
    init(network: WINetworkSharingProvider.Network, requestID: UUID = UUID()) throws {
        let policies = try network.securityPolicy.map(Self.mapPolicy)
        let mappedCredential = try Self.mapCredential(network.credentials)
        try self.init(
            requestID: requestID,
            ssid: network.ssid.data,
            hidden: !network.isSSIDBroadcast,
            security: policies,
            credential: mappedCredential
        )
    }

    private static func mapPolicy(
        _ policy: WINetworkSharingProvider.Network.SecurityPolicy
    ) throws -> AutoWiFiSecurity {
        switch policy {
        case .open: .open
        case .owe: .owe
        case .wpa2: .wpa2
        case .wpa3: .wpa3
        case .wep, .wpa: throw AutoWiFiNetworkMappingError.unsupportedSecurity
        @unknown default: throw AutoWiFiNetworkMappingError.unsupportedSecurity
        }
    }

    private static func mapCredential(
        _ credentials: WINetworkSharingProvider.Network.Credentials
    ) throws -> AutoWiFiCredentialValue {
        if #available(iOS 26.4, *) {
            switch credentials {
            case .none:
                return AutoWiFiCredentialValue(kind: "none", password: nil)
            case .password(let password):
                return AutoWiFiCredentialValue(kind: "password", password: password)
            case .enterprise:
                throw AutoWiFiNetworkMappingError.unsupportedCredential
            @unknown default:
                throw AutoWiFiNetworkMappingError.unsupportedCredential
            }
        } else {
            switch credentials {
            case .none:
                return AutoWiFiCredentialValue(kind: "none", password: nil)
            case .password(let password):
                return AutoWiFiCredentialValue(kind: "password", password: password)
            default:
                throw AutoWiFiNetworkMappingError.unsupportedCredential
            }
        }
    }
}

/// Framework-to-transport seam used by the Accessory Transport Extension.
/// The BLE layer supplies `sendFrame`; this type owns no UI and logs no data.
@available(iOS 26.2, *)
final class MinimumNetworkEventForwarder {
    private let accessory: ASAccessory
    private let sendFrame: @Sendable (Data, UUID) -> Void
    private var task: Task<Void, Never>?

    init(
        accessory: ASAccessory,
        sendFrame: @escaping @Sendable (Data, UUID) -> Void
    ) {
        self.accessory = accessory
        self.sendFrame = sendFrame
    }

    func start() {
        guard task == nil else { return }
        task = Task { [accessory, sendFrame] in
            do {
                let provider = try await WINetworkSharingProvider(for: accessory)
                for try await event in provider.networkEvents() {
                    try Task.checkCancellation()

                    if event.appRequestedSharing || event.newShareableNetworkAvailable {
                        _ = try await provider.presentAskToShareUI(scanProvider: nil)
                    }

                    // The first slice sends each supported network separately.
                    // Deduplication by event counter/request ID belongs in the
                    // production state machine.
                    for network in event.networks {
                        do {
                            let message = try AutoWiFiCredentialMessage(network: network)
                            let frame = try AutoWiFiFrameCodec.frame(message)
                            sendFrame(frame, message.requestID)
                        } catch AutoWiFiNetworkMappingError.unsupportedSecurity,
                                AutoWiFiNetworkMappingError.unsupportedCredential {
                            continue
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Never log the event, network description, or encoded payload.
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
