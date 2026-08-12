import Foundation

public enum AutoWiFiWireError: Error, Equatable {
    case invalidFrameLength
    case payloadTooLarge
    case invalidMessage
    case invalidTransition
}

public struct AutoWiFiPingMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID

    public init(requestID: UUID) {
        version = AutoWiFiConstants.protocolVersion
        type = "transport-ping"
        self.requestID = requestID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "transport-ping"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        self.init(requestID: try values.decode(UUID.self, forKey: .requestID))
    }
}

public struct AutoWiFiPongMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID

    public init(requestID: UUID) {
        version = AutoWiFiConstants.protocolVersion
        type = "transport-pong"
        self.requestID = requestID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "transport-pong"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        self.init(requestID: try values.decode(UUID.self, forKey: .requestID))
    }
}

public struct AutoWiFiForgetRequestMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID

    public init(requestID: UUID) {
        version = AutoWiFiConstants.protocolVersion
        type = "accessory-forget"
        self.requestID = requestID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "accessory-forget"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        self.init(requestID: try values.decode(UUID.self, forKey: .requestID))
    }
}

public struct AutoWiFiForgetReadyMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID

    public init(requestID: UUID) {
        version = AutoWiFiConstants.protocolVersion
        type = "accessory-forget-ready"
        self.requestID = requestID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "accessory-forget-ready"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        self.init(requestID: try values.decode(UUID.self, forKey: .requestID))
    }
}

public enum AutoWiFiSecurity: String, Codable, CaseIterable, Sendable {
    case open
    case owe
    case wpa2
    case wpa3
}

public struct AutoWiFiCredentialValue: Codable, Equatable, Sendable {
    public let kind: String
    public let password: String?

    public init(kind: String, password: String?) {
        self.kind = kind
        self.password = password
    }
}

public struct AutoWiFiCredentialMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID
    public let ssid: Data
    public let hidden: Bool
    public let security: [AutoWiFiSecurity]
    public let credential: AutoWiFiCredentialValue

    public init(
        requestID: UUID,
        ssid: Data,
        hidden: Bool,
        security: [AutoWiFiSecurity],
        credential: AutoWiFiCredentialValue
    ) throws {
        guard (1 ... 32).contains(ssid.count), !security.isEmpty else {
            throw AutoWiFiWireError.invalidMessage
        }
        let policies = Set(security)
        let isOpen = policies == [.open]
        let isOWE = policies.contains(.owe) && policies.isSubset(of: [.open, .owe])
        let isPersonal = policies.isSubset(of: [.wpa2, .wpa3])
        guard isOpen || isOWE || isPersonal else {
            throw AutoWiFiWireError.invalidMessage
        }
        if isOpen || isOWE {
            guard credential.kind == "none", credential.password == nil else {
                throw AutoWiFiWireError.invalidMessage
            }
        } else {
            guard credential.kind == "password", credential.password?.isEmpty == false else {
                throw AutoWiFiWireError.invalidMessage
            }
        }

        version = AutoWiFiConstants.protocolVersion
        type = "wifi-credential"
        self.requestID = requestID
        self.ssid = ssid
        self.hidden = hidden
        self.security = security.sorted { $0.rawValue < $1.rawValue }
        self.credential = credential
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "wifi-credential"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        try self.init(
            requestID: values.decode(UUID.self, forKey: .requestID),
            ssid: values.decode(Data.self, forKey: .ssid),
            hidden: values.decode(Bool.self, forKey: .hidden),
            security: values.decode([AutoWiFiSecurity].self, forKey: .security),
            credential: values.decode(AutoWiFiCredentialValue.self, forKey: .credential)
        )
    }
}

public enum AutoWiFiStatusState: String, Codable, Sendable {
    case received
    case connecting
    case connected
    case failed

    public func canTransition(to next: Self) -> Bool {
        switch (self, next) {
        case (.received, .connecting), (.connecting, .connected), (.connecting, .failed):
            true
        default:
            false
        }
    }
}

public struct AutoWiFiStatusMessage: Codable, Equatable, Sendable {
    public let version: Int
    public let type: String
    public let requestID: UUID
    public let state: AutoWiFiStatusState
    public let error: String?

    public init(requestID: UUID, state: AutoWiFiStatusState, error: String? = nil) throws {
        guard
            (state == .failed && error?.isEmpty == false)
                || (state != .failed && error == nil)
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        version = AutoWiFiConstants.protocolVersion
        type = "wifi-status"
        self.requestID = requestID
        self.state = state
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard
            try values.decode(Int.self, forKey: .version) == AutoWiFiConstants.protocolVersion,
            try values.decode(String.self, forKey: .type) == "wifi-status"
        else {
            throw AutoWiFiWireError.invalidMessage
        }
        try self.init(
            requestID: values.decode(UUID.self, forKey: .requestID),
            state: values.decode(AutoWiFiStatusState.self, forKey: .state),
            error: values.decodeIfPresent(String.self, forKey: .error)
        )
    }
}

public enum AutoWiFiFrameCodec {
    public static func payload<T: Encodable>(for message: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(message)
        guard !payload.isEmpty, payload.count <= AutoWiFiConstants.maximumPayloadBytes else {
            throw AutoWiFiWireError.payloadTooLarge
        }
        return payload
    }

    public static func frame<T: Encodable>(_ message: T) throws -> Data {
        let payload = try payload(for: message)
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }
}

public struct AutoWiFiFrameDecoder: Sendable {
    private var buffer = Data()
    private let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = AutoWiFiConstants.maximumPayloadBytes) {
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public mutating func feed(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var payloads: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= maximumPayloadBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw AutoWiFiWireError.invalidFrameLength
            }
            let messageLength = 4 + Int(length)
            guard buffer.count >= messageLength else { break }
            payloads.append(buffer.subdata(in: 4 ..< messageLength))
            buffer.removeSubrange(0 ..< messageLength)
        }
        return payloads
    }
}
