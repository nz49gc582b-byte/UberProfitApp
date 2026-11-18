import SwiftUI

// MARK: - Linha de corrida registrada (Ganhos e Extratos)

public struct AcceptedRideRow: View {
    let ride: RideAnalysis

    public init(ride: RideAnalysis) { self.ride = ride }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    SourceBadge(source: ride.offer.appSource)
                    Text(Fmt.time(timestamp: ride.offer.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Fmt.brl(ride.offer.fareBRL))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("\(Fmt.km(ride.offer.totalDistanceKm)) · \(ride.offer.totalMinutes) min · \(Fmt.perKm(ride.grossPerKm))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.signedBRL(ride.netProfitBRL))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(ride.netProfitBRL >= 0 ? Theme.good : Theme.bad)
                Text("líquido")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Linha de oferta lida (Histórico de ofertas)

public struct OfferRow: View {
    let ride: RideAnalysis
    let accepted: Bool

    public init(ride: RideAnalysis, accepted: Bool) {
        self.ride = ride
        self.accepted = accepted
    }

    public var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.color(for: ride.verdict))
                .frame(width: 4, height: 44)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    SourceBadge(source: ride.offer.appSource)
                    Text(Fmt.time(timestamp: ride.offer.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if accepted {
                        Label("Registrada", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.good)
                    }
                }
                Text(Fmt.brl(ride.offer.fareBRL))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("\(Fmt.km(ride.offer.totalDistanceKm)) · \(ride.offer.totalMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.perKm(ride.grossPerKm))
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.color(for: ride.verdict))
                Text(Fmt.perHour(ride.grossPerHour))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
