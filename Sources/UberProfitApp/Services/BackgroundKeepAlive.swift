import Foundation
import AVFoundation
import UIKit

/// Mantém o aplicativo principal vivo 100% do tempo em segundo plano usando:
/// 1. `AVAudioSession` `.playback` com `.mixWithOthers`
/// 2. `AVAudioPlayer` com buffer WAV PCM 16-bit de baixíssima amplitude não-zero (evita o detector de silêncio digital `0.0` do iOS)
/// 3. `AVAudioEngine` secundário + `UIBackgroundTaskIdentifier` e watchdog em `RunLoop.main` (`.common`)
@MainActor
public final class BackgroundKeepAlive: ObservableObject {
    @Published public private(set) var isRunning: Bool = false

    private var audioPlayer: AVAudioPlayer?
    private var watchdogTimer: Timer?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var wavData: Data?

    public init() {
        self.wavData = Self.makeSubAudibleWAVData()
        setupNotifications()
    }

    public func start() {
        ensureEnginePlaying()
        startWatchdog()
    }

    public func ensureEnginePlaying() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])

            if audioPlayer == nil, let data = wavData {
                let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                player.numberOfLoops = -1
                player.volume = 0.01
                player.prepareToPlay()
                self.audioPlayer = player
            }

            if let player = audioPlayer {
                if !player.isPlaying {
                    player.play()
                }
                isRunning = player.isPlaying
            } else {
                isRunning = false
            }
        } catch {
            isRunning = false
        }
    }

    public func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        audioPlayer?.stop()
        endBackgroundTaskIfNeeded()
        isRunning = false
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.audioPlayer?.isPlaying != true {
                    self.ensureEnginePlaying()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func beginBackgroundTask() {
        endBackgroundTaskIfNeeded()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "UberProfitKeepAlive") { [weak self] in
            Task { @MainActor in
                self?.ensureEnginePlaying()
                self?.endBackgroundTaskIfNeeded()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func setupNotifications() {
        let nc = NotificationCenter.default

        nc.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureEnginePlaying()
            }
        }

        nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureEnginePlaying()
            }
        }

        nc.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.audioPlayer = nil
                self?.ensureEnginePlaying()
            }
        }

        nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.beginBackgroundTask()
                self?.ensureEnginePlaying()
            }
        }

        nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundTaskIfNeeded()
                self?.ensureEnginePlaying()
            }
        }
    }

    /// Gera um arquivo WAV PCM 16-bit mono (22.050 Hz, 2 segundos) com sinal sub-audível não-zero (±2 de 32767).
    /// Isso impede que o daemon de áudio do iOS (`mediaserverd`) detecte "silêncio digital 0.0" e suspenda o app em 2º plano.
    private static func makeSubAudibleWAVData() -> Data {
        let sampleRate: UInt32 = 22050
        let numSamples: UInt32 = sampleRate * 2
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let dataSize: UInt32 = numSamples * UInt32(blockAlign)
        let chunkSize: UInt32 = 36 + dataSize

        var data = Data(capacity: Int(44 + dataSize))
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: UInt32 = 16
        let audioFormat: UInt16 = 1 // PCM
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))

        for i in 0..<numSamples {
            let sample: Int16 = (i % 2 == 0) ? 2 : -2
            let le = sample.littleEndian
            withUnsafeBytes(of: le) { data.append(contentsOf: $0) }
        }
        return data
    }
}
