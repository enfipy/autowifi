import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AccessorySessionModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Autowifi")
                        .font(.largeTitle.bold())
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                Divider()

                ScrollView {
                    VStack(spacing: 20) {
                        header

                        if model.sparks.isEmpty {
                            emptyState
                        } else {
                            selectionBar

                            ForEach(model.sparks) { spark in
                                SparkCard(
                                    spark: spark,
                                    toggleSelection: { model.toggleSelection(spark.id) },
                                    testTransport: { model.testSecureTransport(spark.id) },
                                    remove: { Task { await model.removeSpark(spark.id) } },
                                    forgetOnIPhone: {
                                        Task { await model.forgetSparkOnIPhone(spark.id) }
                                    }
                                )
                            }

                            sharingActions
                        }

                        if model.removalRecoverySeconds > 0 {
                            Label(
                                "Bluetooth is resetting. Add another Spark in \(model.removalRecoverySeconds)s.",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        }

                        Button(model.sparks.isEmpty ? "Add DGX Spark" : "Add another Spark") {
                            Task { await model.presentPicker() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.state == .pairing
                                || model.state == .starting
                                || model.removalRecoverySeconds > 0
                        )
                    }
                    .padding(20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 52))
                .foregroundStyle(iconColor)
            Text(model.state.title)
                .font(.title2.bold())
            Text(model.state.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("Each Spark pairs directly with this iPhone and receives its own Wi-Fi authorization.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
    }

    private var selectionBar: some View {
        HStack {
            Text("\(model.selectedCount) selected")
                .font(.headline)
            Spacer()
            Button(model.areAllSelected ? "Deselect all" : "Select all") {
                model.toggleAllSelection()
            }
        }
    }

    private var sharingActions: some View {
        VStack(spacing: 12) {
            Button("Set sharing for selected") {
                Task { await model.requestWiFiSharingForSelection() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedCount == 0 || model.isSharingWithSelection)

            Button("Share current network with selected") {
                Task { await model.shareCurrentNetworkWithSelection() }
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedCount == 0 || model.isSharingWithSelection)

            Text(
                "Apple stores Automatic or Ask Every Time separately for each Spark. "
                    + "Selection controls which Sparks these actions update."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
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
}

private struct SparkCard: View {
    let spark: AccessorySessionModel.Spark
    let toggleSelection: () -> Void
    let testTransport: () -> Void
    let remove: () -> Void
    let forgetOnIPhone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleSelection) {
                HStack(spacing: 12) {
                    Image(systemName: spark.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(spark.isSelected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spark.name)
                            .font(.headline)
                        Text(spark.id.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Label(spark.transportState.title, systemImage: transportIcon)
                .foregroundStyle(transportColor)
            Label(spark.wiFiSharingState.title, systemImage: "wifi")
                .foregroundStyle(sharingColor)
            if spark.manualShareState != .notRequested {
                Label(spark.manualShareState.title, systemImage: "wifi.badge.checkmark")
                    .foregroundStyle(manualShareColor)
            }

            HStack {
                Button("Test encrypted BLE", action: testTransport)
                    .buttonStyle(.bordered)
                    .disabled(spark.transportState.isRunning || spark.isRemoving)
                Spacer()
                Button(spark.isRemoving ? "Preparing…" : "Remove", role: .destructive, action: remove)
                    .disabled(spark.isRemoving)
            }

            if let code = spark.removalErrorCode {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Removal failed: \(code)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("If this Spark already forgot the iPhone bond, repair the stale iOS pairing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Forget on iPhone only", role: .destructive, action: forgetOnIPhone)
                        .buttonStyle(.bordered)
                }
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(spark.isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
        }
    }

    private var transportIcon: String {
        if spark.transportState.succeeded { return "checkmark.shield.fill" }
        if case .failed = spark.transportState { return "exclamationmark.triangle.fill" }
        if spark.transportState.isRunning { return "antenna.radiowaves.left.and.right" }
        return "shield"
    }

    private var transportColor: Color {
        if spark.transportState.succeeded { return .green }
        if case .failed = spark.transportState { return .orange }
        return .secondary
    }

    private var sharingColor: Color {
        switch spark.wiFiSharingState {
        case .automatic: .green
        case .denied, .failed: .orange
        default: .secondary
        }
    }

    private var manualShareColor: Color {
        switch spark.manualShareState {
        case .approved, .automatic: .green
        case .denied, .failed: .orange
        default: .secondary
        }
    }
}
