import SwiftUI

// MARK: - PAINEL (operação ao vivo)

public struct PanelView: View {
    @ObservedObject var viewModel: ContentViewModel
    @ObservedObject private var config: AppConfiguration
    @ObservedObject private var udpListener: UDPListenerManager
    @ObservedObject private var keepAlive: BackgroundKeepAlive
    @ObservedObject private var pipManager: PiPOverlayManager

    public init(viewModel: ContentViewModel) {
        self.viewModel = viewModel
        self._config = ObservedObject(wrappedValue: viewModel.config)
        self._udpListener = ObservedObject(wrappedValue: viewModel.udpListener)
        self._keepAlive = ObservedObject(wrappedValue: viewModel.keepAlive)
        self._pipManager = ObservedObject(wrappedValue: viewModel.pipManager)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if config.showQuickGuide {
                    guideCard
                }

                statusStrip
                liveCard
                controls

                if let candidate = viewModel.latestAnalysis ?? viewModel.lastSeenAnalysis {
                    lastOfferCard(candidate)
                }

                shiftCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Painel")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation { config.showQuickGuide.toggle() }
                } label: {
                    Image(systemName: config.showQuickGuide ? "questionmark.circle.fill" : "questionmark.circle")
                }
            }
        }
    }

    // MARK: Guia rápido

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Como funciona", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button {
                    withAnimation { config.showQuickGuide = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                guideStep(number: "1", text: "Toque em Iniciar leitor e escolha UberProfit ScreenReader.")
                guideStep(number: "2", text: "Abra a Uber ou a 99: o app calcula o lucro e avisa por voz, banner ou PiP.")
                guideStep(number: "3", text: "Aceitou? A corrida entra em Ganhos automaticamente (ou com 1 toque).")
            }
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent)
                .clipShape(Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Status

    private var statusStrip: some View {
        let readerDetail = udpListener.broadcastActive ? "Capturando" : (udpListener.isListening ? "Parado" : "Sem conexão")
        return HStack(spacing: 10) {
            StatusChip(
                icon: "dot.radiowaves.left.and.right",
                title: "Leitor",
                detail: readerDetail,
                isOn: udpListener.broadcastActive
            )
            StatusChip(
                icon: "bolt.shield.fill",
                title: "2º plano",
                detail: keepAlive.isRunning ? "Ativo" : "Parado",
                isOn: keepAlive.isRunning
            )
            Button {
                config.voiceAlertsEnabled.toggle()
            } label: {
                StatusChip(
                    icon: config.voiceAlertsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    title: "Voz",
                    detail: config.voiceAlertsEnabled ? "Ligada" : "Mudo",
                    isOn: config.voiceAlertsEnabled,
                    tint: Theme.accent
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Monitor ao vivo

    private var liveCard: some View {
        ZStack {
            PiPLayerContainerView(displayLayer: pipManager.displayLayer)
                .opacity(config.visualAlertMode == .notificationOnly ? 0.01 : 1.0)

            if config.visualAlertMode == .notificationOnly {
                nativePreviewCard
            }
        }
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    udpListener.broadcastActive ? Theme.good.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: 1.5
                )
        )
    }

    private var nativePreviewCard: some View {
        let analysis = viewModel.latestAnalysis
        let background: Color = {
            guard let analysis else { return Color(red: 0.07, green: 0.09, blue: 0.13) }
            switch analysis.verdict {
            case .approved: return Color(red: 0.05, green: 0.50, blue: 0.24)
            case .warning: return Color(red: 0.72, green: 0.47, blue: 0.02)
            case .rejected: return Color(red: 0.66, green: 0.10, blue: 0.14)
            }
        }()

        return ZStack {
            Rectangle().fill(background)

            if let analysis {
                let shownKm = (config.primaryMetricDisplay == .net) ? analysis.netPerKm : analysis.grossPerKm
                let shownHour = (config.primaryMetricDisplay == .net) ? analysis.netPerHour : analysis.grossPerHour

                VStack(spacing: 10) {
                    HStack {
                        Text("\(analysis.offer.appSource) · \(Theme.title(for: analysis.verdict).uppercased())")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.28))
                            .clipShape(Capsule())
                        Spacer()
                        Text("Lucro \(Fmt.brl(analysis.netProfitBRL))")
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.perKm(shownKm))
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.7)
                        Spacer()
                        Text(Fmt.perHour(shownHour))
                            .font(.system(size: 28, weight: .heavy, design: .rounded))
                            .minimumScaleFactor(0.7)
                    }
                    .monospacedDigit()

                    Text("Tarifa \(Fmt.brl(analysis.offer.fareBRL)) · \(Fmt.km(analysis.offer.totalDistanceKm)) · \(analysis.offer.totalMinutes) min · Comb. −\(Fmt.brl(analysis.fuelCostBRL))")
                        .font(.caption.weight(.semibold))
                        .opacity(0.95)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundStyle(.white)
                .padding(16)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: udpListener.broadcastActive ? "waveform.path.ecg" : "play.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(udpListener.broadcastActive ? "Monitorando ofertas" : "Leitor desligado")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(udpListener.broadcastActive
                         ? "Abra a Uber ou a 99. Você será avisado por banner e voz."
                         : "Toque em Iniciar leitor para começar.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
    }

    // MARK: Controles

    private var controls: some View {
        HStack(spacing: 12) {
            readerButton
            secondaryButton
        }
    }

    private var readerButton: some View {
        let active = udpListener.broadcastActive
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(active ? Theme.bad : Theme.accent)

            HStack(spacing: 10) {
                Image(systemName: active ? "stop.circle.fill" : "record.circle.fill")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(active ? "Parar leitor" : "Iniciar leitor")
                        .font(.subheadline.weight(.semibold))
                    Text(active ? "Capturando a tela" : "Toque para ligar")
                        .font(.caption2)
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)

            // O seletor nativo do ReplayKit fica por trás do visual e recebe o toque.
            BroadcastPickerRepresentable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blendMode(.destinationOver)
        }
        .frame(height: 60)
    }

    @ViewBuilder
    private var secondaryButton: some View {
        if config.visualAlertMode != .notificationOnly {
            Button {
                pipManager.togglePiP()
            } label: {
                secondaryButtonLabel(
                    icon: pipManager.isPiPActive ? "pip.exit" : "pip.enter",
                    title: pipManager.isPiPActive ? "PiP ativo" : "Abrir PiP",
                    subtitle: pipManager.isPiPActive ? "Toque para fechar" : "Janela flutuante",
                    tint: pipManager.isPiPActive ? Theme.caution : Theme.accent
                )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                viewModel.selectedTab = .settings
            } label: {
                secondaryButtonLabel(
                    icon: "bell.badge.fill",
                    title: "Só notificação",
                    subtitle: "Alterar em Ajustes",
                    tint: Theme.accent
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func secondaryButtonLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 60)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Última oferta

    private func lastOfferCard(_ item: RideAnalysis) -> some View {
        let accepted = viewModel.isRideAlreadyAccepted(item)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                viewModel.selectedRideDetail = item
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Última oferta")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Text(Fmt.time(timestamp: item.offer.timestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                SourceBadge(source: item.offer.appSource)
                                Text(Fmt.brl(item.offer.fareBRL))
                                    .font(.system(.title3, design: .rounded).weight(.bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                            }
                            Text("\(Fmt.km(item.offer.totalDistanceKm)) · \(item.offer.totalMinutes) min · lucro \(Fmt.brl(item.netProfitBRL))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VerdictPill(verdict: item.verdict)
                    }
                }
            }
            .buttonStyle(.plain)

            if accepted {
                Label("Registrada nos ganhos", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.good)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                Button {
                    viewModel.acceptRide(item, source: "painel")
                } label: {
                    Label("Registrar corrida", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .card()
    }

    // MARK: Turno atual

    private var shiftCard: some View {
        let metrics = viewModel.currentShiftMetrics
        let offers = viewModel.todayOffers
        let goodCount = offers.filter { $0.verdict == .approved }.count
        let warningCount = offers.filter { $0.verdict == .warning }.count
        let rejectedCount = offers.filter { $0.verdict == .rejected }.count
        let goal = config.dailyNetGoalBRL
        let progress = goal > 0 ? min(max(metrics.netBRL / goal, 0), 1) : 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turno atual")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(Fmt.longDay(Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.selectedTab = .earnings
                } label: {
                    HStack(spacing: 3) {
                        Text("Ganhos")
                        Image(systemName: "chevron.right")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.brl(metrics.netBRL))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("lucro livre")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text("Meta de \(Fmt.brl(goal)) · \(Fmt.percent(progress)) concluída")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                miniStat(value: "\(metrics.rideCount)", label: "corridas")
                miniStat(value: Fmt.perHour(metrics.netPerHour), label: "líquido/hora")
                miniStat(value: Fmt.km(metrics.totalKm), label: "rodados")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Ofertas lidas hoje · \(offers.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    offerDot(count: goodCount, label: "boas", color: Theme.good)
                    offerDot(count: warningCount, label: "atenção", color: Theme.caution)
                    offerDot(count: rejectedCount, label: "recusadas", color: Theme.bad)
                    Spacer(minLength: 0)
                }
            }
        }
        .card()
    }

    private func miniStat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
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

    private func offerDot(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(count) \(label)")
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
