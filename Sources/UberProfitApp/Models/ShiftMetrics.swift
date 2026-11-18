import Foundation

/// Métricas consolidadas de um conjunto de corridas (turno atual ou extrato arquivado).
/// Todos os valores usam o custo de combustível calculado no momento de cada corrida,
/// garantindo que "Ganhos" e "Extrato" sempre mostrem exatamente os mesmos números.
public struct ShiftMetrics: Sendable, Equatable {
    public let rideCount: Int
    public let grossBRL: Double
    public let fuelBRL: Double
    public let extraBRL: Double
    public let totalKm: Double
    public let pickupKm: Double
    public let tripKm: Double
    public let totalMinutes: Int
    public let uberCount: Int
    public let ninetyNineCount: Int
    public let otherCount: Int
    public let uberGrossBRL: Double
    public let ninetyNineGrossBRL: Double

    public init(rides: [RideAnalysis], extraExpenseBRL: Double = 0) {
        var gross = 0.0
        var fuel = 0.0
        var km = 0.0
        var pickup = 0.0
        var trip = 0.0
        var minutes = 0
        var uber = 0
        var n99 = 0
        var other = 0
        var uberGross = 0.0
        var n99Gross = 0.0

        for ride in rides {
            gross += ride.offer.fareBRL
            fuel += ride.fuelCostBRL
            km += ride.offer.totalDistanceKm
            pickup += ride.offer.pickupDistanceKm
            trip += ride.offer.tripDistanceKm
            minutes += ride.offer.totalMinutes
            switch ride.offer.appSource {
            case "UBER":
                uber += 1
                uberGross += ride.offer.fareBRL
            case "99":
                n99 += 1
                n99Gross += ride.offer.fareBRL
            default:
                other += 1
            }
        }

        self.rideCount = rides.count
        self.grossBRL = gross
        self.fuelBRL = fuel
        self.extraBRL = max(extraExpenseBRL, 0)
        self.totalKm = km
        self.pickupKm = pickup
        self.tripKm = trip
        self.totalMinutes = minutes
        self.uberCount = uber
        self.ninetyNineCount = n99
        self.otherCount = other
        self.uberGrossBRL = uberGross
        self.ninetyNineGrossBRL = n99Gross
    }

    /// Lucro livre = bruto − combustível − gastos extras
    public var netBRL: Double { grossBRL - fuelBRL - extraBRL }

    public var grossPerKm: Double { totalKm > 0 ? grossBRL / totalKm : 0 }
    public var netPerKm: Double { totalKm > 0 ? netBRL / totalKm : 0 }
    public var grossPerHour: Double { totalMinutes > 0 ? grossBRL / Double(totalMinutes) * 60.0 : 0 }
    public var netPerHour: Double { totalMinutes > 0 ? netBRL / Double(totalMinutes) * 60.0 : 0 }
    public var averageTicketBRL: Double { rideCount > 0 ? grossBRL / Double(rideCount) : 0 }
}
