import Foundation

/// Extrato de um turno encerrado. Compatível com o formato antigo (V1) salvo no aparelho.
public struct ArchivedTurn: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    /// Data de fechamento do turno (usada só como reserva quando não há corridas).
    public var date: Date
    public var rides: [RideAnalysis]
    public var extraExpenseBRL: Double

    enum CodingKeys: String, CodingKey {
        case id, date, rides, extraExpenseBRL
        case totalNetProfit // legado: mantido para leitura/escrita retrocompatível
    }

    public init(id: UUID = UUID(), date: Date = Date(), rides: [RideAnalysis], extraExpenseBRL: Double = 0) {
        self.id = id
        self.date = date
        self.rides = rides
        self.extraExpenseBRL = extraExpenseBRL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.date = try container.decode(Date.self, forKey: .date)
        self.rides = try container.decode([RideAnalysis].self, forKey: .rides)
        self.extraExpenseBRL = try container.decodeIfPresent(Double.self, forKey: .extraExpenseBRL) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(rides, forKey: .rides)
        try container.encode(extraExpenseBRL, forKey: .extraExpenseBRL)
        try container.encode(metrics.netBRL, forKey: .totalNetProfit)
    }

    public var metrics: ShiftMetrics {
        ShiftMetrics(rides: rides, extraExpenseBRL: extraExpenseBRL)
    }

    /// Lucro livre do turno (já descontando combustível e gastos extras).
    public var totalNetProfit: Double { metrics.netBRL }

    private var rideDates: [Date] {
        rides.map { Date(timeIntervalSince1970: $0.offer.timestamp) }
    }

    /// Horário da primeira corrida do turno (data real em que o turno aconteceu).
    public var startedAt: Date { rideDates.min() ?? date }

    /// Horário da última corrida do turno.
    public var endedAt: Date { rideDates.max() ?? date }
}

public final class RidePersistenceService {
    private let savedAcceptedKey = "UberProfit_AcceptedRides_V7"
    private let savedHistoryKey = "UberProfit_OfferHistory_V7"
    private let savedTurnsKey = "UberProfit_TurnHistory_V1"

    public init() {}

    // MARK: - Corridas aceitas (turno atual)

    public func loadAcceptedRides() -> [RideAnalysis] {
        guard let data = UserDefaults.standard.data(forKey: savedAcceptedKey),
              let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) else { return [] }
        return decoded
    }

    public func saveAcceptedRides(_ rides: [RideAnalysis]) {
        if let encoded = try? JSONEncoder().encode(rides) {
            UserDefaults.standard.set(encoded, forKey: savedAcceptedKey)
        }
    }

    // MARK: - Histórico de ofertas lidas

    public func loadHistory() -> [RideAnalysis] {
        guard let data = UserDefaults.standard.data(forKey: savedHistoryKey),
              let decoded = try? JSONDecoder().decode([RideAnalysis].self, from: data) else { return [] }
        return decoded
    }

    public func saveHistory(_ history: [RideAnalysis]) {
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: savedHistoryKey)
        }
    }

    // MARK: - Extratos de turnos encerrados

    public func archiveTurn(_ rides: [RideAnalysis], extraExpenseBRL: Double) {
        guard !rides.isEmpty else { return }
        var turns = loadArchivedTurns()
        turns.insert(ArchivedTurn(rides: rides, extraExpenseBRL: extraExpenseBRL), at: 0)
        saveArchivedTurns(turns)
    }

    public func loadArchivedTurns() -> [ArchivedTurn] {
        guard let data = UserDefaults.standard.data(forKey: savedTurnsKey),
              let decoded = try? JSONDecoder().decode([ArchivedTurn].self, from: data) else { return [] }
        return decoded
    }

    public func saveArchivedTurns(_ turns: [ArchivedTurn]) {
        if let encoded = try? JSONEncoder().encode(turns) {
            UserDefaults.standard.set(encoded, forKey: savedTurnsKey)
        }
    }

    public func clearArchivedTurns() {
        UserDefaults.standard.removeObject(forKey: savedTurnsKey)
    }
}
