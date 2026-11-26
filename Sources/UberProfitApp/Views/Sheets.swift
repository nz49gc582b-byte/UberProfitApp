import SwiftUI
import UIKit

// MARK: - Detalhe de uma corrida/oferta

public struct RideDetailSheet: View {
    @ObservedObject var viewModel: ContentViewModel
    let ride: RideAnalysis

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    public init(viewModel: ContentViewModel, ride: RideAnalysis) {
        self.viewModel = viewModel
        self.ride = ride
    }

    public var body: some View {
        let inShift = viewModel.isRideAlreadyAccepted(ride)
        let inArchive = viewModel.isRideInArchivedTurns(ride)
        let date = Date(timeIntervalSince1970: ride.offer.timestamp)

        return NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        HStack {
                            SourceBadge(source: ride.offer.appSource)
                            Spacer()
                            VerdictPill(verdict: ride.verdict)
                        }
                        Text(Fmt.brl(ride.offer.fareBRL))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("\(Fmt.longDay(date)) · \(Fmt.time(date))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Análise") {
                    row("Por km (bruto)", Fmt.perKm(ride.grossPerKm))
                    row("Por km (líquido)", Fmt.perKm(ride.netPerKm))
                    row("Por hora (bruto)", Fmt.perHour(ride.grossPerHour))
                    row("Por hora (líquido)", Fmt.perHour(ride.netPerHour))
                    row("Combustível estimado", "−\(Fmt.brl(ride.fuelCostBRL))")
                    row("Lucro livre", Fmt.signedBRL(ride.netProfitBRL), tint: ride.netProfitBRL >= 0 ? Theme.good : Theme.bad)
                }

                Section("Trajeto") {
                    row("Até o passageiro", "\(Fmt.km(ride.offer.pickupDistanceKm)) · \(ride.offer.pickupMinutes) min")
                    row("Viagem", "\(Fmt.km(ride.offer.tripDistanceKm)) · \(ride.offer.tripMinutes) min")
                    row("Total", "\(Fmt.km(ride.offer.totalDistanceKm)) · \(ride.offer.totalMinutes) min")
                }

                Section {
                    if inShift {
                        Button(role: .destructive) {
                            viewModel.removeAcceptedRide(ride)
                            dismiss()
                        } label: {
                            Label("Remover dos ganhos", systemImage: "minus.circle")
                        }
                    } else if inArchive {
                        Label("Registrada em um extrato anterior", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            viewModel.acceptRide(ride, source: "detalhe")
                            dismiss()
                        } label: {
                            Label("Registrar nos ganhos", systemImage: "plus.circle.fill")
                        }
                    }
                }

                Section {
                    Text(ride.offer.rawRecognizedText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = ride.offer.rawRecognizedText
                        copied = true
                    } label: {
                        Label(copied ? "Copiado" : "Copiar texto", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } header: {
                    Text("Texto lido da tela")
                } footer: {
                    Text("Útil para diagnosticar leituras incorretas.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Detalhes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Lançamento manual

public struct AddManualRideSheetView: View {
    @ObservedObject var viewModel: ContentViewModel

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Aplicativo") {
                    Picker("Aplicativo", selection: $viewModel.manualRideApp) {
                        Text("Uber").tag("UBER")
                        Text("99").tag("99")
                        Text("Outro").tag("EXTRA")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    HStack {
                        Text("Valor recebido")
                        Spacer()
                        Text("R$")
                            .foregroundStyle(.secondary)
                        TextField("18,50", text: $viewModel.manualRideFareText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    HStack {
                        Text("Distância total")
                        Spacer()
                        TextField("6,5", text: $viewModel.manualRideKmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("km")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Tempo total")
                        Spacer()
                        TextField("15", text: $viewModel.manualRideMinText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("min")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dados da corrida")
                } footer: {
                    Text("O combustível é estimado com o consumo e o preço configurados em Ajustes.")
                }
            }
            .navigationTitle("Lançar corrida")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        viewModel.showAddManualRideSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        viewModel.saveManualRide()
                    }
                    .bold()
                    .disabled(!viewModel.canSaveManualRide)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
