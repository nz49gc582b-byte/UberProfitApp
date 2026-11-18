import SwiftUI

// MARK: - Grade de métricas (compartilhada por Ganhos e Extratos)

public struct MetricsGridView: View {
    let metrics: ShiftMetrics

    public init(metrics: ShiftMetrics) { self.metrics = metrics }

    public var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            MetricTile(
                icon: "speedometer",
                title: "Por km",
                value: Fmt.perKm(metrics.grossPerKm),
                caption: "Líquido \(Fmt.perKm(metrics.netPerKm))",
                tint: Theme.accent
            )
            MetricTile(
                icon: "clock.fill",
                title: "Por hora",
                value: Fmt.perHour(metrics.grossPerHour),
                caption: "Líquido \(Fmt.perHour(metrics.netPerHour))",
                tint: Theme.caution
            )
            MetricTile(
                icon: "map.fill",
                title: "Distância",
                value: Fmt.km(metrics.totalKm),
                caption: "Busca \(Fmt.km(metrics.pickupKm))",
                tint: .blue
            )
            MetricTile(
                icon: "hourglass",
                title: "Tempo em corrida",
                value: Fmt.duration(minutes: metrics.totalMinutes),
                caption: "\(metrics.rideCount) corridas",
                tint: .purple
            )
            MetricTile(
                icon: "tag.fill",
                title: "Ticket médio",
                value: Fmt.brl(metrics.averageTicketBRL),
                caption: "por corrida",
                tint: .teal
            )
            MetricTile(
                icon: "square.stack.3d.up.fill",
                title: "Por aplicativo",
                value: "Uber \(metrics.uberCount) · 99 \(metrics.ninetyNineCount)",
                caption: metrics.otherCount > 0 ? "Outros \(metrics.otherCount)" : "corridas",
                tint: .indigo
            )
        }
    }
}

// MARK: - HISTÓRICO (Extratos | Ofertas)

public struct HistoryTabView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case turns = "Extratos"
        case offers = "Ofertas"
        var id: String { rawValue }
    }

    @ObservedObject var viewModel: ContentViewModel
    @State private var mode: Mode = .turns

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            switch mode {
            case .turns:
                TurnsListView(viewModel: viewModel)
            case .offers:
                OffersListView(viewModel: viewModel)
            }
        }
        .navigationTitle("Histórico")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Visualização", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
    }
}

// MARK: - Extratos (turnos encerrados)

struct TurnsListView: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var showClearDialog = false

    private var sortedTurns: [ArchivedTurn] {
        viewModel.archivedTurns.sorted { $0.startedAt > $1.startedAt }
    }

    private var months: [(key: Date, turns: [ArchivedTurn])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sortedTurns) { turn in
            calendar.date(from: calendar.dateComponents([.year, .month], from: turn.startedAt)) ?? turn.startedAt
        }
        return groups.keys.sorted(by: >).map { (key: $0, turns: groups[$0] ?? []) }
    }

    var body: some View {
        let turns = sortedTurns

        return List {
            if turns.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "calendar.badge.clock",
                        title: "Nenhum extrato ainda",
                        message: "Ao finalizar um turno (ou quando um novo dia começa), o resumo completo de corridas e lucros fica guardado aqui."
                    )
                    .plainListRow()
                }
            } else {
                Section {
                    overallCard(turns)
                        .plainListRow(top: 4, bottom: 4)
                }

                ForEach(months, id: \.key) { month in
                    Section {
                        ForEach(month.turns) { turn in
                            NavigationLink {
                                TurnDetailView(viewModel: viewModel, turnID: turn.id)
                            } label: {
                                TurnRow(turn: turn)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    viewModel.deleteArchivedTurn(turn.id)
                                } label: {
                                    Label("Excluir", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        monthHeader(month.key, turns: month.turns)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showClearDialog = true
                    } label: {
                        Label("Apagar todos os extratos", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(turns.isEmpty)
            }
        }
        .confirmationDialog("Apagar todos os extratos?", isPresented: $showClearDialog, titleVisibility: .visible) {
            Button("Apagar \(turns.count) extratos", role: .destructive) {
                viewModel.clearArchivedTurns()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Esta ação não pode ser desfeita. Para apagar só um extrato, deslize a linha dele para a esquerda.")
        }
    }

    private func overallCard(_ turns: [ArchivedTurn]) -> some View {
        let all = turns.flatMap { $0.rides }
        let extras = turns.reduce(0.0) { $0 + $1.extraExpenseBRL }
        let metrics = ShiftMetrics(rides: all, extraExpenseBRL: extras)
        let average = turns.isEmpty ? 0 : metrics.netBRL / Double(turns.count)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lucro acumulado")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(Fmt.brl(metrics.netBRL))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(metrics.netBRL >= 0 ? Theme.good : Theme.bad)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            HStack(spacing: 0) {
                summaryStat(value: "\(turns.count)", label: "turnos")
                summaryStat(value: "\(metrics.rideCount)", label: "corridas")
                summaryStat(value: Fmt.brlRounded(average), label: "média/turno")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func monthHeader(_ date: Date, turns: [ArchivedTurn]) -> some View {
        let net = turns.reduce(0.0) { $0 + $1.totalNetProfit }
        let rides = turns.reduce(0) { $0 + $1.rides.count }
        return HStack {
            Text(Fmt.month(date))
            Spacer()
            Text("\(Fmt.brl(net)) · \(rides) corridas")
                .monospacedDigit()
        }
        .textCase(nil)
    }
}

struct TurnRow: View {
    let turn: ArchivedTurn

    var body: some View {
        let metrics = turn.metrics
        return HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(Fmt.weekdayShort(turn.startedAt))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(Fmt.dayNumber(turn.startedAt))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 44, height: 46)
            .background(Theme.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("\(metrics.rideCount) corridas")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(Fmt.duration(minutes: metrics.totalMinutes)) · \(Fmt.km(metrics.totalKm))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.brl(metrics.netBRL))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(metrics.netBRL >= 0 ? Theme.good : Theme.bad)
                Text(Fmt.perHour(metrics.netPerHour))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detalhe de um extrato

struct TurnDetailView: View {
    @ObservedObject var viewModel: ContentViewModel
    let turnID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteDialog = false

    private var turn: ArchivedTurn? {
        viewModel.archivedTurns.first { $0.id == turnID }
    }

    var body: some View {
        Group {
            if let turn {
                content(turn)
            } else {
                Color.clear
            }
        }
        .onChange(of: viewModel.archivedTurns.count) { _ in
            if turn == nil { dismiss() }
        }
    }

    private func content(_ turn: ArchivedTurn) -> some View {
        let metrics = turn.metrics
        let rides = turn.rides.sorted { $0.offer.timestamp < $1.offer.timestamp }

        return List {
            Section {
                hero(turn, metrics: metrics)
                    .plainListRow(top: 4, bottom: 4)
            }

            Section {
                MetricsGridView(metrics: metrics)
                    .plainListRow(top: 4, bottom: 4)
            }

            Section("Por aplicativo") {
                appRow(source: "UBER", count: metrics.uberCount, gross: metrics.uberGrossBRL)
                appRow(source: "99", count: metrics.ninetyNineCount, gross: metrics.ninetyNineGrossBRL)
                if metrics.otherCount > 0 {
                    appRow(source: "EXTRA", count: metrics.otherCount, gross: metrics.grossBRL - metrics.uberGrossBRL - metrics.ninetyNineGrossBRL)
                }
            }

            Section {
                ForEach(rides) { ride in
                    Button {
                        viewModel.selectedRideDetail = ride
                    } label: {
                        AcceptedRideRow(ride: ride)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            viewModel.removeRideFromArchivedTurn(rideID: ride.id, turnID: turn.id)
                        } label: {
                            Label("Remover", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Corridas · \(rides.count)")
            } footer: {
                Text("Deslize uma corrida para a esquerda para removê-la deste extrato.")
            }

            Section {
                ShareLink(item: exportText(turn, rides: rides)) {
                    Label("Compartilhar extrato", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    showDeleteDialog = true
                } label: {
                    Label("Excluir extrato", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Fmt.shortDay(turn.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Excluir este extrato?", isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("Excluir extrato", role: .destructive) {
                viewModel.deleteArchivedTurn(turn.id)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As \(rides.count) corridas deste dia serão apagadas. Esta ação não pode ser desfeita.")
        }
    }

    private func hero(_ turn: ArchivedTurn, metrics: ShiftMetrics) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.longDay(turn.startedAt))
                    .font(.footnote.weight(.semibold))
                    .opacity(0.85)
                Text(Fmt.brl(metrics.netBRL))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("Lucro livre · \(Fmt.time(turn.startedAt)) às \(Fmt.time(turn.endedAt))")
                    .font(.caption)
                    .opacity(0.85)
            }

            Divider()
                .overlay(Color.white.opacity(0.25))

            HStack(spacing: 0) {
                heroBreakdown(title: "Bruto", value: Fmt.brl(metrics.grossBRL))
                heroBreakdown(title: "Combustível", value: "−\(Fmt.brl(metrics.fuelBRL))")
                heroBreakdown(title: "Extras", value: "−\(Fmt.brl(metrics.extraBRL))")
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Theme.accent, Theme.accentDark],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func heroBreakdown(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .opacity(0.8)
            Text(value)
                .font(.system(.footnote, design: .rounded).weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func appRow(source: String, count: Int, gross: Double) -> some View {
        HStack {
            SourceBadge(source: source)
            Text("\(count) corridas")
                .foregroundStyle(.primary)
            Spacer()
            Text(Fmt.brl(gross))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func exportText(_ turn: ArchivedTurn, rides: [RideAnalysis]) -> String {
        let m = turn.metrics
        var lines: [String] = []
        lines.append("Extrato — \(Fmt.longDay(turn.startedAt))")
        lines.append("Corridas: \(m.rideCount) · Tempo: \(Fmt.duration(minutes: m.totalMinutes)) · Distância: \(Fmt.km(m.totalKm))")
        lines.append("Bruto: \(Fmt.brl(m.grossBRL)) · Combustível: −\(Fmt.brl(m.fuelBRL)) · Extras: −\(Fmt.brl(m.extraBRL))")
        lines.append("Lucro livre: \(Fmt.brl(m.netBRL)) (\(Fmt.perHour(m.netPerHour)))")
        lines.append("")
        for ride in rides {
            lines.append("\(Fmt.time(timestamp: ride.offer.timestamp)) [\(ride.offer.appSource)] \(Fmt.brl(ride.offer.fareBRL)) · \(Fmt.km(ride.offer.totalDistanceKm)) · \(ride.offer.totalMinutes) min · líquido \(Fmt.brl(ride.netProfitBRL))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Ofertas lidas

enum OfferFilter: CaseIterable, Identifiable {
    case all, good, warning, rejected, registered

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "Todas"
        case .good: return "Boas"
        case .warning: return "Atenção"
        case .rejected: return "Recusadas"
        case .registered: return "Registradas"
        }
    }
}

struct OffersListView: View {
    @ObservedObject var viewModel: ContentViewModel
    @State private var filter: OfferFilter = .all
    @State private var showClearTodayDialog = false
    @State private var showClearAllDialog = false

    private func matches(_ ride: RideAnalysis, _ filter: OfferFilter) -> Bool {
        switch filter {
        case .all: return true
        case .good: return ride.verdict == .approved
        case .warning: return ride.verdict == .warning
        case .rejected: return ride.verdict == .rejected
        case .registered: return viewModel.isRideAlreadyAccepted(ride)
        }
    }

    private var days: [(key: Date, rides: [RideAnalysis])] {
        let calendar = Calendar.current
        let filtered = viewModel.history.filter { matches($0, filter) }
        let groups = Dictionary(grouping: filtered) { ride in
            calendar.startOfDay(for: Date(timeIntervalSince1970: ride.offer.timestamp))
        }
        return groups.keys.sorted(by: >).map { key in
            (key: key, rides: (groups[key] ?? []).sorted { $0.offer.timestamp > $1.offer.timestamp })
        }
    }

    var body: some View {
        let history = viewModel.history

        return List {
            if history.isEmpty {
                Section {
                    EmptyStateView(
                        icon: "tray",
                        title: "Nenhuma oferta lida",
                        message: "Com o leitor ligado, toda oferta que aparecer na Uber ou na 99 é analisada e listada aqui."
                    )
                    .plainListRow()
                }
            } else {
                Section {
                    summaryCard(history)
                        .plainListRow(top: 4, bottom: 4)
                }

                Section {
                    filterChips
                        .plainListRow(top: 0, bottom: 0)
                }

                if days.isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "line.3.horizontal.decrease.circle",
                            title: "Nada neste filtro",
                            message: "Nenhuma oferta corresponde ao filtro selecionado."
                        )
                        .plainListRow()
                    }
                }

                ForEach(days, id: \.key) { day in
                    Section {
                        ForEach(day.rides) { ride in
                            let accepted = viewModel.isRideAlreadyAccepted(ride)
                            Button {
                                viewModel.selectedRideDetail = ride
                            } label: {
                                OfferRow(ride: ride, accepted: accepted)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !accepted {
                                    Button {
                                        viewModel.acceptRide(ride, source: "histórico")
                                    } label: {
                                        Label("Registrar", systemImage: "plus.circle.fill")
                                    }
                                    .tint(Theme.accent)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deleteOffers(ids: [ride.id])
                                } label: {
                                    Label("Excluir", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(Fmt.relativeDay(day.key))
                            Spacer()
                            Text("\(day.rides.count) ofertas")
                        }
                        .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showClearTodayDialog = true
                    } label: {
                        Label("Apagar ofertas de hoje", systemImage: "calendar.badge.minus")
                    }
                    Button(role: .destructive) {
                        showClearAllDialog = true
                    } label: {
                        Label("Apagar todo o histórico", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(history.isEmpty)
            }
        }
        .confirmationDialog("Apagar ofertas de hoje?", isPresented: $showClearTodayDialog, titleVisibility: .visible) {
            Button("Apagar ofertas de hoje", role: .destructive) {
                viewModel.clearTodayOffers()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As corridas já registradas em Ganhos não são afetadas.")
        }
        .confirmationDialog("Apagar todo o histórico de ofertas?", isPresented: $showClearAllDialog, titleVisibility: .visible) {
            Button("Apagar \(history.count) ofertas", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As corridas já registradas em Ganhos e nos extratos não são afetadas.")
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OfferFilter.allCases) { item in
                    chip(item)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func chip(_ item: OfferFilter) -> some View {
        let selected = filter == item
        let count = viewModel.history.filter { matches($0, item) }.count
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = item }
        } label: {
            Text("\(item.title) · \(count)")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.card)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func summaryCard(_ history: [RideAnalysis]) -> some View {
        let good = history.filter { $0.verdict == .approved }.count
        let warning = history.filter { $0.verdict == .warning }.count
        let rejected = history.filter { $0.verdict == .rejected }.count
        let registered = history.filter { viewModel.isRideAlreadyAccepted($0) }.count
        let rate = history.isEmpty ? 0 : Double(registered) / Double(history.count)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                offerStat(value: "\(history.count)", label: "lidas", color: .primary)
                offerStat(value: "\(good)", label: "boas", color: Theme.good)
                offerStat(value: "\(warning)", label: "atenção", color: Theme.caution)
                offerStat(value: "\(rejected)", label: "recusadas", color: Theme.bad)
            }
            Divider()
            HStack {
                Label("\(registered) registradas nos ganhos", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.percent(rate)) das lidas")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func offerStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
