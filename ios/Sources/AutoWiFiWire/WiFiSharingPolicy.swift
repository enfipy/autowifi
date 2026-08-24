/// Pure decisions used by the app while sharing the current Wi-Fi network.
/// Framework calls remain in the app so this policy stays portable and testable.
public enum AutoWiFiSharingPolicy {
    public enum Authorization: Equatable, Sendable {
        case notRequested
        case undetermined
        case denied
        case askToShare
        case automatic
        case failed
    }

    public enum Action: Equatable, Sendable {
        case requestAuthorization
        case askToShare
        case authorizationDenied
    }

    public enum BatchAction: Equatable, Sendable {
        case `continue`
        case stop
    }

    private static let errorCodes = [
        "error",
        "timeout",
        "communication-failure",
        "unsupported",
        "app-not-permitted",
        "app-not-foreground",
        "accessory-transport-not-secured",
        "accessory-not-configured",
        "accessory-not-authorized",
        "accessory-not-connected",
        "no-networks",
        "too-many-requests",
        "no-scan-response",
        "no-matching-scan-request",
    ]

    public static func action(for authorization: Authorization) -> Action {
        switch authorization {
        case .askToShare, .automatic:
            // Automatic mode handles future joins. An explicit app action still signals the
            // extension so the accessory receives the network the phone already uses.
            .askToShare
        case .denied:
            .authorizationDenied
        case .notRequested, .undetermined, .failed:
            .requestAuthorization
        }
    }

    /// Preserve the concrete framework code when Wi-Fi Infrastructure bridges its Swift error
    /// enum through NSError instead of collapsing every failure to the generic `.error` case.
    public static func errorCode(domain: String, code: Int) -> String? {
        let normalizedDomain = domain.lowercased().filter(\.isLetter)
        guard (
            normalizedDomain.hasSuffix("wifinetworksharingerror")
                || normalizedDomain.hasSuffix("winetworksharingerror")
        ),
              errorCodes.indices.contains(code) else { return nil }
        return errorCodes[code]
    }

    /// These framework failures apply to the whole request stream. Continuing would immediately
    /// repeat a request while the app is inactive or iOS is rate-limiting it.
    public static func batchAction(after errorCode: String) -> BatchAction {
        switch errorCode {
        case "app-not-foreground", "too-many-requests": .stop
        default: .continue
        }
    }

    /// OWE-transition access points advertise encrypted OWE and open compatibility BSSes. Use
    /// the compatibility profile when both are advertised; retain OWE for OWE-only networks.
    public static func effectiveSecurityPolicies(
        _ policies: Set<AutoWiFiSecurity>
    ) -> Set<AutoWiFiSecurity> {
        policies == [.open, .owe] ? [.open] : policies
    }
}
