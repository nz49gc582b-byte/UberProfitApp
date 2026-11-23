import Foundation
import SwiftUI
import AVKit
import Combine

public enum AppSectionTab: String, CaseIterable, Sendable, Hashable {
    case operation = "Painel"
    case earnings = "Ganhos"
    case history = "Histórico"
    case settings = "Ajustes"

    public var icon: String {
        switch self {
        case .operation: return "bolt.car.fill"
        case .earnings: return "dollarsign.circle.fill"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape.fill"
        }
    }
}

@MainActor
public final class ContentViewModel: ObservableObject {
    // Services
    public let keepAlive = BackgroundKeepAlive()
    @Published public var udpListener = UDPListenerManager()
    public let voiceManager = VoiceAlertManager()
    public let pipManager = PiPOverlayManager()
    public let notificationManager = NotificationAlertManager()
    @Published public var config = AppConfiguration()
    public let persistence = RidePersistenceService()
    public let logStore = ConsoleLogStore()

    // State
    @Published public var selectedTab: AppSectionTab = .operation
    @Published public var latestAnalysis: RideAnalysis?
    @Published public var lastSeenAnalysis: RideAnalysis?
    @Published public var history: [RideAnalysis] = []
    @Published public var acceptedRides: [RideAnalysis] = []
    @Published public var archivedTurns: [ArchivedTurn] = []
    @Published public var selectedRideDetail: RideAnalysis?

    // Modal para adicionar corrida manual na aba Ganhos
    @Published public var showAddManualRideSheet: Bool = false
    @Published public var manualRideApp: String = "UBER"
    @Published public var manualRideFareText: String = ""
    @Published public var manualRideKmText: String = ""
    @Published public var manualRideMinText: String = ""

    private var cancellables = Set<AnyCancellable>()
    private var didStartServices = false
    private let maxHistoryItems = 300
    private var lastAnnouncedSignature: String = ""
    private var lastAnnouncedTime: TimeInterval = 0

    public init() {
        self.history = persistence.loadHistory()
        self.acceptedRides = persistence.loadAcceptedRides()
        self.archivedTurns = persistence.loadArchivedTurns()
        self.lastSeenAnalysis = self.history.first

        udpListener.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)

        keepAlive.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)

        pipManager.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)

        checkAndResetDailyTurn()
    }

    private func checkAndResetDailyTurn() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        if config.currentTurnDate.isEmpty {
            config.currentTurnDate = today
            return
        }

        if config.currentTurnDate != today {
            // Novo dia: arquiva o que sobrou do turno anterior
            if !acceptedRides.isEmpty {
                finishTurn(reason: "Novo dia")
            } else {
                config.extraDailyExpenseBRL = 0.0
            }
            config.currentTurnDate = today
        }
    }

    public var currentSettings: DriverSettings {
        DriverSettings(
            targetBRLPerKm: config.targetBRLPerKm,
            targetBRLPerHour: config.targetBRLPerHour,
            enableMinFareFilter: config.enableMinFareFilter,
            minFareBRL: config.minFareBRL,
            maxPickupDistanceKm: config.maxPickupDistanceKm,
            carConsumptionKmPerLiter: config.carConsumptionKmPerLiter,
            fuelPriceBRLPerLiter: config.fuelPriceBRLPerLiter,
            voiceAlertsEnabled: config.voiceAlertsEnabled,
            evaluateUsingNetProfit: config.evaluateUsingNetProfit,
            voiceSpeechStyle: config.voiceSpeechStyle,
            voiceSpeechRate: config.voiceSpeechRate,
            primaryMetricDisplay: config.primaryMetricDisplay
        )
    }

    // MARK: - Métricas derivadas

    /// Métricas do turno em andamento.
    public var currentShiftMetrics: ShiftMetrics {
        ShiftMetrics(rides: acceptedRides, extraExpenseBRL: config.extraDailyExpenseBRL)
    }

    /// Ofertas lidas hoje (o histórico guarda vários dias).
    public var todayOffers: [RideAnalysis] {
        history.filter { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.offer.timestamp)) }
    }

    // MARK: - Serviços em segundo plano

    public func startBackgroundServices() {
        guard !didStartServices else { return }
        didStartServices = true

        keepAlive.start()
        notificationManager.requestAuthorizationIfNeeded()
        pipManager.setAutoStartEnabled(config.visualAlertMode != .notificationOnly)

        voiceManager.onSpeechFinished = { [weak self] in
            Task { @MainActor in
                self?.keepAlive.ensureEnginePlaying()
            }
        }

        notificationManager.onAcceptRideFromNotification = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if let candidate = self.latestAnalysis ?? self.lastSeenAnalysis {
                    self.acceptRide(candidate, source: "notificação")
                }
            }
        }

        udpListener.onHeartbeatReceived = { [weak self] in
            Task { @MainActor in
                self?.keepAlive.ensureEnginePlaying()
            }
        }

        udpListener.onOfferReceived = { [weak self] offer in
            Task { @MainActor in
                self?.processIncomingOffer(offer, recordInHistory: true)
            }
        }

        udpListener.onClearCardRequested = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.latestAnalysis = nil
                self.pipManager.updateCard(with: nil, displayMode: self.config.primaryMetricDisplay)
            }
        }

        udpListener.onRideAcceptedDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.addLog("RIDE_ACCEPTED recebido da extensão.", kind: .accepted)
                if self.config.autoDetectAcceptedRides, let candidate = self.latestAnalysis ?? self.lastSeenAnalysis {
                    self.acceptRide(candidate, source: "automático")
                } else if !self.config.autoDetectAcceptedRides {
                    self.addLog("Registro automático desligado nos Ajustes: corrida não registrada.", kind: .unknown)
                } else {
                    self.addLog("Aceite detectado, mas nenhuma oferta recente foi encontrada.", kind: .error)
                }
            }
        }

        udpListener.onRideOutcome = { [weak self] kind, text in
            Task { @MainActor in
                guard let self = self else { return }
                switch kind {
                case "SNAPSHOT":
                    self.addLog(text, kind: .snapshot)
                case "DECLINED":
                    self.addLog("Oferta recusada/expirada (tela ociosa). Não registrada.", kind: .declined)
                case "UNKNOWN":
                    // Sem confirmação de aceite: não registra (evita falso positivo ao trocar de app)
                    self.addLog("Desfecho incerto: oferta não registrada (use + em Ganhos se você aceitou).", kind: .unknown)
                default:
                    break
                }
            }
        }

        udpListener.startListening()
        addLog("App iniciado. Serviços em segundo plano ativos.", kind: .system)
    }

    public func addLog(_ message: String, kind: LogEntry.Kind = .system) {
        logStore.add(message, kind: kind)
    }

    // MARK: - Ofertas

    public func processIncomingOffer(_ offer: RideOfferPayload, recordInHistory: Bool = true) {
        let settings = currentSettings
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: settings)
        self.latestAnalysis = analysis
        self.lastSeenAnalysis = analysis

        // Atualiza sempre o PiP em tempo real (com flush + invalidatePlaybackState)
        self.pipManager.updateCard(with: analysis, displayMode: self.config.primaryMetricDisplay)

        let sig = "\(offer.appSource)-\(Int((offer.fareBRL * 100).rounded()))-\(Int((offer.totalDistanceKm * 10).rounded()))-\(offer.totalMinutes)"
        let isRepeatedSameCard = recordInHistory && (sig == lastAnnouncedSignature) && ((offer.timestamp - lastAnnouncedTime) < 18.0)

        guard !isRepeatedSameCard else { return }

        if recordInHistory {
            lastAnnouncedSignature = sig
            lastAnnouncedTime = offer.timestamp
        }

        let origin = recordInHistory ? "" : " (simulação)"
        addLog(
            "Oferta\(origin) [\(offer.appSource)] \(Fmt.brl(offer.fareBRL)) · \(Fmt.km(offer.totalDistanceKm)) · \(offer.totalMinutes) min → \(analysis.verdict.rawValue) (\(Fmt.perKm(analysis.grossPerKm)))",
            kind: .offer
        )

        if recordInHistory {
            self.history.insert(analysis, at: 0)
            if self.history.count > maxHistoryItems {
                self.history.removeLast(self.history.count - maxHistoryItems)
            }
            self.persistence.saveHistory(self.history)
        }

        // Dispara sempre o banner de notificação no topo (mesmo com PiP ativo)
        self.notificationManager.sendRideBanner(analysis: analysis, displayMode: self.config.primaryMetricDisplay)

        if self.config.voiceAlertsEnabled {
            self.voiceManager.announce(analysis: analysis, settings: settings)
        }
    }

    public func deleteOffers(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        history.removeAll { ids.contains($0.id) }
        persistence.saveHistory(history)
    }

    public func clearTodayOffers() {
        history.removeAll { Calendar.current.isDateInToday(Date(timeIntervalSince1970: $0.offer.timestamp)) }
        persistence.saveHistory(history)
    }

    public func clearHistory() {
        history.removeAll()
        persistence.saveHistory(history)
    }

    // MARK: - Turno atual (Ganhos)

    @discardableResult
    public func acceptRide(_ ride: RideAnalysis, source: String = "manual") -> Bool {
        guard !acceptedRides.contains(where: { $0.id == ride.id }) else { return false }
        acceptedRides.append(ride)
        persistence.saveAcceptedRides(acceptedRides)
        addLog(
            "Corrida registrada (\(source)): [\(ride.offer.appSource)] \(Fmt.brl(ride.offer.fareBRL)) · lucro \(Fmt.brl(ride.netProfitBRL))",
            kind: .accepted
        )
        return true
    }

    public func removeAcceptedRide(_ ride: RideAnalysis) {
        acceptedRides.removeAll(where: { $0.id == ride.id })
        persistence.saveAcceptedRides(acceptedRides)
        addLog("Corrida removida dos ganhos: [\(ride.offer.appSource)] \(Fmt.brl(ride.offer.fareBRL))", kind: .system)
    }

    public func isRideAlreadyAccepted(_ ride: RideAnalysis) -> Bool {
        acceptedRides.contains(where: { $0.id == ride.id })
    }

    public func finishTurn(reason: String = "Manual") {
        guard !acceptedRides.isEmpty else {
            config.extraDailyExpenseBRL = 0.0
            return
        }
        let metrics = currentShiftMetrics
        persistence.archiveTurn(acceptedRides, extraExpenseBRL: config.extraDailyExpenseBRL)
        archivedTurns = persistence.loadArchivedTurns()
        addLog("Turno encerrado (\(reason)): \(metrics.rideCount) corridas · lucro \(Fmt.brl(metrics.netBRL))", kind: .system)
        acceptedRides.removeAll()
        config.extraDailyExpenseBRL = 0.0
        persistence.saveAcceptedRides(acceptedRides)
    }

    /// Descarta o turno atual sem salvar no extrato.
    public func clearTurn() {
        acceptedRides.removeAll()
        config.extraDailyExpenseBRL = 0.0
        persistence.saveAcceptedRides(acceptedRides)
        addLog("Turno atual descartado sem arquivar.", kind: .system)
    }

    // MARK: - Extratos

    public func deleteArchivedTurn(_ id: UUID) {
        archivedTurns.removeAll { $0.id == id }
        persistence.saveArchivedTurns(archivedTurns)
    }

    public func removeRideFromArchivedTurn(rideID: String, turnID: UUID) {
        guard let index = archivedTurns.firstIndex(where: { $0.id == turnID }) else { return }
        archivedTurns[index].rides.removeAll { $0.id == rideID }
        if archivedTurns[index].rides.isEmpty {
            archivedTurns.remove(at: index)
        }
        persistence.saveArchivedTurns(archivedTurns)
    }

    public func clearArchivedTurns() {
        persistence.clearArchivedTurns()
        archivedTurns = []
    }

    // MARK: - Corrida manual

    public func saveManualRide() {
        let fare = Fmt.parseDecimal(manualRideFareText) ?? 0.0
        let km = Fmt.parseDecimal(manualRideKmText) ?? 0.0
        let mins = Int(manualRideMinText.trimmingCharacters(in: .whitespaces)) ?? 10

        guard fare > 0, km > 0 else { return }

        let offer = RideOfferPayload(
            appSource: manualRideApp,
            fareBRL: fare,
            pickupDistanceKm: 0.0,
            tripDistanceKm: km,
            totalDistanceKm: km,
            pickupMinutes: 0,
            tripMinutes: max(mins, 1),
            totalMinutes: max(mins, 1),
            rawRecognizedText: "Corrida lançada manualmente pelo motorista.",
            timestamp: Date().timeIntervalSince1970
        )
        let analysis = ProfitCalculator.evaluate(offer: offer, settings: currentSettings)
        acceptRide(analysis, source: "lançamento manual")

        manualRideFareText = ""
        manualRideKmText = ""
        manualRideMinText = ""
        showAddManualRideSheet = false
    }

    public var canSaveManualRide: Bool {
        (Fmt.parseDecimal(manualRideFareText) ?? 0) > 0 && (Fmt.parseDecimal(manualRideKmText) ?? 0) > 0
    }

    // MARK: - Simulação (não entra no histórico)

    public func simulateRideOffer(appSource: String, fare: Double, pickupKm: Double, tripKm: Double, pickupMin: Int, tripMin: Int, rawText: String) {
        let mock = RideOfferPayload(
            appSource: appSource,
            fareBRL: fare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: pickupKm + tripKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: pickupMin + tripMin,
            rawRecognizedText: rawText,
            timestamp: Date().timeIntervalSince1970
        )
        processIncomingOffer(mock, recordInHistory: false)
    }

    // MARK: - Compatibilidade de formatação

    public func formatBRL(_ value: Double) -> String { Fmt.brl(value) }
    public func formatDuration(minutes: Int) -> String { Fmt.duration(minutes: minutes) }
    public func formatTime(_ timestamp: TimeInterval) -> String { Fmt.time(timestamp: timestamp) }

    public func color(for verdict: RideVerdict) -> Color { Theme.color(for: verdict) }
}
