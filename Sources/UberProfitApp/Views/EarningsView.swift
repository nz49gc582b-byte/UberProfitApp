import SwiftUI

// MARK: - GANHOS (turno atual)

public struct EarningsView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration

    @State private var showFinishDialog = false
    @State private var showDiscardDialog = false
    @State private var showExpenseSheet = false

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
    }

    public var body: some View {
        let metrics = viewModel.currentShiftMetrics
        let hasRides = !viewModel.acceptedRides.isEmpty

        return List {
            Section {
                heroCard(metrics)
                    .plainListRow(top: 4, bottom: 4)
            }

            if hasRides {
                Section {
                    MetricsGridView(metrics: metrics)
                        .plainListRow(top: 4, bottom: 4)
                }
            }

            Section {
                Button {
                    showExpenseSheet = true
                } label: {
                    HStack {
                        Label("Gastos extras do dia", systemImage: "creditcard.fill")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("−\(Fmt.brl(config.extraDailyExpenseBRL))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            } footer: {
                Text("Lanche, lavagem, aluguel do carro… são descontados do lucro livre do turno.")
            }

            Section {
                if hasRides {
                    ForEach(viewModel.acceptedRides.reversed()) { ride in
                        Button {
                            viewModel.selectedRideDetail = ride
                        } label: {
                            AcceptedRideRow(ride: ride)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.removeAcceptedRide(ride)
                            } label: {
                                Label("Remover", systemImage: "trash")
                            }
                        }
                    }
                } else {
                    EmptyStateView(
                        icon: "car.circle",
                        title: "Nenhuma corrida registrada",
                        message: "Quando você aceitar uma corrida na Uber ou na 99, ela aparece aqui. Também dá para lançar manualmente no botão +."
                    )
                    .plainListRow()
                }
            } header: {
                Text("Corridas do turno · \(viewModel.acceptedRides.count)")
            }

            if hasRides {
                Section {
                    Button {
                        showFinishDialog = true
                    } label: {
                        Label("Finalizar turno e arquivar", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .plainListRow()
                } footer: {
                    Text("O turno é arquivado automaticamente quando um novo dia começa.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ganhos")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.showAddManualRideSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showExpenseSheet = true
                    } label: {
                        Label("Gastos extras do dia", systemImage: "creditcard")
                    }
                    Divider()
                    Button {
                        showFinishDialog = true
                    } label: {
                        Label("Finalizar turno", systemImage: "checkmark.seal")
                    }
                    .disabled(!hasRides)
                    Button(role: .destructive) {
                        showDiscardDialog = true
                    } label: {
                        Label("Descartar turno", systemImage: "trash")
                    }
                    .disabled(!hasRides)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Finalizar turno?", isPresented: $showFinishDialog, titleVisibility: .visible) {
            Button("Finalizar e arquivar no extrato") {
                viewModel.finishTurn()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As \(viewModel.acceptedRides.count) corridas serão movidas para o extrato, em Histórico.")
        }
        .confirmationDialog("Descartar turno?", isPresented: $showDiscardDialog, titleVisibility: .visible) {
            Button("Descartar sem arquivar", role: .destructive) {
                viewModel.clearTurn()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("As corridas deste turno serão apagadas e NÃO irão para o extrato.")
        }
        .sheet(isPresented: $showExpenseSheet) {
            ExpenseSheet(config: config)
        }
    }

    // MARK: Card principal

    private func heroCard(_ m: ShiftMetrics) -> some View {
        let goal = config.dailyNetGoalBRL
        let progress = goal > 0 ? min(max(m.netBRL / goal, 0), 1) : 0

        return VStack(spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lucro livre do turno")
                        .font(.footnote.weight(.semibold))
                        .opacity(0.85)
                    Text(Fmt.brl(m.netBRL))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("\(m.rideCount) corridas · \(Fmt.duration(minutes: m.totalMinutes))")
                        .font(.caption)
                        .opacity(0.85)
                }
                Spacer()
                ZStack {
                    ProgressRing(progress: progress, lineWidth: 7, tint: .white)
                    VStack(spacing: 0) {
                        Text(Fmt.percent(progress))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                        Text("da meta")
                            .font(.system(size: 9))
                            .opacity(0.8)
                    }
                }
                .frame(width: 72, height: 72)
            }

            Divider()
                .overlay(Color.white.opacity(0.25))

            HStack(spacing: 0) {
                heroBreakdown(title: "Bruto", value: Fmt.brl(m.grossBRL))
                heroBreakdown(title: "Combustível", value: "−\(Fmt.brl(m.fuelBRL))")
                heroBreakdown(title: "Extras", value: "−\(Fmt.brl(m.extraBRL))")
            }

            Text("Meta diária: \(Fmt.brl(goal))")
                .font(.caption)
                .opacity(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(18)
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
}

// MARK: - Gastos extras do dia

public struct ExpenseSheet: View {
    @ObservedObject var config: AppConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    public init(config: AppConfiguration) {
        self.config = config
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Total do turno")
                        Spacer()
                        Text("R$")
                            .foregroundStyle(.secondary)
                        TextField("0,00", text: $text)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                    }
                } footer: {
                    Text("Valor total gasto hoje fora o combustível (já calculado por corrida).")
                }

                Section("Adicionar rápido") {
                    HStack(spacing: 8) {
                        ForEach([5.0, 10.0, 20.0, 50.0], id: \.self) { amount in
                            Button("+\(Int(amount))") {
                                add(amount)
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }

                if (Fmt.parseDecimal(text) ?? 0) > 0 {
                    Section {
                        Button("Zerar gastos", role: .destructive) {
                            text = ""
                        }
                    }
                }
            }
            .navigationTitle("Gastos do dia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        config.extraDailyExpenseBRL = max(Fmt.parseDecimal(text) ?? 0, 0)
                        dismiss()
                    }
                    .bold()
                }
            }
            .onAppear {
                if config.extraDailyExpenseBRL > 0 {
                    text = String(format: "%.2f", config.extraDailyExpenseBRL).replacingOccurrences(of: ".", with: ",")
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add(_ amount: Double) {
        let current = Fmt.parseDecimal(text) ?? 0
        text = String(format: "%.2f", current + amount).replacingOccurrences(of: ".", with: ",")
    }
}
