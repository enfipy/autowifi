import Foundation
import AccessorySetupKit
import WiFiInfrastructure

/// Stable, accessory-owned wire DTO. Do not expose Apple's Codable layout as
/// the protocol: Apple does not document that JSON representation as a wire ABI.
@available(iOS 26.2, *)
struct AutoWiFiCredential: Codable, Equatable {
    static let maximumPayloadBytes = 65_536

    let version: Int
    let type: String
    let requestID: UUID
    let ssid: Data
    let hidden: Bool
    let security: [String]
    let credential: Credential

    struct Credential: Codable, Equatable {
        let kind: String
        let password: String?
    }

    enum MappingError: Error {
        case unsupportedSecurity
        case unsupportedCredential
        case payloadTooLarge
    }

    init(network: WINetworkSharingProvider.Network, requestID: UUID = UUID()) throws {
        let policies = try network.securityPolicy.map(Self.mapPolicy).sorted()
        guard !policies.isEmpty else { throw MappingError.unsupportedSecurity }

        let mappedCredential = try Self.mapCredential(network.credentials)

        version = 1
        type = "wifi-credential"
        self.requestID = requestID
        ssid = network.ssid.data
        hidden = !network.isSSIDBroadcast
        security = policies
        credential = mappedCredential
    }

    private static func mapPolicy(
        _ policy: WINetworkSharingProvider.Network.SecurityPolicy
    ) throws -> String {
        switch policy {
        case .open: "open"
        case .owe: "owe"
        case .wpa2: "wpa2"
        case .wpa3: "wpa3"
        case .wep, .wpa: throw MappingError.unsupportedSecurity
        @unknown default: throw MappingError.unsupportedSecurity
        }
    }

    private static func mapCredential(
        _ credentials: WINetworkSharingProvider.Network.Credentials
    ) throws -> Credential {
        if #available(iOS 26.4, *) {
            switch credentials {
            case .none:
                return Credential(kind: "none", password: nil)
            case .password(let password):
                return Credential(kind: "password", password: password)
            case .enterprise:
                throw MappingError.unsupportedCredential
            @unknown default:
                throw MappingError.unsupportedCredential
            }
        } else {
            switch credentials {
            case .none:
                return Credential(kind: "none", password: nil)
            case .password(let password):
                return Credential(kind: "password", password: password)
            default:
                throw MappingError.unsupportedCredential
            }
        }
    }

    func framed() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(self)
        guard payload.count <= Self.maximumPayloadBytes else {
            throw MappingError.payloadTooLarge
        }

        var length = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }
}

/// Framework-to-transport seam used by the Accessory Transport Extension.
/// The BLE layer supplies `sendFrame`; this type owns no UI and logs no data.
@available(iOS 26.2, *)
final class MinimumNetworkEventForwarder {
    private let accessory: ASAccessory
    private let sendFrame: @Sendable (Data) async throws -> Void
    private var task: Task<Void, Never>?

    init(
        accessory: ASAccessory,
        sendFrame: @escaping @Sendable (Data) async throws -> Void
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
                            let frame = try AutoWiFiCredential(network: network).framed()
                            try await sendFrame(frame)
                        } catch AutoWiFiCredential.MappingError.unsupportedSecurity,
                                AutoWiFiCredential.MappingError.unsupportedCredential {
                            continue
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Report a redacted transport failure through the extension's
                // own state channel. Never print the event or encoded payload.
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
