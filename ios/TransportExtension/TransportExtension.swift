import AccessorySetupKit
import AccessoryTransportExtension
import ExtensionFoundation
import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "AutowifiTransport",
    category: "lifecycle"
)

@available(iOS 26.2, *)
@main
struct TransportExtension: AccessoryTransportAppExtension {
    @AppExtensionPoint.Bind
    static var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier("com.apple.accessory-transport-extension")
    }

    func accept(
        sessionRequest: AccessoryTransportSession.Request
    ) -> AccessoryTransportSession.Request.Decision {
        sessionRequest.accept {
            SessionHandler(session: sessionRequest.session)
        }
    }

    // AccessorySetupKit and CoreBluetooth callbacks are both delivered on the
    // main queue. Provider callbacks explicitly hop there before touching state.
    final class SessionHandler: AccessoryTransportSession.EventHandler, @unchecked Sendable {
        private let transportSession: AccessoryTransportSession
        private let accessorySession = ASAccessorySession()
        private var pingTransport: SparkBLEPingTransport?
        private var credentialTransport: SparkBLEPingTransport?
        private var networkForwarder: MinimumNetworkEventForwarder?
        private var pendingCredentials: [(frame: Data, requestID: UUID)] = []
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
            DispatchQueue.main.async { [weak self] in
                self?.invalidate()
            }
        }

        @available(iOS 26.5, *)
        func sessionInvalidated(error: AccessoryTransportSession.Error?) {
            DispatchQueue.main.async { [weak self] in
                self?.invalidate()
            }
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
            case .activated:
                guard accessorySession.accessories.count == 1,
                      let accessory = accessorySession.accessories.first,
                      let identifier = accessory.bluetoothIdentifier else {
                    logger.error("Extension requires exactly one configured accessory")
                    transportSession.cancel(error: .unsupported)
                    return
                }
                startPing(accessory: accessory, identifier: identifier)
            case .invalidated:
                invalidate()
            default:
                break
            }
        }

        private func startPing(accessory: ASAccessory, identifier: UUID) {
            guard pingTransport == nil, !invalidated else { return }
            let transport = SparkBLEPingTransport(identifier: identifier) { [weak self] state in
                self?.handlePingState(state, accessory: accessory, identifier: identifier)
            }
            pingTransport = transport
            transport.start()
        }

        private func handlePingState(
            _ state: SparkBLEPingTransport.State,
            accessory: ASAccessory,
            identifier: UUID
        ) {
            switch state {
            case .succeeded:
                logger.info("Extension encrypted transport ping succeeded")
                DispatchQueue.main.async { [weak self] in
                    self?.pingTransport = nil
                    self?.startNetworkForwarder(accessory: accessory, identifier: identifier)
                }
            case .failed(let code):
                logger.error("Extension encrypted transport ping failed: \(code, privacy: .public)")
                transportSession.cancel(error: .unknown)
            default:
                break
            }
        }

        private func startNetworkForwarder(accessory: ASAccessory, identifier: UUID) {
            guard networkForwarder == nil, !invalidated else { return }
            let forwarder = MinimumNetworkEventForwarder(accessory: accessory) { [weak self] frame, requestID in
                DispatchQueue.main.async {
                    self?.enqueueCredential(frame: frame, requestID: requestID, identifier: identifier)
                }
            }
            networkForwarder = forwarder
            forwarder.start()
            logger.info("Extension network provider started")
        }

        private func enqueueCredential(frame: Data, requestID: UUID, identifier: UUID) {
            guard !invalidated else { return }
            pendingCredentials.append((frame, requestID))
            sendNextCredential(identifier: identifier)
        }

        private func sendNextCredential(identifier: UUID) {
            guard credentialTransport == nil,
                  !pendingCredentials.isEmpty,
                  !invalidated else { return }
            let next = pendingCredentials.removeFirst()
            let transport = SparkBLEPingTransport(
                identifier: identifier,
                credentialFrame: next.frame,
                requestID: next.requestID
            ) { [weak self] state in
                self?.handleCredentialState(state, identifier: identifier)
            }
            credentialTransport = transport
            transport.start()
        }

        private func handleCredentialState(
            _ state: SparkBLEPingTransport.State,
            identifier: UUID
        ) {
            switch state {
            case .succeeded:
                logger.info("Extension credential request accepted")
                DispatchQueue.main.async { [weak self] in
                    self?.credentialTransport = nil
                    self?.sendNextCredential(identifier: identifier)
                }
            case .failed(let code):
                logger.error("Extension credential request failed: \(code, privacy: .public)")
                transportSession.cancel(error: .unknown)
            default:
                break
            }
        }

        private func invalidate() {
            guard !invalidated else { return }
            invalidated = true
            pingTransport?.cancel()
            pingTransport = nil
            credentialTransport?.cancel()
            credentialTransport = nil
            pendingCredentials.removeAll(keepingCapacity: false)
            networkForwarder?.stop()
            networkForwarder = nil
            accessorySession.invalidate()
            logger.info("Extension transport session invalidated")
        }
    }
}
