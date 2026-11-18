import Foundation

/// Formatação centralizada em português do Brasil (moeda, distância, duração e datas).
@MainActor
public enum Fmt {
    private static let ptBR = Locale(identifier: "pt_BR")

    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = ptBR
        f.numberStyle = .currency
        f.currencySymbol = "R$"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let currencyRounded: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = ptBR
        f.numberStyle = .currency
        f.currencySymbol = "R$"
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    private static let oneDecimal: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = ptBR
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    private static func dateFormatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = ptBR
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = ptBR
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let shortDayFormatter = dateFormatter("EEE d MMM")
    private static let longDayFormatter = dateFormatter("EEEE d MMMM")
    private static let monthFormatter = dateFormatter("MMMM y")
    private static let weekdayFormatter = dateFormatter("EEE")
    private static let monthShortFormatter = dateFormatter("MMM")

    /// "TER", "QUA"… (sem ponto final)
    public static func weekdayShort(_ date: Date) -> String {
        weekdayFormatter.string(from: date).replacingOccurrences(of: ".", with: "").uppercased()
    }

    /// "nov", "dez"… (sem ponto final)
    public static func monthShort(_ date: Date) -> String {
        monthShortFormatter.string(from: date).replacingOccurrences(of: ".", with: "").lowercased()
    }

    public static func dayNumber(_ date: Date) -> String {
        "\(Calendar.current.component(.day, from: date))"
    }

    // MARK: - Números

    public static func brl(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? "R$ 0,00"
    }

    public static func brlRounded(_ value: Double) -> String {
        currencyRounded.string(from: NSNumber(value: value)) ?? "R$ 0"
    }

    public static func signedBRL(_ value: Double) -> String {
        value >= 0 ? "+\(brl(value))" : "−\(brl(abs(value)))"
    }

    public static func perKm(_ value: Double) -> String { "\(brl(value))/km" }
    public static func perHour(_ value: Double) -> String { "\(brlRounded(value))/h" }

    public static func km(_ value: Double) -> String {
        "\(oneDecimal.string(from: NSNumber(value: value)) ?? "0,0") km"
    }

    public static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        return hours > 0 ? String(format: "%dh %02dmin", hours, mins) : "\(mins) min"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Converte texto digitado ("18,50" ou "18.50") em número.
    public static func parseDecimal(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    // MARK: - Datas

    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    public static func time(timestamp: TimeInterval) -> String { time(Date(timeIntervalSince1970: timestamp)) }

    public static func shortDay(_ date: Date) -> String { capitalizedFirst(shortDayFormatter.string(from: date)) }
    public static func longDay(_ date: Date) -> String { capitalizedFirst(longDayFormatter.string(from: date)) }
    public static func month(_ date: Date) -> String { capitalizedFirst(monthFormatter.string(from: date)) }

    /// "Hoje", "Ontem" ou data curta.
    public static func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Hoje" }
        if calendar.isDateInYesterday(date) { return "Ontem" }
        return shortDay(date)
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
