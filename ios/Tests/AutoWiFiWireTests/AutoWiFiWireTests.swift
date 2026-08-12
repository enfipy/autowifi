import Foundation
import Testing
@testable import AutoWiFiWire

private let fixtureRequestID = UUID(uuidString: "FE39D9C7-FAB9-4A51-9D48-6C26684D38FE")!

private func fixture(_ name: String) throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let packageRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: packageRoot.appending(path: "../fixtures/\(name)"))
        .trimmingTrailingNewline()
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        var result = self
        while result.last == 0x0A || result.last == 0x0D {
            result.removeLast()
        }
        return result
    }
}

@Test func generatedConstantsAreFrozen() {
    #expect(AutoWiFiConstants.serviceUUID.uuidString == "7A8D154F-B911-4858-BF22-B82E0C086B2F")
    #expect(AutoWiFiConstants.credentialRXUUID.uuidString == "6927C5F7-C9BA-435C-8DB7-5D7958B19BA8")
    #expect(AutoWiFiConstants.statusTXUUID.uuidString == "0B69E4BD-1320-4C08-8916-CA27E2395C0A")
}

@Test func swiftCredentialEncodingMatchesSharedFixture() throws {
    let message = try AutoWiFiCredentialMessage(
        requestID: fixtureRequestID,
        ssid: Data("WPA2Net".utf8),
        hidden: false,
        security: [.wpa2],
        credential: AutoWiFiCredentialValue(kind: "password", password: "fixture-password")
    )
    #expect(try AutoWiFiFrameCodec.payload(for: message) == fixture("credential-wpa2.json"))
}

@Test func swiftStatusEncodingMatchesSharedFixture() throws {
    let message = try AutoWiFiStatusMessage(
        requestID: fixtureRequestID,
        state: .failed,
        error: "network-activation-failed"
    )
    #expect(try AutoWiFiFrameCodec.payload(for: message) == fixture("status-failed.json"))
}

@Test(arguments: [
    "credential-open.json",
    "credential-owe.json",
    "credential-wpa2.json",
    "credential-wpa3.json",
    "credential-binary-ssid.json",
])
func decodesSharedCredentialFixtures(name: String) throws {
    let message = try JSONDecoder().decode(AutoWiFiCredentialMessage.self, from: fixture(name))
    #expect(message.requestID == fixtureRequestID)
    #expect((1 ... 32).contains(message.ssid.count))
}

@Test(arguments: ["status-received.json", "status-failed.json"])
func decodesSharedStatusFixtures(name: String) throws {
    let status = try JSONDecoder().decode(AutoWiFiStatusMessage.self, from: fixture(name))
    #expect(status.requestID == fixtureRequestID)
}

@Test func rejectsUnsupportedSecurityFixture() throws {
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            AutoWiFiCredentialMessage.self,
            from: fixture("invalid-unsupported-security.json")
        )
    }
}

@Test func frameDecoderHandlesEverySplitPoint() throws {
    let status = try AutoWiFiStatusMessage(requestID: fixtureRequestID, state: .received)
    let framed = try AutoWiFiFrameCodec.frame(status)
    let expected = try AutoWiFiFrameCodec.payload(for: status)

    for split in 0 ..< framed.count {
        var decoder = AutoWiFiFrameDecoder()
        #expect(try decoder.feed(framed.prefix(split)) == [])
        #expect(try decoder.feed(framed.dropFirst(split)) == [expected])
    }

    var completeDecoder = AutoWiFiFrameDecoder()
    #expect(try completeDecoder.feed(framed) == [expected])
}

@Test func statusTransitionsAreExplicit() {
    #expect(AutoWiFiStatusState.received.canTransition(to: .connecting))
    #expect(AutoWiFiStatusState.connecting.canTransition(to: .connected))
    #expect(AutoWiFiStatusState.connecting.canTransition(to: .failed))
    #expect(!AutoWiFiStatusState.received.canTransition(to: .connected))
    #expect(!AutoWiFiStatusState.connected.canTransition(to: .connecting))
}
