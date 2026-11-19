import SwiftUI
import UIKit

// MARK: - AJUSTES (Metas, Carro, Filtros, Alertas, Simulação e Console)

public struct SettingsHomeView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration
    @ObservedObject private var logStore: ConsoleLogStore

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
        self._logStore = ObservedObject(wrappedValue: viewModel.logStore)
    }

    public var body: some View {
        List {
            // 1. Console & Diagnóstico em destaque no topo para fácil acesso
            Section {
                NavigationLink {
                    ConsoleLogView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Console de Diagnóstico")
                                .font(.subheadline.weight(.semibold))
                            Text("\(logStore.entries.count) registros salvos · copiar ou compartilhar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Diagnóstico")
            } footer: {
                Text("Os registros ficam salvos no aparelho mesmo fechando o app e podem ser copiados com 1 toque.")
            }

            // 2. Metas Principais
            Section {
                SliderRow(
                    title: "Meta mínima por km",
                    valueText: Fmt.perKm(config.targetBRLPerKm),
                    value: $config.targetBRLPerKm,
                    range: 1.00...5.00,
                    step: 0.05,
                    tint: Theme.good
                )

                SliderRow(
                    title: "Meta mínima por hora",
                    valueText: Fmt.perHour(config.targetBRLPerHour),
                    value: $config.targetBRLPerHour,
                    range: 20.0...120.0,
                    step: 2.0,
                    tint: Theme.good
                )

                SliderRow(
                    title: "Meta diária de lucro livre",
                    valueText: Fmt.brl(config.dailyNetGoalBRL),
                    value: $config.dailyNetGoalBRL,
                    range: 50.0...800.0,
                    step: 10.0,
                    tint: Theme.accent
                )

                Toggle("Avaliar metas pelo lucro líquido", isOn: $config.evaluateUsingNetProfit)
            } header: {
                Text("Metas de Lucratividade")
            } footer: {
                let requiredGross = config.targetBRLPerKm + config.fuelCostPerKm
                let netLeftover = max(config.targetBRLPerKm - config.fuelCostPerKm, 0)
                if config.evaluateUsingNetProfit {
                    Text("Modo rigoroso: descontando \(Fmt.perKm(config.fuelCostPerKm)) de combustível, a corrida precisa pagar pelo menos \(Fmt.perKm(requiredGross)) bruto para ficar verde.")
                } else {
                    Text("Modo padrão: fica verde a partir de \(Fmt.perKm(config.targetBRLPerKm)) bruto (sobram \(Fmt.perKm(netLeftover)) livres por km).")
                }
            }

            // 3. Filtros de Oferta
            Section {
                Toggle("Exigir valor mínimo da corrida", isOn: $config.enableMinFareFilter)

                if config.enableMinFareFilter {
                    SliderRow(
                        title: "Tarifa mínima da corrida",
                        valueText: Fmt.brl(config.minFareBRL),
                        value: $config.minFareBRL,
                        range: 4.0...30.0,
                        step: 0.50,
                        tint: .blue
                    )
                }

                SliderRow(
                    title: "Distância máxima p/ buscar",
                    valueText: Fmt.km(config.maxPickupDistanceKm),
                    value: $config.maxPickupDistanceKm,
                    range: 0.5...10.0,
                    step: 0.5,
                    tint: .blue
                )
            } header: {
                Text("Filtros de Oferta")
            } footer: {
                if config.enableMinFareFilter {
                    Text("Com o filtro ligado, corridas abaixo de \(Fmt.brl(config.minFareBRL)) recebem alerta de recusa mesmo se pagarem bem por km.")
                } else {
                    Text("Filtro de valor mínimo desligado: qualquer corrida rápida que pague bem por km e por hora (mesmo de R$ 6 a R$ 8) receberá sinal VERDE.")
                }
            }

            // 4. Veículo e Combustível
            Section {
                HStack {
                    Text("Custo estimado por km")
                    Spacer()
                    Text(Fmt.perKm(config.fuelCostPerKm))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.caution)
                }

                SliderRow(
                    title: "Consumo do veículo",
                    valueText: String(format: "%.1f km/L", config.carConsumptionKmPerLiter).replacingOccurrences(of: ".", with: ","),
                    value: $config.carConsumptionKmPerLiter,
                    range: 5.0...22.0,
                    step: 0.5,
                    tint: .blue
                )

                SliderRow(
                    title: "Preço do combustível",
                    valueText: "\(Fmt.brl(config.fuelPriceBRLPerLiter))/L",
                    value: $config.fuelPriceBRLPerLiter,
                    range: 3.00...9.00,
                    step: 0.05,
                    tint: Theme.caution
                )
            } header: {
                Text("Veículo e Combustível")
            }

            // 5. Automação
            Section {
                Toggle("Registrar corrida aceita automaticamente", isOn: $config.autoDetectAcceptedRides)
            } header: {
                Text("Registro de Corridas")
            } footer: {
                Text("Salva a corrida em Ganhos somente quando a tela da Uber ou da 99 confirma o início do deslocamento até o passageiro.")
            }

            // 6. Alertas Visuais e Voz
            Section {
                Picker("Modo de exibição", selection: $config.visualAlertModeRaw) {
                    ForEach(VisualAlertMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .onChange(of: config.visualAlertModeRaw) { newValue in
                    let isNotificationOnly = (newValue == VisualAlertMode.notificationOnly.rawValue)
                    viewModel.pipManager.setAutoStartEnabled(!isNotificationOnly)
                    if isNotificationOnly {
                        viewModel.notificationManager.requestAuthorizationIfNeeded()
                    }
                }

                Picker("Valor em destaque", selection: $config.primaryMetricDisplayRaw) {
                    ForEach(PrimaryMetricDisplay.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .onChange(of: config.primaryMetricDisplayRaw) { _ in
                    if let latest = viewModel.latestAnalysis {
                        viewModel.pipManager.updateCard(with: latest, displayMode: config.primaryMetricDisplay)
                    }
                }

                Toggle("Alerta de voz automático", isOn: $config.voiceAlertsEnabled)

                if config.voiceAlertsEnabled {
                    Picker("Estilo da fala", selection: $config.voiceSpeechStyleRaw) {
                        ForEach(VoiceSpeechStyle.allCases, id: \.rawValue) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }

                    SliderRow(
                        title: "Velocidade da voz",
                        valueText: config.voiceSpeechRate < 0.50 ? "Pausada" : (config.voiceSpeechRate > 0.58 ? "Rápida" : "Normal"),
                        value: $config.voiceSpeechRate,
                        range: 0.44...0.64,
                        step: 0.02,
                        tint: Theme.accent
                    )
                }
            } header: {
                Text("Alertas e Voz")
            }

            // 7. Testes Rápidos
            Section {
                Button {
                    viewModel.simulateRideOffer(
                        appSource: "UBER",
                        fare: 22.80,
                        pickupKm: 0.8,
                        tripKm: 7.2,
                        pickupMin: 3,
                        tripMin: 15,
                        rawText: "UberX Exclusivo\nR$ 22,80\n18 min • 8.0 km • Est. de R$2,85/km\n3 min (0.8 km)\n15 minutos (7.2 km)\nAceitar"
                    )
                } label: {
                    Label("Simular oferta boa (Uber)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.good)
                }

                Button {
                    viewModel.simulateRideOffer(
                        appSource: "99",
                        fare: 10.32,
                        pickupKm: 1.4,
                        tripKm: 6.6,
                        pickupMin: 5,
                        tripMin: 18,
                        rawText: "99Pop\nR$ 10,32\n5 min (1.4 km)\n18 min (6.6 km)\nAceitar"
                    )
                } label: {
                    Label("Simular oferta ruim (99)", systemImage: "xmark.circle.fill")
                        .foregroundStyle(Theme.bad)
                }

                if !config.showQuickGuide {
                    Button {
                        config.showQuickGuide = true
                        viewModel.selectedTab = .operation
                    } label: {
                        Label("Mostrar guia rápido no Painel", systemImage: "questionmark.circle")
                    }
                }
            } header: {
                Text("Testes")
            } footer: {
                Text("As simulações servem para testar voz, banner e PiP e nunca entram no histórico nem nos ganhos.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - CONSOLE DE DIAGNÓSTICO (Persistente + Copiar + Compartilhar + Filtros)

public struct ConsoleLogView: View {
    public enum Filter: String, CaseIterable, Identifiable {
        case all = "Todos"
        case snapshots = "Telas 📸"
        case accepted = "Aceitas"
        case offers = "Ofertas"
        case system = "Sistema"

        public var id: String { rawValue }
    }

    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var logStore: ConsoleLogStore

    @State private var filter: Filter = .all
    @State private var searchText: String = ""
    @State private var copiedBanner: String? = nil
    @State private var showClearConfirm: Bool = false

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._logStore = ObservedObject(wrappedValue: viewModel.logStore)
    }

    private var filteredEntries: [LogEntry] {
        logStore.entries.filter { entry in
            let matchesFilter: Bool = {
                switch filter {
                case .all: return true
                case .snapshots: return entry.kind == .snapshot
                case .accepted: return entry.kind == .accepted || entry.kind == .declined || entry.kind == .unknown
                case .offers: return entry.kind == .offer
                case .system: return entry.kind == .system || entry.kind == .error
                }
            }()
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        let entries = filteredEntries
        let exported = logStore.exportText(entries)

        VStack(spacing: 0) {
            // Barra de ações rápidas (Copiar tudo + Compartilhar + Filtros)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.string = exported
                        showCopiedFeedback("Copiado (\(entries.count) linhas)")
                    } label: {
                        Label(copiedBanner ?? "Copiar tudo (\(entries.count))", systemImage: copiedBanner != nil ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(copiedBanner != nil ? Theme.good : Theme.accent)
                    .disabled(entries.isEmpty)

                    if !entries.isEmpty {
                        ShareLink(item: exported) {
                            Label("Enviar", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 14)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { item in
                            let isSelected = filter == item
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { filter = item }
                            } label: {
                                Text(item.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? Theme.accent : Theme.card)
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.background)

            Divider()

            if entries.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "terminal",
                    title: "Nenhum registro neste filtro",
                    message: "Os eventos do leitor de tela, ofertas e textos pós-oferta ficam gravados aqui e não se perdem ao fechar o app."
                )
                Spacer()
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            LogEntryRow(entry: entry) {
                                let line = "\(Fmt.time(entry.date)) [\(entry.kind.rawValue)] \(entry.message)"
                                UIPasteboard.general.string = line
                                showCopiedFeedback("Linha copiada!")
                            }
                        }
                    } header: {
                        Text("Toque em uma linha para copiar · segure para selecionar texto")
                            .textCase(nil)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Theme.background)
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Buscar texto no log...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logStore.entries.isEmpty)
            }
        }
        .confirmationDialog("Limpar todos os registros do Console?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Limpar Console", role: .destructive) {
                logStore.clear()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Recomendado copiar ou enviar os logs antes de limpar.")
        }
    }

    private func showCopiedFeedback(_ text: String) {
        withAnimation { copiedBanner = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation {
                if copiedBanner == text { copiedBanner = nil }
            }
        }
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry
    let onTapCopy: () -> Void

    var body: some View {
        Button(action: onTapCopy) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(badgeLabel)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.16))
                        .foregroundStyle(badgeColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Text( timestampString(entry.date) )
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(entry.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onTapCopy()
            } label: {
                Label("Copiar esta linha", systemImage: "doc.on.doc")
            }
        }
    }

    private var badgeLabel: String {
        switch entry.kind {
        case .system: return "SISTEMA"
        case .offer: return "OFERTA"
        case .accepted: return "ACEITA"
        case .declined: return "RECUSADA"
        case .unknown: return "INCERTA"
        case .snapshot: return "TELA 📸"
        case .error: return "ERRO"
        }
    }

    private var badgeColor: Color {
        switch entry.kind {
        case .system: return .secondary
        case .offer: return .blue
        case .accepted: return Theme.good
        case .declined: return Theme.bad
        case .unknown: return Theme.caution
        case .snapshot: return .purple
        case .error: return Theme.bad
        }
    }

    private func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM HH:mm:ss"
        return f.string(from: date)
    }
}
