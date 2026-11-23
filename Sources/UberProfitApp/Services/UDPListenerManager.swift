import Foundation
import Network
import UIKit

/// Gerencia o socket UDP local (`127.0.0.1:9876`) com auto-recuperação automática em 2º plano
/// e monitora em tempo real (`UIScreen.main.isCaptured` + Heartbeat UDP) se a transmissão do ReplayKit está ativa.
@MainActor
public final class UDPListenerManager: ObservableObject {
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var broadcastActive: Bool = false
    @Published public private(set) var lastPacketTime: Date?

    public var onOfferReceived: (@Sendable (RideOfferPayload) -> Void)?
    public var onClearCardRequested: (@Sendable () -> Void)?
    public var onRideAcceptedDetected: (@Sendable () -> Void)?
    /// kind: "DECLINED" | "UNKNOWN" | "SNAPSHOT"
    public var onRideOutcome: (@Sendable (String, String) -> Void)?
    public var onHeartbeatReceived: (@Sendable () -> Void)?

    private var listener: NWListener?
    private var screenCheckTimer: Timer?
    private let port: NWEndpoint.Port = 9876
    private let listenerQueue = DispatchQueue(label: "com.uberprofit.udplistener", qos: .userInteractive)

    public init() {
        setupScreenCaptureObserver()
    }

    public func startListening() {
        updateScreenCaptureStatus()
        guard listener == nil else { return }

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true

            let nwListener = try NWListener(using: params, on: port)

            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isListening = true
                    case .failed, .cancelled:
                        self.isListening = false
                        self.listener?.cancel()
                        self.listener = nil
                        // Auto-reconexão automática após queda de socket em 2º plano
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            self?.startListening()
                        }
                    default:
                        break
                    }
                }
            }

            nwListener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.listenerQueue ?? .global(qos: .userInteractive))
                self?.receiveLoop(on: connection)
            }

            nwListener.start(queue: listenerQueue)
            self.listener = nwListener
            self.isListening = true
        } catch {
            self.isListening = false
            self.listener = nil
        }
    }

    public func stopListening() {
        listener?.cancel()
        listener = nil
        isListening = false
    }

    private func setupScreenCaptureObserver() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateScreenCaptureStatus()
            }
        }

        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isListening || self.listener == nil {
                    self.startListening()
                }
            }
        }

        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isListening || self.listener == nil {
                    self.startListening()
                }
                self.updateScreenCaptureStatus()
            }
        }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.isListening || self.listener == nil {
                    self.startListening()
                }
                self.updateScreenCaptureStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenCheckTimer = timer
    }

    private func updateScreenCaptureStatus() {
        let isCaptured = UIScreen.main.isCaptured
        let recentUDPHeartbeat = lastPacketTime.map { Date().timeIntervalSince($0) < 4.5 } ?? false
        broadcastActive = isCaptured || recentUDPHeartbeat
    }

    nonisolated private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.handleIncomingData(data)
            }
            if error == nil {
                self?.receiveLoop(on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    nonisolated private func handleIncomingData(_ data: Data) {
        if let offer = try? JSONDecoder().decode(RideOfferPayload.self, from: data) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastPacketTime = Date()
                self.broadcastActive = true
                self.onHeartbeatReceived?()
                self.onOfferReceived?(offer)
            }
            return
        }

        if let statusDict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let status = statusDict["status"] {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onHeartbeatReceived?()
                if status == "BROADCAST_FINISHED" {
                    self.lastPacketTime = nil
                    self.broadcastActive = UIScreen.main.isCaptured
                    self.onClearCardRequested?()
                } else if status == "CLEAR_CARD" {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                    self.onClearCardRequested?()
                } else if status == "RIDE_ACCEPTED" {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                    self.onRideAcceptedDetected?()
                    self.onClearCardRequested?()
                } else if status == "RIDE_DECLINED" {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                    self.onRideOutcome?("DECLINED", "")
                    self.onClearCardRequested?()
                } else if status == "RIDE_UNKNOWN" {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                    self.onRideOutcome?("UNKNOWN", "")
                } else if status == "SCREEN_SNAPSHOT" {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                    self.onRideOutcome?("SNAPSHOT", statusDict["text"] ?? "")
                } else {
                    self.lastPacketTime = Date()
                    self.broadcastActive = true
                }
            }
        }
    }
}
