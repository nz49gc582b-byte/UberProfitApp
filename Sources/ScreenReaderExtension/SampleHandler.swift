import ReplayKit
import Vision
import Network
import CoreImage
import UIKit

/// Payload compartilhado enviado via UDP local para o App Principal
public struct RideOfferPayload: Codable, Sendable {
    public let appSource: String?
    public let fareBRL: Double
    public let pickupDistanceKm: Double
    public let tripDistanceKm: Double
    public let totalDistanceKm: Double
    public let pickupMinutes: Int
    public let tripMinutes: Int
    public let totalMinutes: Int
    public let rawRecognizedText: String
    public let timestamp: TimeInterval
}

/// Pacote de confirmação de corrida aceita com o payload completo da oferta embutido
/// (garante 100% de registro mesmo se o app principal estivesse em transição de 2º plano).
public struct AcceptedRideEventPayload: Codable, Sendable {
    public let status: String
    public let triggerReason: String
    public let offer: RideOfferPayload
}

private struct RecognizedLine {
    let text: String
    let midY: CGFloat
    let height: CGFloat
}

@objc(SampleHandler)
public final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    // MARK: - Configurações de Performance e Limites
    private let normalThrottleInterval: TimeInterval = 0.35
    private let fastPostOfferThrottleInterval: TimeInterval = 0.22
    private let heartbeatInterval: TimeInterval = 1.5
    private let debounceInterval: TimeInterval = 2.2
    private let udpHost: NWEndpoint.Host = "127.0.0.1"
    private let udpPort: NWEndpoint.Port = 9876

    // MARK: - Estado Interno
    private var lastProcessedTime: TimeInterval = 0
    private var lastHeartbeatTime: TimeInterval = 0
    private var recentOfferHashes: [Int: TimeInterval] = [:]
    private var lastValidOfferSeenTime: TimeInterval = 0
    private var lastSnapshotTime: TimeInterval = 0
    private var acceptedHitCount: Int = 0
    private var idleHitCount: Int = 0
    private var didSendClearCard: Bool = true
    private var didSendAcceptedForLastOffer: Bool = true
    private var isProcessingFrame: Bool = false

    // Guarda a última oferta lida com timestamp fixo e o endereço de embarque extraído
    private var activeOfferPayload: RideOfferPayload?
    private var activeOfferHash: Int = 0
    private var activeOfferPickupStreet: String = ""

    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

    // MARK: - Regex Pré-Compiladas (Uber Driver + 99 Motorista)
    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\+)(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    // Captura exata do botão da 99 Negocia: "Aceitar por R$ 8,14"
    private static let acceptButtonPriceRegex = try! NSRegularExpression(
        pattern: #"Aceitar\s+por\s+(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))"#,
        options: [.caseInsensitive]
    )
    // Formato Uber e 99 Pop tradicional: "3 min (0.8 km)" ou "8 min (3,2 km)"
    private static let stepOutsideParenRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Formato 99 Negocia / Solicitações: "(3 min 1 km)" ou "(19 min 9,2 km)"
    private static let stepInsideParenRegex = try! NSRegularExpression(
        pattern: #"\(\s*(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s+(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Linha de resumo da Uber ou barra de navegação pós-aceite: "15 min • 5.4 km" ou "4 min · 872 m"
    private static let uberSummaryRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*[•·\-]\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b"#,
        options: [.caseInsensitive]
    )
    // Multiplicadores de mapa ocioso da 99: "1,1 ~ 1,6x" ou "1,1X-1,6X"
    private static let idleSurgeBadgeRegex = try! NSRegularExpression(
        pattern: #"\d[.,]\d\s*(?:x\s*)?[~\-]\s*\d[.,]\d\s*x"#,
        options: [.caseInsensitive]
    )

    // MARK: - Ciclo de Vida do ReplayKit
    public override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        setupUDPConnection()
        sendPingStatus(status: "BROADCAST_STARTED")
    }

    public override func broadcastPaused() {
        sendPingStatus(status: "BROADCAST_PAUSED")
    }

    public override func broadcastResumed() {
        setupUDPConnection()
        sendPingStatus(status: "BROADCAST_RESUMED")
    }

    public override func broadcastFinished() {
        sendPingStatus(status: "BROADCAST_FINISHED")
        udpConnection?.cancel()
        udpConnection = nil
    }

    public override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = CACurrentMediaTime()

        if (now - lastHeartbeatTime) >= heartbeatInterval {
            lastHeartbeatTime = now
            sendPingStatus(status: "BROADCAST_ACTIVE")
        }

        let wallNow = Date().timeIntervalSince1970
        let isPendingAcceptCheck = !didSendAcceptedForLastOffer && lastValidOfferSeenTime > 0 && ((wallNow - lastValidOfferSeenTime) <= 35.0)
        let activeThrottle = isPendingAcceptCheck ? fastPostOfferThrottleInterval : normalThrottleInterval

        guard (now - lastProcessedTime) >= activeThrottle, !isProcessingFrame else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        lastProcessedTime = now
        isProcessingFrame = true

        let orientationRaw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? UInt32
        let cgOrientation = CGImagePropertyOrientation(rawValue: orientationRaw ?? CGImagePropertyOrientation.up.rawValue) ?? .up

        autoreleasepool {
            defer { isProcessingFrame = false }
            performFastOCR(on: pixelBuffer, orientation: cgOrientation, timestamp: wallNow)
        }
    }

    // MARK: - OCR de Baixa Latência com Proteção Anti-Histórico e Auto-Aceite Multi-Sinal
    private func performFastOCR(on pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, timestamp: TimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.010
        request.regionOfInterest = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.95)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observations = request.results, !observations.isEmpty else {
            checkAndClearStaleCard(now: timestamp)
            return
        }

        let sortedObservations = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        let cleanScreenLines: [String] = sortedObservations
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isSelfOverlayLine($0) }

        let allScreenText = cleanScreenLines.joined(separator: "\n")

        // BLOQUEIO SE O MOTORISTA ESTIVER DENTRO DO PRÓPRIO APP UBERPROFIT OU EM TELAS DE HISTÓRICO
        if isInsideOwnAppOrHistoryScreen(allScreenText) {
            checkAndClearStaleCard(now: timestamp)
            return
        }

        // Filtra linhas dos 75% inferiores da tela (onde ficam os cards de corrida) ignorando a janela PiP
        var cardLines: [RecognizedLine] = []
        for obs in sortedObservations {
            guard obs.boundingBox.midY <= 0.75,
                  let candidate = obs.topCandidates(1).first else { continue }
            let clean = candidate.string.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !isSelfOverlayLine(clean) else { continue }

            cardLines.append(
                RecognizedLine(
                    text: clean,
                    midY: obs.boundingBox.midY,
                    height: obs.boundingBox.height
                )
            )
        }

        guard !cardLines.isEmpty,
              let parsedPayload = parseRideCard(from: cardLines, timestamp: timestamp) else {
            checkIfOfferWasAcceptedOnScreen(
                allScreenText: allScreenText,
                cleanLines: cleanScreenLines,
                cardLines: cardLines,
                now: timestamp
            )
            checkAndClearStaleCard(now: timestamp)
            return
        }

        let offerHash = computeOfferHash(fare: parsedPayload.fareBRL, totalKm: parsedPayload.totalDistanceKm, totalMin: parsedPayload.totalMinutes)

        // Mantém o mesmo timestamp da oferta enquanto for o mesmo card na tela (evita mudar o ID da corrida)
        let effectivePayload: RideOfferPayload
        if offerHash == activeOfferHash, let existing = activeOfferPayload, (timestamp - lastValidOfferSeenTime) < 25.0 {
            effectivePayload = RideOfferPayload(
                appSource: parsedPayload.appSource,
                fareBRL: parsedPayload.fareBRL,
                pickupDistanceKm: parsedPayload.pickupDistanceKm,
                tripDistanceKm: parsedPayload.tripDistanceKm,
                totalDistanceKm: parsedPayload.totalDistanceKm,
                pickupMinutes: parsedPayload.pickupMinutes,
                tripMinutes: parsedPayload.tripMinutes,
                totalMinutes: parsedPayload.totalMinutes,
                rawRecognizedText: parsedPayload.rawRecognizedText,
                timestamp: existing.timestamp
            )
        } else {
            effectivePayload = parsedPayload
            activeOfferHash = offerHash
            activeOfferPickupStreet = extractPickupStreetToken(from: cardLines)
        }

        activeOfferPayload = effectivePayload
        lastValidOfferSeenTime = timestamp
        didSendClearCard = false
        didSendAcceptedForLastOffer = false
        acceptedHitCount = 0
        idleHitCount = 0

        pruneExpiredHashes(now: timestamp)

        if let lastSeen = recentOfferHashes[offerHash], (timestamp - lastSeen) < debounceInterval {
            return
        }

        recentOfferHashes[offerHash] = timestamp
        sendOfferViaUDP(effectivePayload)
    }

    // MARK: - Motor Multi-Sinal de Detecção de Corrida Aceita
    private func checkIfOfferWasAcceptedOnScreen(
        allScreenText: String,
        cleanLines: [String],
        cardLines: [RecognizedLine],
        now: TimeInterval
    ) {
        guard !didSendAcceptedForLastOffer,
              let pendingOffer = activeOfferPayload,
              lastValidOfferSeenTime > 0 else { return }

        let elapsed = now - lastValidOfferSeenTime
        guard elapsed >= 0.35 else { return }

        let upper = allScreenText.uppercased()
        let normalizedUpper = Self.stripDiacritics(upper)

        if elapsed > 35.0 {
            acceptedHitCount = 0
            idleHitCount = 0
            didSendAcceptedForLastOffer = true
            sendPingStatus(status: "RIDE_UNKNOWN")
            return
        }

        // Snapshot de diagnóstico (a cada 2,0s enquanto o desfecho está pendente)
        if (now - lastSnapshotTime) >= 2.0 {
            lastSnapshotTime = now
            let flat = upper.replacingOccurrences(of: "\n", with: " | ")
            sendTextStatus(status: "SCREEN_SNAPSHOT", text: String(flat.prefix(380)))
        }

        // 1. Verifica se o motorista está em outro app do iPhone (WhatsApp, Tela de Início, etc.)
        if isOtherNonDriverApp(normalizedUpper) {
            return
        }

        // 2. Verifica se voltou para a tela ociosa (radar "Buscando" da 99 ou "Você está online" da Uber)
        if isIdleRadarScreen(upper: upper, normalizedUpper: normalizedUpper, cleanLines: cleanLines) {
            acceptedHitCount = 0
            idleHitCount += 1
            if idleHitCount >= 2 && elapsed >= 1.8 {
                idleHitCount = 0
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                sendPingStatus(status: "RIDE_DECLINED")
            }
            return
        }

        // 3. Verifica se o preço principal do card de oferta ainda está visível (ex: card ainda fechando)
        let stillHasOfferPrice = extractMainFareBRL(from: cardLines) != nil
        if stillHasOfferPrice {
            return
        }

        // 4. SINAIS DE ACEITE (avaliados quando o card da oferta e o preço R$ já saíram da tela):
        var matchedReason: String? = nil
        var confidenceWeight: Int = 0

        // SINAL A (Alta Confiança — Frases exclusivas de corrida em andamento / embarque)
        let highConfidencePhrases: [(pattern: String, label: String)] = [
            ("INICIAR VIAGEM", "Iniciar viagem"),
            ("INICIAR CORRIDA", "Iniciar corrida"),
            ("INICIAR UBER", "Iniciar Uber"),
            ("IR PARA O EMBARQUE", "Ir para o embarque"),
            ("ATE O EMBARQUE", "Até o embarque"),
            ("LOCAL DE EMBARQUE", "Local de embarque"),
            ("PONTO DE EMBARQUE", "Ponto de embarque"),
            ("EMBARQUE DE ", "Embarque de passageiro"),
            ("EMBARQUE EM ", "Embarque em"),
            ("A CAMINHO D", "A caminho do passageiro"),
            ("CHEGUEI", "Botão Cheguei"),
            ("VOCE CHEGOU", "Você chegou"),
            ("DESLIZE PARA", "Deslize para iniciar/chegar"),
            ("AGUARDANDO PASSAGEIRO", "Aguardando passageiro"),
            ("BUSCAR PASSAGEIRO", "Buscar passageiro"),
            ("BUSCANDO PASSAGEIRO", "Buscando passageiro"),
            ("PEGAR PASSAGEIRO", "Pegar passageiro"),
            ("INDO BUSCAR", "Indo buscar"),
            ("INDO ATE", "Indo até passageiro"),
            ("ENCONTRAR COM", "Encontrar com passageiro"),
            ("ENCONTRO COM", "Encontro com passageiro"),
            ("FALAR COM PASSAGEIRO", "Falar com passageiro"),
            ("NOTIFICAR PASSAGEIRO", "Notificar passageiro"),
            ("LIGAR PARA PASSAGEIRO", "Ligar para passageiro"),
            ("CORRIDA ACEITA", "Corrida aceita"),
            ("VIAGEM ACEITA", "Viagem aceita"),
            ("CONECTANDO AO PASSAGEIRO", "Conectando ao passageiro"),
            ("CANCELAR VIAGEM", "Cancelar viagem"),
            ("CANCELAR CORRIDA", "Cancelar corrida")
        ]

        for item in highConfidencePhrases {
            if normalizedUpper.contains(item.pattern) {
                matchedReason = item.label
                confidenceWeight = 2 // Confirma imediatamente se já passou ≥0.7s, ou em 2 frames rápidos
                break
            }
        }

        // SINAL B (Média-Alta Confiança — Elementos de navegação ativa até o passageiro na 99/Uber/Waze/Maps)
        if matchedReason == nil {
            let navPhrases: [(pattern: String, label: String)] = [
                ("EMBARQUE", "Tela de embarque"),
                ("A CAMINHO", "A caminho"),
                ("NAVEGAR", "Botão Navegar ativo"),
                ("CHEGADA ", "Barra de chegada (ETA)"),
                ("CHEGADA:", "Barra de chegada (ETA)"),
                ("CHEGADA AS", "Chegada às"),
                ("CHEGADA EM", "Chegada em"),
                ("VIRE A DIREITA", "Navegação: Vire à direita"),
                ("VIRE A ESQUERDA", "Navegação: Vire à esquerda"),
                ("SIGA EM FRENTE", "Navegação: Siga em frente"),
                ("SIGA PELA", "Navegação: Siga pela via"),
                ("SIGA NA ", "Navegação: Siga na via"),
                ("MANTENHA-SE A", "Navegação: Mantenha-se"),
                ("PEGUE A SAIDA", "Navegação: Pegue a saída"),
                ("NA ROTATORIA", "Navegação: Rotatória"),
                ("RECENTRALIZAR", "Mapa em navegação"),
                ("KM/H", "Velocímetro de navegação")
            ]
            for item in navPhrases {
                if normalizedUpper.contains(item.pattern) {
                    matchedReason = item.label
                    confidenceWeight = 1
                    break
                }
            }
        }

        // SINAL C (Persistência do endereço de embarque da oferta na tela de navegação, sem preço R$)
        if matchedReason == nil && elapsed >= 0.8 && activeOfferPickupStreet.count >= 5 {
            if normalizedUpper.contains(activeOfferPickupStreet) {
                matchedReason = "Rota p/ endereço de embarque (\(activeOfferPickupStreet))"
                confidenceWeight = 1
            }
        }

        // SINAL D (Barra única de tempo/distância até o passageiro na tela de navegação, sem preço R$)
        if matchedReason == nil && elapsed >= 0.8 {
            let (_, _, totalKm, _, _, totalMin, stepCount) = extractStructuredSteps(from: allScreenText)
            if stepCount == 1 && totalKm > 0 && totalMin > 0 && totalMin <= max(pendingOffer.pickupMinutes + 6, 15) {
                matchedReason = "Barra de deslocamento até embarque (\(totalMin) min)"
                confidenceWeight = 1
            }
        }

        if let reason = matchedReason {
            idleHitCount = 0
            // Mesmo sinais de peso 2 exigem elapsed >= 0.7s ou 2 leituras para máxima segurança
            if confidenceWeight >= 2 && elapsed >= 0.75 {
                acceptedHitCount += 2
            } else {
                acceptedHitCount += 1
            }

            if acceptedHitCount >= 2 {
                acceptedHitCount = 0
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                sendAcceptedOfferViaUDP(pendingOffer, reason: reason)
            }
        }
    }

    private func isIdleRadarScreen(upper: String, normalizedUpper: String, cleanLines: [String]) -> Bool {
        if normalizedUpper.contains("VOCE ESTA ONLINE") ||
           normalizedUpper.contains("PROCURANDO VIAGENS") ||
           normalizedUpper.contains("PROCURANDO CORRIDAS") ||
           normalizedUpper.contains("BUSCANDO VIAGENS") ||
           normalizedUpper.contains("BUSCANDO CORRIDAS") ||
           normalizedUpper.contains("PROCURANDO SOLICITA") ||
           normalizedUpper.contains("SOLICITACOES") ||
           normalizedUpper.contains("FICAR ONLINE") ||
           normalizedUpper.contains("TOQUE PARA FICAR ONLINE") ||
           normalizedUpper.contains("VOCE ESTA OFFLINE") {
            return true
        }

        // Na 99 Motorista, a barra inferior da tela ociosa diz apenas "Buscando"
        for line in cleanLines {
            let norm = Self.stripDiacritics(line.uppercased())
            if norm == "BUSCANDO" || norm == "BUSCANDO..." || norm == "SOLICITACOES" {
                return true
            }
        }

        // Hexágonos de dinâmico do mapa ocioso da 99: "1,1 ~ 1,6x" ou "1,1X-1,6X"
        let nsRange = NSRange(upper.startIndex..<upper.endIndex, in: upper)
        if Self.idleSurgeBadgeRegex.firstMatch(in: upper, options: [], range: nsRange) != nil {
            return true
        }

        return false
    }

    private func isOtherNonDriverApp(_ normalizedUpper: String) -> Bool {
        return normalizedUpper.contains("WHATSAPP") ||
               normalizedUpper.contains("DIGITE UMA MENSAGEM") ||
               normalizedUpper.contains("INSTAGRAM") ||
               normalizedUpper.contains("TELEGRAM") ||
               normalizedUpper.contains("BUSCAR APPS") ||
               normalizedUpper.contains("BIBLIOTECA DE APPS")
    }

    /// Extrai o nome da rua/local de embarque (linha logo abaixo do 1º passo de tempo/distância do card)
    private func extractPickupStreetToken(from lines: [RecognizedLine]) -> String {
        for i in 0..<lines.count {
            let text = lines[i].text
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            let isStep = Self.stepOutsideParenRegex.firstMatch(in: text, options: [], range: nsRange) != nil ||
                         Self.stepInsideParenRegex.firstMatch(in: text, options: [], range: nsRange) != nil
            if isStep && (i + 1) < lines.count {
                let nextLine = lines[i + 1].text
                let nextNs = NSRange(nextLine.startIndex..<nextLine.endIndex, in: nextLine)
                let nextIsStep = Self.stepOutsideParenRegex.firstMatch(in: nextLine, options: [], range: nextNs) != nil ||
                                 Self.stepInsideParenRegex.firstMatch(in: nextLine, options: [], range: nextNs) != nil
                if !nextIsStep {
                    let beforeComma = nextLine.components(separatedBy: ",").first ?? nextLine
                    let cleaned = Self.stripDiacritics(beforeComma.uppercased())
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.count >= 5 && !cleaned.contains("PARADA") && !cleaned.contains("ACEITAR") {
                        return String(cleaned.prefix(28))
                    }
                }
                break
            }
        }
        return ""
    }

    private static func stripDiacritics(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
    }

    private func checkAndClearStaleCard(now: TimeInterval) {
        if !didSendClearCard && (now - lastValidOfferSeenTime) >= 7.0 {
            didSendClearCard = true
            sendPingStatus(status: "CLEAR_CARD")
        }
    }

    private func isInsideOwnAppOrHistoryScreen(_ screenText: String) -> Bool {
        let upper = Self.stripDiacritics(screenText.uppercased())

        // 1. Detecta a barra de abas ou títulos exclusivos do próprio UberProfitApp
        let hasOwnTabBar = upper.contains("PAINEL") && upper.contains("GANHOS") && upper.contains("AJUSTES")
        if hasOwnTabBar ||
           upper.contains("UBER & 99 PROFIT AUTO") ||
           upper.contains("METAS & CARRO") ||
           upper.contains("METAS DE LUCRATIVIDADE") ||
           upper.contains("FILTROS DE OFERTA") ||
           upper.contains("VEICULO E COMBUSTIVEL") ||
           upper.contains("MONITORAMENTO AO VIVO") ||
           upper.contains("LEITOR DESLIGADO") ||
           upper.contains("INICIAR LEITOR") ||
           upper.contains("PARAR LEITOR") ||
           upper.contains("TURNO ATUAL") ||
           upper.contains("ULTIMA OFERTA") ||
           upper.contains("OFERTAS LIDAS HOJE") ||
           upper.contains("OFERTAS REGISTRADAS") ||
           upper.contains("CORRIDAS ACEITAS") ||
           upper.contains("CORRIDAS DO TURNO") ||
           upper.contains("GANHOS DO TURNO") ||
           upper.contains("LUCRO LIVRE DO TURNO") ||
           upper.contains("LUCRO LIVRE NO BOLSO") ||
           upper.contains("LUCRO ACUMULADO") ||
           upper.contains("GASTOS EXTRAS DO DIA") ||
           upper.contains("LANCAR CORRIDA") ||
           upper.contains("REGISTRAR CORRIDA") ||
           upper.contains("TESTAR FUNCIONAMENTO") ||
           upper.contains("SIMULAR CORRIDA") ||
           upper.contains("SIMULAR OFERTA") ||
           upper.contains("DIAGNOSTICO OCR") ||
           upper.contains("CONSOLE DE DIAGNOSTICO") ||
           upper.contains("TEXTO LIDO DA TELA") ||
           upper.contains("2º PLANO SEMPRE ATIVO") {
            return true
        }

        // 2. Detecta telas de histórico de viagens passadas dentro da Uber ou da 99
        // (Nota: NÃO incluir "DETALHES DA VIAGEM" pois a Uber exibe isso na gaveta da corrida em andamento!)
        if upper.contains("HISTORICO DE VIAGENS") ||
           upper.contains("HISTORICO DE CORRIDAS") ||
           upper.contains("DETALHES DOS GANHOS") ||
           upper.contains("RESUMO DE GANHOS") {
            return true
        }

        return false
    }

    /// Linhas desenhadas pela própria janela PiP (card de análise, card de confirmação ou card de espera).
    private func isSelfOverlayLine(_ line: String) -> Bool {
        let upper = Self.stripDiacritics(line.uppercased())
        return upper.contains("PROFIT ATIVO") ||
               upper.contains("UBER & 99 PROFIT") ||
               upper.contains("UBERPROFIT") ||
               upper.contains("MONITORANDO OFERTAS") ||
               upper.contains("EM TEMPO REAL") ||
               upper.contains("SALVA NOS GANHOS") ||
               upper.contains("CORRIDA REGISTRADA") ||
               upper.contains("LUCRO R$") ||
               upper.contains("LUCRO LIVRE") ||
               upper.contains("COMB. -R$") ||
               upper.contains("COMB, -R$") ||
               upper.contains("COMB -R$") ||
               upper.contains("GASOLINA: -R$") ||
               upper.contains("KM TOTAL") ||
               upper.contains("TARIFA R$") ||
               upper.contains("• ACEITAR •") ||
               upper.contains("• RECUSAR •") ||
               upper.contains("• ATENCAO •") ||
               upper.contains("[UBER]") ||
               upper.contains("[99]")
    }

    // MARK: - Parser Rigoroso para Cards de Oferta Reais (Uber Driver + 99 Motorista)
    private func parseRideCard(from lines: [RecognizedLine], timestamp: TimeInterval) -> RideOfferPayload? {
        let fullText = lines.map(\.text).joined(separator: "\n")
        let lowerFull = fullText.lowercased()

        let isCollapsed99Drawer = lowerFull.contains("solicitações") || lowerFull.contains("solicitacoes") || lowerFull.contains("buscando")

        let is99Card = isCollapsed99Drawer ||
                       lowerFull.contains("99") ||
                       lowerFull.contains("pgto") ||
                       lowerFull.contains("tarifa base") ||
                       lowerFull.contains("cpf verif") ||
                       lowerFull.contains("perfil premium") ||
                       lowerFull.contains("perfil essencial") ||
                       lowerFull.contains("corridas") ||
                       lowerFull.contains("negocia") ||
                       lowerFull.contains("poupa")

        let appSource = is99Card ? "99" : "UBER"

        // 1. Extrai a Tarifa Principal em Reais
        guard let fare = extractMainFareBRL(from: lines), fare >= 4.5, fare <= 950.0 else {
            return nil
        }

        // 2. Extrai Distâncias e Tempos exigindo formato estruturado de card de oferta
        let (pickupKm, tripKm, totalKm, pickupMin, tripMin, totalMin, stepCount) = extractStructuredSteps(from: fullText)

        // Na 99, TODO card de corrida possui 2 passos obrigatórios (busca do passageiro + viagem até o destino).
        if is99Card && stepCount < 2 {
            return nil
        }

        guard totalKm >= 0.4, totalMin >= 1 else {
            return nil
        }

        return RideOfferPayload(
            appSource: appSource,
            fareBRL: fare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: totalKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: totalMin,
            rawRecognizedText: fullText,
            timestamp: timestamp
        )
    }

    private func extractMainFareBRL(from lines: [RecognizedLine]) -> Double? {
        let fullJoined = lines.map(\.text).joined(separator: "\n")
        let fullNsRange = NSRange(fullJoined.startIndex..<fullJoined.endIndex, in: fullJoined)

        // 1. Se for 99 Negocia com o botão "Aceitar por R$ 8,14", essa é 100% a tarifa oficial da oferta
        if let match = Self.acceptButtonPriceRegex.firstMatch(in: fullJoined, options: [], range: fullNsRange),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: fullJoined) {
            let rawValue = fullJoined[range].replacingOccurrences(of: ",", with: ".")
            if let value = Double(rawValue), value >= 4.5, value <= 950.0 {
                return value
            }
        }

        var candidates: [(value: Double, height: CGFloat, midY: CGFloat)] = []

        for line in lines {
            let lower = line.text.lowercased()
            if lower.contains("incluíd") ||
               lower.contains("incluid") ||
               lower.contains("incl.") ||
               lower.contains("tarifa base") ||
               lower.contains("dinâmica") ||
               lower.contains("dinamica") ||
               lower.contains("prioritária") ||
               lower.contains("prioritaria") ||
               lower.contains("est. de") ||
               lower.contains("/km") ||
               lower.contains("/h") ||
               lower.contains("lucro") ||
               lower.contains("comb") {
                continue
            }

            let nsRange = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
            let matches = Self.priceRegex.matches(in: line.text, options: [], range: nsRange)

            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: line.text) else { continue }
                let rawValue = line.text[range].replacingOccurrences(of: ",", with: ".")
                if let value = Double(rawValue), value >= 4.5, value <= 950.0 {
                    candidates.append((value: value, height: line.height, midY: line.midY))
                }
            }
        }

        guard !candidates.isEmpty else { return nil }

        let maxHeight = candidates.map(\.height).max() ?? 0
        let prominent = candidates.filter { $0.height >= maxHeight * 0.70 }

        if let topProminent = prominent.max(by: { $0.midY < $1.midY }) {
            return topProminent.value
        }

        return candidates.max(by: { $0.height < $1.height })?.value
    }

    private func extractStructuredSteps(from fullText: String) -> (Double, Double, Double, Int, Int, Int, Int) {
        let nsFullRange = NSRange(fullText.startIndex..<fullText.endIndex, in: fullText)

        var summaryResult: (min: Int, km: Double)? = nil
        if let match = Self.uberSummaryRegex.firstMatch(in: fullText, options: [], range: nsFullRange) {
            var hours = 0
            if let hRange = Range(match.range(at: 1), in: fullText), let h = Int(fullText[hRange]) {
                hours = h
            }
            if let mRange = Range(match.range(at: 2), in: fullText),
               let mins = Int(fullText[mRange]),
               let dRange = Range(match.range(at: 3), in: fullText),
               let uRange = Range(match.range(at: 4), in: fullText),
               let distVal = Double(fullText[dRange].replacingOccurrences(of: ",", with: ".")) {
                let unit = fullText[uRange].lowercased()
                let km = (unit == "m") ? (distVal / 1000.0) : distVal
                let totalMins = (hours * 60) + mins
                if km > 0 && totalMins > 0 {
                    summaryResult = (min: totalMins, km: km)
                }
            }
        }

        var steps: [(min: Int, km: Double)] = []

        for regex in [Self.stepOutsideParenRegex, Self.stepInsideParenRegex] {
            let matches = regex.matches(in: fullText, options: [], range: nsFullRange)
            for match in matches {
                var hours = 0
                if let hRange = Range(match.range(at: 1), in: fullText), let h = Int(fullText[hRange]) {
                    hours = h
                }
                guard let mRange = Range(match.range(at: 2), in: fullText),
                      let mins = Int(fullText[mRange]),
                      let dRange = Range(match.range(at: 3), in: fullText),
                      let uRange = Range(match.range(at: 4), in: fullText),
                      let distVal = Double(fullText[dRange].replacingOccurrences(of: ",", with: ".")) else { continue }

                let unit = fullText[uRange].lowercased()
                let distKm = (unit == "m") ? (distVal / 1000.0) : distVal
                let totalMins = (hours * 60) + mins

                if distKm > 0 && totalMins > 0 {
                    steps.append((min: totalMins, km: distKm))
                }
            }
        }

        if steps.count >= 2 {
            let pKm = steps[0].km
            let tKm = steps[1].km
            let pMin = steps[0].min
            let tMin = steps[1].min
            let sumKm = pKm + tKm
            let sumMin = pMin + tMin

            if let summary = summaryResult, summary.km > sumKm {
                return (pKm, summary.km - pKm, summary.km, pMin, max(summary.min - pMin, 1), summary.min, 2)
            }
            return (pKm, tKm, sumKm, pMin, tMin, sumMin, 2)
        }

        if let summary = summaryResult {
            if let firstStep = steps.first, summary.km > firstStep.km {
                let tripKm = summary.km - firstStep.km
                let tripMin = max(summary.min - firstStep.min, 1)
                return (firstStep.km, tripKm, summary.km, firstStep.min, tripMin, summary.min, 2)
            }
            return (0.0, summary.km, summary.km, 0, summary.min, summary.min, 1)
        }

        if let onlyStep = steps.first {
            return (0.0, onlyStep.km, onlyStep.km, 0, onlyStep.min, onlyStep.min, 1)
        }

        return (0, 0, 0, 0, 0, 0, 0)
    }

    // MARK: - Debouncing
    private func computeOfferHash(fare: Double, totalKm: Double, totalMin: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(Int((fare * 100).rounded()))
        hasher.combine(Int((totalKm * 10).rounded()))
        hasher.combine(totalMin)
        return hasher.finalize()
    }

    private func pruneExpiredHashes(now: TimeInterval) {
        recentOfferHashes = recentOfferHashes.filter { (_, timestamp) in
            (now - timestamp) < debounceInterval
        }
    }

    // MARK: - Envio UDP Local (127.0.0.1:9876) com Auto-Reconexão e Burst 3x para Aceite
    private func setupUDPConnection() {
        udpConnection?.cancel()
        let connection = NWConnection(host: udpHost, port: udpPort, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.udpConnection = nil
            default:
                break
            }
        }
        connection.start(queue: processingQueue)
        self.udpConnection = connection
    }

    private func sendRawUDP(_ data: Data) {
        if udpConnection == nil {
            setupUDPConnection()
        }
        udpConnection?.send(content: data, completion: .contentProcessed({ [weak self] error in
            if error != nil {
                self?.setupUDPConnection()
                self?.udpConnection?.send(content: data, completion: .contentProcessed({ _ in }))
            }
        }))
    }

    private func sendOfferViaUDP(_ payload: RideOfferPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        sendRawUDP(data)
    }

    /// Envia o evento de corrida aceita com o payload completo embutido em 3 disparos (0s, 0.45s, 1.1s)
    /// para garantir entrega absoluta mesmo durante transição de tela.
    private func sendAcceptedOfferViaUDP(_ offer: RideOfferPayload, reason: String) {
        let packet = AcceptedRideEventPayload(status: "RIDE_ACCEPTED", triggerReason: reason, offer: offer)
        guard let data = try? JSONEncoder().encode(packet) else {
            sendPingStatus(status: "RIDE_ACCEPTED")
            return
        }
        sendRawUDP(data)
        processingQueue.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.sendRawUDP(data)
        }
        processingQueue.asyncAfter(deadline: .now() + 1.10) { [weak self] in
            self?.sendRawUDP(data)
        }
    }

    private func sendTextStatus(status: String, text: String) {
        let packet: [String: String] = ["status": status, "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: packet, options: []) else { return }
        sendRawUDP(data)
    }

    private func sendPingStatus(status: String) {
        let packet: [String: String] = ["status": status]
        guard let data = try? JSONSerialization.data(withJSONObject: packet, options: []) else { return }
        sendRawUDP(data)
    }
}
