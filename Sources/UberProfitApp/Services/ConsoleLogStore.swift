import Foundation
import SwiftUI

/// Um registro do console de diagnóstico.
public struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case system     // início de serviços, avisos gerais
        case offer      // oferta lida da tela
        case accepted   // corrida registrada
        case declined   // oferta recusada/expirada
        case unknown    // desfecho incerto
        case snapshot   // texto da tela depois da oferta (diagnóstico)
        case error
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let message: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
    }
}

/// Armazena o console em arquivo no aparelho: sobrevive a reinícios do app e nunca perde eventos
/// importantes por causa do volume de "snapshots" de tela (que têm limite próprio).
@MainActor
public final class ConsoleLogStore: ObservableObject {
    /// Mais recentes primeiro.
    @Published public private(set) var entries: [LogEntry] = []

    private let maxEntries = 1500
    private let maxSnapshots = 300
    private var lastSnapshotText: String?
    private var pendingSave = false
    private let fileURL: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("console_log.json")
        load()
    }

    // MARK: - API

    public func add(_ message: String, kind: LogEntry.Kind = .system) {
        if kind == .snapshot {
            // Não repete o mesmo texto de tela em sequência
            guard message != lastSnapshotText else { return }
            lastSnapshotText = message
        }

        entries.insert(LogEntry(kind: kind, message: message), at: 0)

        if kind == .snapshot {
            trimSnapshots()
        }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
    }

    public func clear() {
        entries.removeAll()
        lastSnapshotText = nil
        scheduleSave()
    }

    /// Texto em ordem cronológica (mais antigo primeiro), pronto para colar em qualquer lugar.
    public func exportText(_ items: [LogEntry]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM HH:mm:ss"
        return items.reversed().map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.kind.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }

    // MARK: - Persistência

    private func trimSnapshots() {
        var count = 0
        var removeIndexes: [Int] = []
        for (index, entry) in entries.enumerated() where entry.kind == .snapshot {
            count += 1
            if count > maxSnapshots { removeIndexes.append(index) }
        }
        for index in removeIndexes.reversed() {
            entries.remove(at: index)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LogEntry].self, from: data) else { return }
        entries = decoded
    }

    private func scheduleSave() {
        guard !pendingSave else { return }
        pendingSave = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.flush()
        }
    }

    private func flush() {
        pendingSave = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }
}
