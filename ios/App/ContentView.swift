import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AccessorySessionModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: iconName)
                    .font(.system(size: 58))
                    .foregroundStyle(iconColor)

                VStack(spacing: 8) {
                    Text(model.state.title)
                        .font(.title2.bold())
                    Text(model.state.detail)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if case .paired = model.state {
                    if let identifier = model.bluetoothIdentifier {
                        LabeledContent("Bluetooth ID", value: identifier.uuidString)
                            .font(.caption.monospaced())
                    }

                    Label(model.transportState.title, systemImage: transportIcon)
                        .foregroundStyle(transportColor)
                        .multilineTextAlignment(.center)

                    Button("Test encrypted BLE") {
                        model.testSecureTransport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.transportState.isRunning)

                    Label(model.wiFiSharingState.title, systemImage: "wifi")
                        .foregroundStyle(sharingColor)
                        .multilineTextAlignment(.center)

                    Button("Authorize Wi-Fi sharing") {
                        Task { await model.requestWiFiSharing() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.wiFiSharingState.isRequesting)

                    if model.wiFiSharingState == .askToShare {
                        Label(model.manualShareState.title, systemImage: "wifi.badge.checkmark")
                            .foregroundStyle(manualShareColor)
                            .multilineTextAlignment(.center)

                        Button("Share current network") {
                            Task { await model.shareCurrentNetwork() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.manualShareState.isRequesting)
                    }

                    if let removalErrorCode = model.removalErrorCode {
                        Label(
                            "Removal failed: \(removalErrorCode)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }

                    Button(
                        model.isRemovingSpark ? "Preparing Spark…" : "Remove Spark",
                        role: .destructive
                    ) {
                        Task { await model.removeSpark() }
                    }
                    .disabled(model.isRemovingSpark)
                } else {
                    if model.removalRecoverySeconds > 0 {
                        Label(
                            "Bluetooth is resetting. Try again in \(model.removalRecoverySeconds)s.",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    }

                    Button("Add DGX Spark") {
                        Task { await model.presentPicker() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.state == .pairing
                            || model.state == .starting
                            || model.removalRecoverySeconds > 0
                    )
                }
            }
            .padding(28)
            .navigationTitle("Autowifi")
        }
    }

    private var iconName: String {
        switch model.state {
        case .paired: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "wifi.router"
        }
    }

    private var iconColor: Color {
        switch model.state {
        case .paired: .green
        case .failed: .orange
        default: .blue
        }
    }

    private var transportIcon: String {
        if model.transportState.succeeded { return "checkmark.shield.fill" }
        if case .failed = model.transportState { return "exclamationmark.triangle.fill" }
        if model.transportState.isRunning { return "antenna.radiowaves.left.and.right" }
        return "shield"
    }

    private var transportColor: Color {
        if model.transportState.succeeded { return .green }
        if case .failed = model.transportState { return .orange }
        return .secondary
    }

    private var sharingColor: Color {
        switch model.wiFiSharingState {
        case .automatic: .green
        case .denied, .failed: .orange
        default: .secondary
        }
    }

    private var manualShareColor: Color {
        switch model.manualShareState {
        case .approved: .green
        case .denied, .failed: .orange
        default: .secondary
        }
    }
}
