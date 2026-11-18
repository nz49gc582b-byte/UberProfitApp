import SwiftUI

// MARK: - Tema

public enum Theme {
    /// Verde-esmeralda: cor de marca e de "lucro".
    public static var accent: Color { Color(red: 0.04, green: 0.60, blue: 0.40) }
    public static var accentDark: Color { Color(red: 0.02, green: 0.36, blue: 0.27) }
    public static var good: Color { Color(red: 0.13, green: 0.68, blue: 0.38) }
    public static var caution: Color { Color(red: 0.96, green: 0.62, blue: 0.08) }
    public static var bad: Color { Color(red: 0.88, green: 0.26, blue: 0.26) }
    public static var ninetyNine: Color { Color(red: 1.0, green: 0.78, blue: 0.0) }

    public static var background: Color { Color(.systemGroupedBackground) }
    public static var card: Color { Color(.secondarySystemGroupedBackground) }
    public static var subtleFill: Color { Color(.tertiarySystemGroupedBackground) }

    public static func color(for verdict: RideVerdict) -> Color {
        switch verdict {
        case .approved: return good
        case .warning: return caution
        case .rejected: return bad
        }
    }

    public static func title(for verdict: RideVerdict) -> String {
        switch verdict {
        case .approved: return "Aceitar"
        case .warning: return "Atenção"
        case .rejected: return "Recusar"
        }
    }

    public static func icon(for verdict: RideVerdict) -> String {
        switch verdict {
        case .approved: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .rejected: return "xmark.circle.fill"
        }
    }
}

// MARK: - Modificadores

private struct CardModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    /// Cartão padrão do app (fundo elevado, cantos arredondados).
    public func card(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }

    /// Remove o estilo de linha de `List` para usar cartões próprios dentro dela.
    public func plainListRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
    }
}

// MARK: - Componentes

/// Selo do aplicativo de origem (Uber / 99 / Outro).
public struct SourceBadge: View {
    let source: String

    public init(source: String) { self.source = source }

    public var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var label: String {
        switch source {
        case "UBER": return "UBER"
        case "99": return "99"
        default: return "OUTRO"
        }
    }

    private var background: Color {
        switch source {
        case "UBER": return Color.primary
        case "99": return Theme.ninetyNine
        default: return Color.gray.opacity(0.3)
        }
    }

    private var foreground: Color {
        switch source {
        case "UBER": return Color(.systemBackground)
        case "99": return .black
        default: return .primary
        }
    }
}

/// Etiqueta colorida do veredito (Aceitar / Atenção / Recusar).
public struct VerdictPill: View {
    let verdict: RideVerdict

    public init(verdict: RideVerdict) { self.verdict = verdict }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.icon(for: verdict))
            Text(Theme.title(for: verdict))
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.color(for: verdict).opacity(0.15))
        .foregroundStyle(Theme.color(for: verdict))
        .clipShape(Capsule())
    }
}

/// Indicador compacto de status (ex.: Leitor ativo, 2º plano, Voz).
public struct StatusChip: View {
    let icon: String
    let title: String
    let detail: String
    let isOn: Bool
    let tint: Color

    public init(icon: String, title: String, detail: String, isOn: Bool, tint: Color = Theme.good) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isOn ? tint : Color.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(isOn ? tint : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Bloco de métrica (ícone + título + valor + legenda).
public struct MetricTile: View {
    let icon: String
    let title: String
    let value: String
    let caption: String
    let tint: Color

    public init(icon: String, title: String, value: String, caption: String = "", tint: Color = Theme.accent) {
        self.icon = icon
        self.title = title
        self.value = value
        self.caption = caption
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14)
    }
}

/// Tela vazia padrão.
public struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    public init(icon: String, title: String, message: String) {
        self.icon = icon
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// Anel de progresso (meta diária).
public struct ProgressRing: View {
    let progress: Double
    let lineWidth: CGFloat
    let tint: Color

    public init(progress: Double, lineWidth: CGFloat = 8, tint: Color = .white) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Linha de ajuste com rótulo, valor em destaque e slider.
public struct SliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    public init(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        tint: Color = Theme.accent
    ) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.step = step
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
        }
        .padding(.vertical, 2)
    }
}
