import Foundation
import AccessorySetupKit
import WiFiInfrastructure
import os

private let networkSharingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AutowifiTransport",
    category: "network-sharing"
)

@available(iOS 26.2, *)
func autoWiFiSharingErrorCode(_ error: Error) -> String {
    if let error = error as? WINetworkSharingError {
        return switch error {
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

    let diagnostic = error as NSError
    let domain = diagnostic.domain
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9.-]", with: "-", options: .regularExpression)
    return "\(domain)-\(diagnostic.code)"
}

@available(iOS 26.2, *)
enum AutoWiFiNetworkMappingError: Error {
    case unsupportedSecurity
    case unsupportedCredential
}

@available(iOS 26.2, *)
extension AutoWiFiCredentialMessage {
    init(network: WINetworkSharingProvider.Network, requestID: UUID = UUID()) throws {
        let policies = try Set(network.securityPolicy.map(Self.mapPolicy))
            .sorted { $0.rawValue < $1.rawValue }
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
        // NetworkManager's `wpa-psk` key management handles WPA and WPA2 personal
        // networks. Normalize iOS's legacy/mixed WPA marker to the wire protocol's
        // WPA2-compatible PSK mode instead of dropping the entire network.
        case .wpa, .wpa2: .wpa2
        case .wpa3: .wpa3
        case .wep: throw AutoWiFiNetworkMappingError.unsupportedSecurity
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

                    networkSharingLogger.info(
                        "Sharing event app-requested=\(event.appRequestedSharing, privacy: .public) new-available=\(event.newShareableNetworkAvailable, privacy: .public) network-count=\(event.networks.count, privacy: .public)"
                    )

                    if event.appRequestedSharing || event.newShareableNetworkAvailable {
                        // A picker failure must not discard networks that are already present on
                        // this event (notably under Automatically Share authorization).
                        do {
                            _ = try await provider.presentAskToShareUI(scanProvider: nil)
                        } catch {
                            networkSharingLogger.error(
                                "Sharing UI unavailable: \(autoWiFiSharingErrorCode(error), privacy: .public)"
                            )
                        }
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
                            networkSharingLogger.error(
                                "Skipped unsupported network representation"
                            )
                            continue
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Never log the event, network description, or encoded payload.
                networkSharingLogger.error(
                    "Sharing provider failed: \(autoWiFiSharingErrorCode(error), privacy: .public)"
                )
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
