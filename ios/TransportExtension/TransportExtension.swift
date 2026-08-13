import AccessorySetupKit
import AccessoryTransportExtension
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AutowifiTransport",
    category: "lifecycle"
)

@available(iOS 26.2, *)
@main
struct TransportExtension: AccessoryTransportAppExtension {
    func accept(
        sessionRequest: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        sessionRequest.accept {
            SessionHandler(session: sessionRequest.session)
        }
    }

    /// One extension session can serve every accessory configured for this app. Each Spark
    /// gets an isolated pipeline so its BLE availability and credential acknowledgements
    /// cannot block or cancel another Spark.
    final class SessionHandler: AccessoryTransportSession.EventHandler, @unchecked Sendable {
        private let transportSession: AccessoryTransportSession
        private let accessorySession = ASAccessorySession()
        private var pipelines: [UUID: AccessoryPipeline] = [:]
        private var invalidated = false

        init(session: AccessoryTransportSession) {
            transportSession = session
            logger.info("Extension transport session accepted")
            accessorySession.activate(on: .main) { [weak self] event in
                self?.handleAccessoryEvent(event)
            }
        }

        @available(iOS, introduced: 26.4, deprecated: 26.5)
        func dataEventHandler(event: AccessoryTransportSession.DataEvent) {}

        @available(iOS, introduced: 26.2, deprecated: 26.5)
        func invalidationHandler(error: AccessoryTransportSession.Error?) {
            DispatchQueue.main.async { [weak self] in self?.invalidate() }
        }

        @available(iOS 26.5, *)
        func sessionInvalidated(error: AccessoryTransportSession.Error?) {
            DispatchQueue.main.async { [weak self] in self?.invalidate() }
        }

        @available(iOS 26.5, *)
        func messageReceived(
            _ message: TransportMessage,
            completion: @escaping @Sendable (AccessoryMessage.Result) -> Void
        ) {
            completion(.success)
        }

        private func handleAccessoryEvent(_ event: ASAccessoryEvent) {
            switch event.eventType {
            case .activated, .accessoryAdded, .accessoryRemoved:
                reconcilePipelines()
            case .accessoryChanged:
                if let identifier = event.accessory?.bluetoothIdentifier {
                    pipelines.removeValue(forKey: identifier)?.stop()
                }
                reconcilePipelines()
            case .invalidated:
                invalidate()
            default:
                break
            }
        }

        private func reconcilePipelines() {
            guard !invalidated else { return }
            let available = accessorySession.accessories.compactMap { accessory -> (UUID, ASAccessory)? in
                guard let identifier = accessory.bluetoothIdentifier else { return nil }
                return (identifier, accessory)
            }
            let availableIDs = Set(available.map(\.0))

            for identifier in Set(pipelines.keys).subtracting(availableIDs) {
                pipelines.removeValue(forKey: identifier)?.stop()
            }
            for (identifier, accessory) in available where pipelines[identifier] == nil {
                let pipeline = AccessoryPipeline(accessory: accessory, identifier: identifier)
                pipelines[identifier] = pipeline
                pipeline.start()
            }
            logger.info("Extension serving \(self.pipelines.count, privacy: .public) accessories")
        }

        private func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            for pipeline in pipelines.values { pipeline.stop() }
            pipelines.removeAll(keepingCapacity: false)
            accessorySession.invalidate()
            logger.info("Extension transport session invalidated")
        }
    }

    final class AccessoryPipeline: @unchecked Sendable {
        private let accessory: ASAccessory
        private let identifier: UUID
        private var pingTransport: SparkBLEPingTransport?
        private var credentialTransport: SparkBLEPingTransport?
        private var networkForwarder: MinimumNetworkEventForwarder?
        private var pendingCredentials: [(frame: Data, requestID: UUID)] = []
        private var retry: DispatchWorkItem?
        private var stopped = false

        init(accessory: ASAccessory, identifier: UUID) {
            self.accessory = accessory
            self.identifier = identifier
        }

        func start() {
            guard pingTransport == nil, networkForwarder == nil, !stopped else { return }
            let transport = SparkBLEPingTransport(identifier: identifier) { [weak self] state in
                self?.handlePingState(state)
            }
            pingTransport = transport
            transport.start()
        }

        private func handlePingState(_ state: SparkBLEPingTransport.State) {
            switch state {
            case .succeeded:
                logger.info("Extension encrypted transport ping succeeded")
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.pingTransport = nil
                    self.startNetworkForwarder()
                }
            case .failed(let code):
                logger.error("Extension encrypted transport ping failed: \(code, privacy: .public)")
                DispatchQueue.main.async { [weak self] in self?.scheduleRetry() }
            default:
                break
            }
        }

        private func startNetworkForwarder() {
            guard networkForwarder == nil, !stopped else { return }
            let forwarder = MinimumNetworkEventForwarder(accessory: accessory) {
                [weak self] frame, requestID in
                    DispatchQueue.main.async {
                        self?.enqueueCredential(frame: frame, requestID: requestID)
                    }
            }
            networkForwarder = forwarder
            forwarder.start()
            logger.info("Extension network provider started for one accessory")
        }

        private func enqueueCredential(frame: Data, requestID: UUID) {
            guard !stopped else { return }
            pendingCredentials.append((frame, requestID))
            sendNextCredential()
        }

        private func sendNextCredential() {
            guard credentialTransport == nil, !pendingCredentials.isEmpty, !stopped else { return }
            let next = pendingCredentials.removeFirst()
            let transport = SparkBLEPingTransport(
                identifier: identifier,
                credentialFrame: next.frame,
                requestID: next.requestID
            ) { [weak self] state in
                self?.handleCredentialState(state)
            }
            credentialTransport = transport
            transport.start()
        }

        private func handleCredentialState(_ state: SparkBLEPingTransport.State) {
            switch state {
            case .succeeded:
                logger.info("Extension credential request connected")
                finishCredential()
            case .failed(let code):
                // This request belongs only to this Spark. Keep the provider and every other
                // Spark pipeline alive; a future network event can retry independently.
                logger.error("Extension credential request failed: \(code, privacy: .public)")
                finishCredential()
            default:
                break
            }
        }

        private func finishCredential() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped else { return }
                self.credentialTransport = nil
                self.sendNextCredential()
            }
        }

        private func scheduleRetry() {
            guard !stopped else { return }
            pingTransport?.cancel()
            pingTransport = nil
            retry?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.start() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }

        func stop() {
            guard !stopped else { return }
            stopped = true
            retry?.cancel()
            retry = nil
            pingTransport?.cancel()
            pingTransport = nil
            credentialTransport?.cancel()
            credentialTransport = nil
            pendingCredentials.removeAll(keepingCapacity: false)
            networkForwarder?.stop()
            networkForwarder = nil
        }
    }
}
