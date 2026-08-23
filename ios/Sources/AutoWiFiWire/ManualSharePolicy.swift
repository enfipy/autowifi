/// Pure decision policy for the container app's manual Wi-Fi sharing button.
/// Framework calls remain in the app; this keeps their required ordering testable.
public enum AutoWiFiSharingAuthorization: Equatable, Sendable {
    case notRequested
    case undetermined
    case denied
    case askToShare
    case automatic
    case failed
}

public enum AutoWiFiManualShareAction: Equatable, Sendable {
    case requestAuthorization
    case askToShare
    case authorizationDenied
}

public enum AutoWiFiManualSharePolicy {
    public static func action(
        for authorization: AutoWiFiSharingAuthorization
    ) -> AutoWiFiManualShareAction {
        switch authorization {
        case .askToShare:
            .askToShare
        case .automatic:
            // Automatic mode covers future network joins without prompting. The explicit
            // container-app action still needs to signal the extension so that an already-joined
            // current network is delivered to the accessory.
            .askToShare
        case .denied:
            .authorizationDenied
        case .notRequested, .undetermined, .failed:
            .requestAuthorization
        }
    }
}
