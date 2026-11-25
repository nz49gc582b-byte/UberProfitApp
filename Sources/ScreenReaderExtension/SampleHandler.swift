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

/// Pacote de confirmação de corrida aceita (ou correção pós-zoom do GPS em listas)
public struct AcceptedRideEventPayload: Codable, Sendable {
    public let status: String // "RIDE_ACCEPTED" ou "RIDE_ACCEPTED_CORRECTION"
    public let triggerReason: String
    public let offer: RideOfferPayload
    public let previousOfferTimestamp: TimeInterval?
}

private struct RecognizedLine {
    let text: String
    let midY: CGFloat
    let height: CGFloat
}

/// Candidato rastreado (suporta múltiplas corridas vistas na Lista de Solicitações / Carrossel da 99)
private struct TrackedOfferCandidate {
    var payload: RideOfferPayload
    let hash: Int
    let pickupStreet: String
    let pickupKeywords: [String]
    let destKeywords: [String]
    let firstSeenTime: TimeInterval
    var lastSeenTime: TimeInterval
    var seenFrameCount: Int
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

    // Pool de candidatos recentes (permite saber QUAL corrida da Lista de Solicitações foi aceita)
    private var candidatePool: [TrackedOfferCandidate] = []
    private var activeOfferPayload: RideOfferPayload?
    private var activeOfferHash: Int = 0

    // Verificação pós-aceite (corrige caso uma corrida da lista tenha sido registrada antes da placa da rua aparecer no GPS)
    private var lastAcceptedCandidateHash: Int = 0
    private var lastAcceptedTimestamp: TimeInterval = 0
    private var lastAcceptedOfferTimestamp: TimeInterval = 0

    // Controle de "Corrida Encaixada" (quando o motorista JÁ está em uma corrida e toca outra perto do destino)
    private var isDriverCurrentlyOnTrip: Bool = false
    private var wasInActiveTripWhenOfferArrived: Bool = false
    private var didFinishPreviousTripAfterOffer: Bool = false
    private var preOfferScreenSnapshot: String = ""

    private var udpConnection: NWConnection?
    private let processingQueue = DispatchQueue(label: "com.uberprofit.screenreader.vision", qos: .userInteractive)

    // MARK: - Regex Pré-Compiladas (Uber Driver + 99 Motorista)
    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\+)(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))(?!\s*/)"#,
        options: [.caseInsensitive]
    )
    private static let acceptButtonPriceRegex = try! NSRegularExpression(
        pattern: #"Aceitar\s+por\s+(?:R\s*\$|RS)\s*(\d{1,3}(?:[.,]\d{2}))"#,
        options: [.caseInsensitive]
    )
    // Formato Uber e 99 Pop tradicional: "3 min (0.8 km)" ou "8 min (3,2 km)"
    private static let stepOutsideParenRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*\(\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Formato 99 Lista de Solicitações / Radar: "(3 min 1 km)" ou "(7 min 2,8 km)"
    private static let stepInsideParenRegex = try! NSRegularExpression(
        pattern: #"\(\s*(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s+(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\s*\)"#,
        options: [.caseInsensitive]
    )
    // Linha de resumo da Uber ou barra de navegação pós-aceite: "15 min • 5.4 km"
    private static let uberSummaryRegex = try! NSRegularExpression(
        pattern: #"(?:(\d{1,2})\s*h(?:oras?)?\s*)?(\d{1,3})\s*min(?:utos?)?\s*[•·\-]\s*(\d{1,3}(?:[.,]\d{1,2})?)\s*(km|m)\b"#,
        options: [.caseInsensitive]
    )
    // Multiplicadores de mapa ocioso da 99: "1,1 ~ 1,6x" ou "1,1X-1,6X"
    private static let idleSurgeBadgeRegex = try! NSRegularExpression(
        pattern: #"\d[.,]\d\s*(?:x\s*)?[~\-]\s*\d[.,]\d\s*x"#,
        options: [.caseInsensitive]
    )
    // Marcador exclusivo de card de oferta/lista da 99: "42 corridas", "+999 corridas", "114 corridas"
    private static let passengerRidesCountRegex = try! NSRegularExpression(
        pattern: #"\+?\d{1,4}\s+corridas\b"#,
        options: [.caseInsensitive]
    )
    // Marcador exclusivo de card de oferta: "R$ 1,25/km" ou "R$2,37/km"
    private static let cardRatePerKmRegex = try! NSRegularExpression(
        pattern: #"(?:R\s*\$|RS)\s*\d{1,2}[.,]\d{2}\s*/\s*km"#,
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
        let pendingTimeout: TimeInterval = wasInActiveTripWhenOfferArrived ? 240.0 : 35.0
        let isPendingAcceptCheck = !didSendAcceptedForLastOffer && lastValidOfferSeenTime > 0 && ((wallNow - lastValidOfferSeenTime) <= pendingTimeout)
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

    // MARK: - OCR de Baixa Latência com Suporte a Lista de Corridas e Anti-"Outro Motorista"
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
        let normalizedAll = Self.stripDiacritics(allScreenText.uppercased())

        // BLOQUEIO SE O MOTORISTA ESTIVER DENTRO DO PRÓPRIO APP UBERPROFIT OU EM TELAS DE HISTÓRICO
        if isInsideOwnAppOrHistoryScreen(allScreenText) {
            checkAndClearStaleCard(now: timestamp)
            return
        }

        // TRAVA IMEDIATA: Se apareceu "Esta corrida foi aceita por outro motorista" ou indisponível/expirada!
        if isOfferTakenByAnotherDriverOrUnavailable(normalizedAll) {
            acceptedHitCount = 0
            // Remove do pool o último card que estava em foco pois outro motorista pegou
            if let activeHash = activeOfferPayload.map({ computeOfferHash(fare: $0.fareBRL, totalKm: $0.totalDistanceKm, totalMin: $0.totalMinutes) }) {
                candidatePool.removeAll { $0.hash == activeHash }
            }
            if candidatePool.isEmpty {
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                sendPingStatus(status: "RIDE_DECLINED")
            }
            return
        }

        // Filtra linhas dos 82% inferiores da tela (suporta tanto card único quanto Lista de Solicitações)
        var cardLines: [RecognizedLine] = []
        for obs in sortedObservations {
            guard obs.boundingBox.midY <= 0.82,
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

        // Extrai TODOS os cards válidos visíveis na tela (1 card no modo normal, ou 2-3 cards no modo Lista da 99)
        let parsedCards = parseAllRideCardsOnScreen(from: cardLines, allScreenText: allScreenText, timestamp: timestamp)

        guard !parsedCards.isEmpty else {
            // Se já aceitou uma corrida nos últimos 12s a partir de uma lista, confere se a placa da rua no GPS confirma outro card da lista
            verifyRecentListAcceptAgainstGPSScreen(normalizedUpper: normalizedAll, now: timestamp)

            checkIfOfferWasAcceptedOnScreen(
                allScreenText: allScreenText,
                cleanLines: cleanScreenLines,
                cardLines: cardLines,
                now: timestamp
            )
            checkAndClearStaleCard(now: timestamp)
            return
        }

        // Limpa candidatos antigos (> 35s) do pool
        candidatePool.removeAll { (timestamp - $0.lastSeenTime) > 35.0 }

        let hasTopNavWhileCardOpen =
            normalizedAll.contains("PROXIMA CORRIDA") ||
            normalizedAll.contains("PROXIMA VIAGEM") ||
            normalizedAll.contains("VIAGEM ATUAL") ||
            normalizedAll.contains("CORRIDA ATUAL") ||
            normalizedAll.contains("VIRE A DIREITA") ||
            normalizedAll.contains("VIRE A ESQUERDA") ||
            normalizedAll.contains("SIGA EM FRENTE") ||
            normalizedAll.contains("SIGA PELA")

        if didSendAcceptedForLastOffer {
            wasInActiveTripWhenOfferArrived = isDriverCurrentlyOnTrip || hasTopNavWhileCardOpen
            didFinishPreviousTripAfterOffer = false
        }

        // Atualiza o pool de candidatos com cada card visível na tela (sem misturar dados entre cards!)
        var primaryCandidate: TrackedOfferCandidate? = nil

        for card in parsedCards {
            let hash = computeOfferHash(fare: card.payload.fareBRL, totalKm: card.payload.totalDistanceKm, totalMin: card.payload.totalMinutes)
            if let idx = candidatePool.firstIndex(where: { $0.hash == hash }) {
                var existing = candidatePool[idx]
                existing.lastSeenTime = timestamp
                existing.seenFrameCount += 1
                // Preserva o timestamp original para manter o mesmo ID
                existing.payload = RideOfferPayload(
                    appSource: card.payload.appSource,
                    fareBRL: card.payload.fareBRL,
                    pickupDistanceKm: card.payload.pickupDistanceKm,
                    tripDistanceKm: card.payload.tripDistanceKm,
                    totalDistanceKm: card.payload.totalDistanceKm,
                    pickupMinutes: card.payload.pickupMinutes,
                    tripMinutes: card.payload.tripMinutes,
                    totalMinutes: card.payload.totalMinutes,
                    rawRecognizedText: card.payload.rawRecognizedText,
                    timestamp: existing.payload.timestamp
                )
                candidatePool[idx] = existing
                if primaryCandidate == nil { primaryCandidate = existing }
            } else {
                let newEntry = TrackedOfferCandidate(
                    payload: card.payload,
                    hash: hash,
                    pickupStreet: card.pickupStreet,
                    pickupKeywords: card.pickupKeywords,
                    destKeywords: card.destKeywords,
                    firstSeenTime: timestamp,
                    lastSeenTime: timestamp,
                    seenFrameCount: 1
                )
                candidatePool.append(newEntry)
                if primaryCandidate == nil { primaryCandidate = newEntry }
            }
        }

        guard let chosenPrimary = primaryCandidate else { return }

        activeOfferPayload = chosenPrimary.payload
        activeOfferHash = chosenPrimary.hash
        lastValidOfferSeenTime = timestamp
        didSendClearCard = false
        didSendAcceptedForLastOffer = false
        acceptedHitCount = 0
        idleHitCount = 0

        pruneExpiredHashes(now: timestamp)

        // Envia cada card novo visível na lista (ou reenvia o principal a cada 2.2s para manter o PiP atualizado)
        for card in parsedCards {
            let hash = computeOfferHash(fare: card.payload.fareBRL, totalKm: card.payload.totalDistanceKm, totalMin: card.payload.totalMinutes)
            if let poolItem = candidatePool.first(where: { $0.hash == hash }) {
                if let lastSeen = recentOfferHashes[hash], (timestamp - lastSeen) < debounceInterval {
                    continue
                }
                recentOfferHashes[hash] = timestamp
                sendOfferViaUDP(poolItem.payload)
            }
        }
    }

    // MARK: - Fatiamento Espacial de Cards (Suporta Card Único e Lista Vertical de Solicitações da 99)
    private struct ParsedCardBlock {
        let payload: RideOfferPayload
        let pickupStreet: String
        let pickupKeywords: [String]
        let destKeywords: [String]
    }

    private func parseAllRideCardsOnScreen(
        from lines: [RecognizedLine],
        allScreenText: String,
        timestamp: TimeInterval
    ) -> [ParsedCardBlock] {
        let lowerAll = allScreenText.lowercased()
        let is99Screen = lowerAll.contains("99") ||
                         lowerAll.contains("solicitações") ||
                         lowerAll.contains("solicitacoes") ||
                         lowerAll.contains("buscando") ||
                         lowerAll.contains("pgto") ||
                         lowerAll.contains("tarifa base") ||
                         lowerAll.contains("cpf verif") ||
                         lowerAll.contains("perfil premium") ||
                         lowerAll.contains("perfil essencial") ||
                         lowerAll.contains("pop nova") ||
                         lowerAll.contains("corridas") ||
                         lowerAll.contains("negocia") ||
                         lowerAll.contains("poupa")

        // 1. Tenta fatiar a tela em blocos iniciados por cada linha de preço principal (ideal para a Lista da 99)
        var fareLineIndices: [(index: Int, fare: Double)] = []
        for (i, line) in lines.enumerated() {
            if let fare = extractFareFromSingleLine(line) {
                // Evita duplicar se duas linhas muito próximas (< 0.03 de midY) tiverem o mesmo valor
                if let last = fareLineIndices.last,
                   abs(lines[last.index].midY - line.midY) < 0.035,
                   abs(last.fare - fare) < 0.05 {
                    continue
                }
                fareLineIndices.append((index: i, fare: fare))
            }
        }

        var results: [ParsedCardBlock] = []

        if fareLineIndices.count >= 2 {
            // MODO LISTA (2 ou mais preços de corridas empilhados na tela):
            // Cada bloco vai da linha do preço atual até a linha anterior ao próximo preço!
            for k in 0..<fareLineIndices.count {
                let startIdx = fareLineIndices[k].index
                let endIdx = (k + 1 < fareLineIndices.count) ? (fareLineIndices[k + 1].index - 1) : (lines.count - 1)
                guard startIdx <= endIdx else { continue }
                let slice = Array(lines[startIdx...endIdx])
                if let block = buildCardBlock(from: slice, explicitFare: fareLineIndices[k].fare, force99: is99Screen, timestamp: timestamp) {
                    results.append(block)
                }
            }
            if !results.isEmpty {
                return results
            }
        }

        // 2. Fallback: Card Único na tela
        if let singleFare = extractMainFareBRL(from: lines),
           let block = buildCardBlock(from: lines, explicitFare: singleFare, force99: is99Screen, timestamp: timestamp) {
            return [block]
        }

        return []
    }

    private func extractFareFromSingleLine(_ line: RecognizedLine) -> Double? {
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
           lower.contains("aceitar por") ||
           lower.contains("/km") ||
           lower.contains("/h") ||
           lower.contains("lucro") ||
           lower.contains("comb") {
            return nil
        }

        let nsRange = NSRange(line.text.startIndex..<line.text.endIndex, in: line.text)
        let matches = Self.priceRegex.matches(in: line.text, options: [], range: nsRange)
        // Ignora a fileira de botões de contraproposta do rodapé da 99 Negocia (que tem 2 ou 3 preços na mesma linha)
        if matches.count > 1 { return nil }

        guard let match = matches.first,
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: line.text) else { return nil }
        let rawValue = line.text[range].replacingOccurrences(of: ",", with: ".")
        guard let value = Double(rawValue), value >= 4.5, value <= 950.0 else { return nil }
        return value
    }

    private func buildCardBlock(
        from sliceLines: [RecognizedLine],
        explicitFare: Double,
        force99: Bool,
        timestamp: TimeInterval
    ) -> ParsedCardBlock? {
        let sliceText = sliceLines.map(\.text).joined(separator: "\n")
        let lowerSlice = sliceText.lowercased()
        let is99 = force99 || lowerSlice.contains("99") || lowerSlice.contains("negocia") || lowerSlice.contains("pop") || lowerSlice.contains("corridas")
        let appSource = is99 ? "99" : "UBER"

        let (pickupKm, tripKm, totalKm, pickupMin, tripMin, totalMin, stepCount) = extractStructuredSteps(from: sliceText)

        // Na 99, cada card individual precisa ter os 2 passos (embarque + destino) dentro da sua própria fatia!
        if is99 && stepCount < 2 {
            return nil
        }
        guard totalKm >= 0.4, totalMin >= 1 else {
            return nil
        }

        let (pickupStreet, pickupKw, destKw) = extractAddressTokens(from: sliceLines)

        let payload = RideOfferPayload(
            appSource: appSource,
            fareBRL: explicitFare,
            pickupDistanceKm: pickupKm,
            tripDistanceKm: tripKm,
            totalDistanceKm: totalKm,
            pickupMinutes: pickupMin,
            tripMinutes: tripMin,
            totalMinutes: totalMin,
            rawRecognizedText: sliceText,
            timestamp: timestamp
        )

        return ParsedCardBlock(
            payload: payload,
            pickupStreet: pickupStreet,
            pickupKeywords: pickupKw,
            destKeywords: destKw
        )
    }

    // MARK: - Motor Multi-Sinal de Detecção de Corrida Aceita (Com Filtro Anti-Lista e Seleção Inteligente do Pool)
    private func checkIfOfferWasAcceptedOnScreen(
        allScreenText: String,
        cleanLines: [String],
        cardLines: [RecognizedLine],
        now: TimeInterval
    ) {
        let upper = allScreenText.uppercased()
        let normalizedUpper = Self.stripDiacritics(upper)
        let isIdle = isIdleRadarScreen(upper: upper, normalizedUpper: normalizedUpper, cleanLines: cleanLines)

        // Quando não há oferta pendente, monitora continuamente se o motorista está livre ou em corrida ativa
        if didSendAcceptedForLastOffer || candidatePool.isEmpty || lastValidOfferSeenTime <= 0 {
            if isIdle {
                isDriverCurrentlyOnTrip = false
                preOfferScreenSnapshot = ""
            } else if hasActiveTripOrNavigationIndicators(normalizedUpper) {
                isDriverCurrentlyOnTrip = true
                preOfferScreenSnapshot = normalizedUpper
            }
            return
        }

        let elapsed = now - lastValidOfferSeenTime
        guard elapsed >= 0.35 else { return }

        let maxWindow: TimeInterval = wasInActiveTripWhenOfferArrived ? 240.0 : 35.0
        if elapsed > maxWindow {
            acceptedHitCount = 0
            idleHitCount = 0
            candidatePool.removeAll()
            didSendAcceptedForLastOffer = true
            sendPingStatus(status: "RIDE_UNKNOWN")
            return
        }

        // Snapshot de diagnóstico (a cada 2,0s nos primeiros 35s)
        if elapsed <= 35.0 && (now - lastSnapshotTime) >= 2.0 {
            lastSnapshotTime = now
            let modeTag = wasInActiveTripWhenOfferArrived ? "[ENCAIXADA]" : (candidatePool.count > 1 ? "[LISTA:\(candidatePool.count)]" : "[LIVRE]")
            let flat = upper.replacingOccurrences(of: "\n", with: " | ")
            sendTextStatus(status: "SCREEN_SNAPSHOT", text: "\(modeTag) " + String(flat.prefix(360)))
        }

        // 1. Verifica se o motorista está em outro app do iPhone (WhatsApp, Tela de Início, etc.)
        if isOtherNonDriverApp(normalizedUpper) {
            return
        }

        // 2. Verifica se apareceu "aceita por outro motorista" ou indisponível
        if isOfferTakenByAnotherDriverOrUnavailable(normalizedUpper) {
            acceptedHitCount = 0
            return
        }

        // 3. TRAVA ANTI-CARD E ANTI-LISTA DE SOLICITAÇÕES:
        // Enquanto ainda houver QUALQUER resquício de card de oferta ou da aba/lista de Solicitações na tela
        // (ex: "42 corridas", "+999 corridas", "R$ 1,25/km", "Pop Nova", "(7 min 2,8 km)", "Perfil Essencial/Premium", "CPF verif"),
        // o motorista AINDA está olhando o card/lista (ou um card escurecido) e NÃO entrou na tela de viagem!
        if hasOfferCardOrListRemnants(upper: upper, normalizedUpper: normalizedUpper, cardLines: cardLines) {
            acceptedHitCount = 0
            return
        }

        // 4. Verifica se voltou para a tela ociosa (radar "Buscando" da 99 ou "Você está online" da Uber)
        if isIdle {
            acceptedHitCount = 0
            idleHitCount += 1
            if idleHitCount >= 2 && elapsed >= 1.8 {
                idleHitCount = 0
                isDriverCurrentlyOnTrip = false
                preOfferScreenSnapshot = ""
                candidatePool.removeAll()
                didSendAcceptedForLastOffer = true
                didSendClearCard = true
                sendPingStatus(status: "RIDE_DECLINED")
            }
            return
        }

        // 5. Se a oferta tocou durante uma corrida já em andamento, verifica se o motorista está encerrando a corrida anterior
        if wasInActiveTripWhenOfferArrived {
            let isFinishingPreviousTripScreen =
                normalizedUpper.contains("FINALIZAR CORRIDA") ||
                normalizedUpper.contains("FINALIZAR VIAGEM") ||
                normalizedUpper.contains("CONCLUIR VIAGEM") ||
                normalizedUpper.contains("CONCLUIR CORRIDA") ||
                normalizedUpper.contains("ENCERRAR CORRIDA") ||
                normalizedUpper.contains("RECEBER DINHEIRO") ||
                normalizedUpper.contains("VALOR A COBRAR") ||
                normalizedUpper.contains("CONFIRMAR PAGAMENTO") ||
                normalizedUpper.contains("AVALIE O PASSAGEIRO") ||
                normalizedUpper.contains("AVALIAR PASSAGEIRO") ||
                normalizedUpper.contains("COMO FOI A VIAGEM") ||
                normalizedUpper.contains("COMO FOI A CORRIDA")

            if isFinishingPreviousTripScreen {
                didFinishPreviousTripAfterOffer = true
                acceptedHitCount = 0
                return
            }
        }

        let isStillOnPreviousTrip = wasInActiveTripWhenOfferArrived && !didFinishPreviousTripAfterOffer

        var matchedReason: String? = nil
        var confidenceWeight: Int = 0

        if isStillOnPreviousTrip {
            // MODO CORRIDA ENCAIXADA (Corrida 1 ainda em andamento)
            let stackedConfirmPhrases: [(pattern: String, label: String)] = [
                ("CORRIDA ACEITA", "Corrida encaixada aceita"),
                ("VIAGEM ACEITA", "Viagem encaixada aceita"),
                ("PROXIMA CORRIDA", "Próxima corrida na fila"),
                ("PROXIMA VIAGEM", "Próxima viagem na fila"),
                ("ADICIONADA A FILA", "Corrida adicionada à fila"),
                ("CORRIDA NA FILA", "Corrida na fila")
            ]
            for item in stackedConfirmPhrases {
                if normalizedUpper.contains(item.pattern) {
                    matchedReason = item.label
                    confidenceWeight = 2
                    break
                }
            }

            if matchedReason == nil && elapsed >= 1.2 {
                for candidate in candidatePool where candidate.pickupStreet.count >= 6 {
                    let wasAlreadyOnScreenInRide1 = preOfferScreenSnapshot.contains(candidate.pickupStreet)
                    if !wasAlreadyOnScreenInRide1 && normalizedUpper.contains(candidate.pickupStreet) {
                        matchedReason = "Novo embarque encaixado (\(candidate.pickupStreet))"
                        confidenceWeight = 1
                        break
                    }
                }
            }
        } else {
            // MODO LIVRE (ou após a Corrida 1 já ter sido finalizada):
            // Exige elementos reais da tela de embarque/navegação (Sinal A ou Sinal B).
            // Nota: Endereço ou tempo isolados NÃO disparam sozinhos sem um elemento de navegação/viagem!

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
                    confidenceWeight = 2
                    break
                }
            }

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
        }

        guard let reason = matchedReason else { return }

        idleHitCount = 0
        if confidenceWeight >= 2 && elapsed >= 0.75 {
            acceptedHitCount += 2
        } else {
            acceptedHitCount += 1
        }

        guard acceptedHitCount >= 2 else { return }

        // SELEÇÃO INTELIGENTE DO POOL:
        // Se havia 2+ corridas no pool (o motorista estava na Lista de Solicitações),
        // identifica QUAL das corridas da lista corresponde à tela de navegação aberta!
        let (bestCandidate, matchDetail, hasDirectScreenMatch) = selectBestMatchingCandidate(
            from: candidatePool,
            normalizedScreen: normalizedUpper,
            rawScreen: allScreenText,
            now: now
        )

        // Se havia múltiplas corridas na lista e a tela de GPS ainda está dando zoom (< 3.2s) sem mostrar a rua ou o tempo da corrida escolhida,
        // aguarda mais alguns frames até a rua/tempo aparecer no GPS para não pegar uma corrida nova que entrou na lista no último segundo!
        if candidatePool.count >= 2 && !hasDirectScreenMatch && elapsed < 3.2 {
            return
        }

        guard let winner = bestCandidate ?? activeOfferPayload.map({
            TrackedOfferCandidate(payload: $0, hash: activeOfferHash, pickupStreet: "", pickupKeywords: [], destKeywords: [], firstSeenTime: now, lastSeenTime: now, seenFrameCount: 1)
        }) else { return }

        acceptedHitCount = 0
        isDriverCurrentlyOnTrip = true
        preOfferScreenSnapshot = normalizedUpper
        didSendAcceptedForLastOffer = true
        didSendClearCard = true

        lastAcceptedCandidateHash = winner.hash
        lastAcceptedTimestamp = now
        lastAcceptedOfferTimestamp = winner.payload.timestamp

        let fullReason = matchDetail.isEmpty ? reason : "\(reason) • \(matchDetail)"
        sendAcceptedOfferViaUDP(winner.payload, reason: fullReason)
    }

    /// Escolhe qual corrida do pool (lista de solicitações) foi realmente aceita cruzando rua de embarque, tempo/km de busca e tempo de foco
    private func selectBestMatchingCandidate(
        from pool: [TrackedOfferCandidate],
        normalizedScreen: String,
        rawScreen: String,
        now: TimeInterval
    ) -> (candidate: TrackedOfferCandidate?, detail: String, hasDirectMatch: Bool) {
        guard !pool.isEmpty else { return (nil, "", false) }
        if pool.count == 1 {
            return (pool[0], "", true)
        }

        let (_, _, navKm, _, _, navMin, stepCount) = extractStructuredSteps(from: rawScreen)

        var bestScore: Int = Int.min
        var bestCandidate: TrackedOfferCandidate = pool[0]
        var bestDetail: String = ""
        var anyDirectMatch = false

        for candidate in pool {
            var score = 0
            var matchedTags: [String] = []

            // 1. Match exato da rua de embarque (+120 pts)
            if candidate.pickupStreet.count >= 5 && normalizedScreen.contains(candidate.pickupStreet) {
                score += 120
                matchedTags.append("rua \(candidate.pickupStreet)")
                anyDirectMatch = true
            } else {
                // Match por palavras-chave do endereço de embarque (+45 pts por palavra)
                var kwHits = 0
                for kw in candidate.pickupKeywords where normalizedScreen.contains(kw) {
                    kwHits += 1
                }
                if kwHits > 0 {
                    score += kwHits * 45
                    matchedTags.append("endereço")
                    anyDirectMatch = true
                }
            }

            // 2. Match por palavras-chave do destino (+25 pts)
            for kw in candidate.destKeywords where normalizedScreen.contains(kw) {
                score += 25
                anyDirectMatch = true
            }

            // 3. Match pelo tempo e distância de busca na barra de navegação (+70 pts)
            if stepCount >= 1 && navMin > 0 {
                let minDiff = abs(navMin - candidate.payload.pickupMinutes)
                let kmDiff = abs(navKm - candidate.payload.pickupDistanceKm)
                if minDiff <= 1 && kmDiff <= 0.4 {
                    score += 70
                    matchedTags.append("\(navMin) min")
                    anyDirectMatch = true
                } else if minDiff <= 2 && kmDiff <= 0.8 {
                    score += 35
                    anyDirectMatch = true
                }
            }

            // 4. Filtro Anti-"Corrida Nova que Entrou na Lista na Hora do Clique":
            // Uma corrida que o motorista olhou por vários frames (>= 2 leituras) ganha bônus (+30 pts).
            // Uma corrida que apareceu por apenas 1 frame nos últimos 1.2s antes da lista fechar sofre penalidade (-50 pts),
            // pois é quase certamente um card novo que entrou na lista enquanto o clique na corrida anterior já estava processando!
            if candidate.seenFrameCount >= 2 {
                score += 30
            } else if (now - candidate.firstSeenTime) < 1.3 {
                score -= 50
            }

            if score > bestScore {
                bestScore = score
                bestCandidate = candidate
                bestDetail = matchedTags.joined(separator: " + ")
            }
        }

        return (bestCandidate, bestDetail, anyDirectMatch)
    }

    /// Nos primeiros 12s após aceitar uma corrida de uma Lista (2+ candidatos), continua conferindo a placa da rua no GPS.
    /// Se a placa da rua do GPS confirmar outra corrida que estava na mesma lista, envia correção automática!
    private func verifyRecentListAcceptAgainstGPSScreen(normalizedUpper: String, now: TimeInterval) {
        guard didSendAcceptedForLastOffer,
              candidatePool.count >= 2,
              lastAcceptedTimestamp > 0,
              (now - lastAcceptedTimestamp) <= 12.0 else { return }

        for candidate in candidatePool where candidate.hash != lastAcceptedCandidateHash {
            let matchesFullStreet = candidate.pickupStreet.count >= 6 && normalizedUpper.contains(candidate.pickupStreet)
            let keywordHits = candidate.pickupKeywords.filter { normalizedUpper.contains($0) }.count

            if matchesFullStreet || keywordHits >= 2 {
                let previousTs = lastAcceptedOfferTimestamp
                lastAcceptedCandidateHash = candidate.hash
                lastAcceptedOfferTimestamp = candidate.payload.timestamp
                sendAcceptedCorrectionViaUDP(
                    candidate.payload,
                    previousTimestamp: previousTs,
                    reason: "Confirmada pela rua no GPS (\(candidate.pickupStreet))"
                )
                break
            }
        }
    }

    // MARK: - Travas de Segurança contra Falso Aceite

    /// Detecta avisos da 99/Uber quando outro motorista aceita a corrida ou quando a oferta expira
    private func isOfferTakenByAnotherDriverOrUnavailable(_ normalizedUpper: String) -> Bool {
        return normalizedUpper.contains("OUTRO MOTORISTA") ||
               normalizedUpper.contains("FOI ACEITA POR") ||
               normalizedUpper.contains("JA FOI ACEITA") ||
               normalizedUpper.contains("NAO ESTA MAIS DISPONIVEL") ||
               normalizedUpper.contains("CORRIDA INDISPONIVEL") ||
               normalizedUpper.contains("VIAGEM INDISPONIVEL") ||
               normalizedUpper.contains("OFERTA EXPIRADA") ||
               normalizedUpper.contains("CORRIDA EXPIRADA") ||
               normalizedUpper.contains("TEMPO ESGOTADO")
    }

    /// Verifica se ainda existem elementos visuais exclusivos de um Card de Oferta ou da Lista de Solicitações na tela
    private func hasOfferCardOrListRemnants(
        upper: String,
        normalizedUpper: String,
        cardLines: [RecognizedLine]
    ) -> Bool {
        // 1. Preço de oferta visível no card
        if extractMainFareBRL(from: cardLines) != nil {
            return true
        }

        // 2. Textos exclusivos de cards de oferta / lista de solicitações da 99 e Uber
        if normalizedUpper.contains("POP NOVA") ||
           normalizedUpper.contains("PERFIL ESSENCIAL") ||
           normalizedUpper.contains("PERFIL PREMIUM") ||
           normalizedUpper.contains("CPF VERIF") ||
           normalizedUpper.contains("CPF E CARTAO") ||
           normalizedUpper.contains("ESPERA LONGA") ||
           normalizedUpper.contains("TARIFA BASE") ||
           normalizedUpper.contains("TAXA DE PARADA") ||
           normalizedUpper.contains("PGTO. NO APP") ||
           normalizedUpper.contains("NAO AFETA A TA") ||
           normalizedUpper.contains("ACEITAR POR R$") ||
           normalizedUpper.contains("SOLICITACOES") ||
           normalizedUpper.contains("MAIS >") {
            return true
        }

        let nsRange = NSRange(upper.startIndex..<upper.endIndex, in: upper)

        // 3. Contador de corridas históricas do passageiro no card: "42 corridas", "+999 corridas"
        if Self.passengerRidesCountRegex.firstMatch(in: upper, options: [], range: nsRange) != nil {
            return true
        }

        // 4. Taxa R$/km impressa no card de oferta: "R$ 1,25/km"
        if Self.cardRatePerKmRegex.firstMatch(in: upper, options: [], range: nsRange) != nil {
            return true
        }

        // 5. Formato entre parênteses da Lista/Radar da 99: "(7 min 2,8 km)"
        if Self.stepInsideParenRegex.firstMatch(in: upper, options: [], range: nsRange) != nil {
            return true
        }

        return false
    }

    private func hasActiveTripOrNavigationIndicators(_ normalizedUpper: String) -> Bool {
        return normalizedUpper.contains("NAVEGAR") ||
               normalizedUpper.contains("KM/H") ||
               normalizedUpper.contains("VIRE A DIREITA") ||
               normalizedUpper.contains("VIRE A ESQUERDA") ||
               normalizedUpper.contains("SIGA EM FRENTE") ||
               normalizedUpper.contains("SIGA PELA") ||
               normalizedUpper.contains("CHEGADA ") ||
               normalizedUpper.contains("CHEGADA AS") ||
               normalizedUpper.contains("CHEGUEI") ||
               normalizedUpper.contains("INICIAR CORRIDA") ||
               normalizedUpper.contains("INICIAR VIAGEM") ||
               normalizedUpper.contains("EMBARQUE") ||
               normalizedUpper.contains("A CAMINHO") ||
               normalizedUpper.contains("FINALIZAR CORRIDA") ||
               normalizedUpper.contains("FINALIZAR VIAGEM")
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

        for line in cleanLines {
            let norm = Self.stripDiacritics(line.uppercased())
            if norm == "BUSCANDO" || norm == "BUSCANDO..." || norm == "SOLICITACOES" {
                return true
            }
        }

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

    /// Extrai a rua de embarque e palavras-chave significativas do embarque e do destino
    private func extractAddressTokens(from lines: [RecognizedLine]) -> (street: String, pickupKeywords: [String], destKeywords: [String]) {
        var stepIndices: [Int] = []
        var inlineAddresses: [Int: String] = [:]

        for (i, line) in lines.enumerated() {
            let text = line.text
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = Self.stepInsideParenRegex.firstMatch(in: text, options: [], range: nsRange) ??
                           Self.stepOutsideParenRegex.firstMatch(in: text, options: [], range: nsRange) {
                stepIndices.append(i)
                // Na Lista da 99, o endereço muitas vezes começa na MESMA linha após o parêntese:
                // ex: "(7 min 2,8 km) Loja 2A, Avenida Álvaro Carvalho Barbosa, 2257"
                let endPos = match.range.location + match.range.length
                if endPos < nsRange.length,
                   let afterRange = Range(NSRange(location: endPos, length: nsRange.length - endPos), in: text) {
                    let remainder = String(text[afterRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if remainder.count >= 5 {
                        inlineAddresses[i] = remainder
                    }
                }
            }
        }

        var pickupRaw = ""
        var destRaw = ""

        if let firstStepIdx = stepIndices.first {
            if let inline = inlineAddresses[firstStepIdx] {
                pickupRaw = inline
            } else if (firstStepIdx + 1) < lines.count && !stepIndices.contains(firstStepIdx + 1) {
                pickupRaw = lines[firstStepIdx + 1].text
            }
        }

        if stepIndices.count >= 2 {
            let secondStepIdx = stepIndices[1]
            if let inline = inlineAddresses[secondStepIdx] {
                destRaw = inline
            } else if (secondStepIdx + 1) < lines.count && !stepIndices.contains(secondStepIdx + 1) {
                destRaw = lines[secondStepIdx + 1].text
            }
        }

        let beforeComma = pickupRaw.components(separatedBy: ",").first ?? pickupRaw
        let cleanStreet = Self.stripDiacritics(beforeComma.uppercased()).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalStreet = (cleanStreet.count >= 5 && !cleanStreet.contains("PARADA") && !cleanStreet.contains("ACEITAR"))
            ? String(cleanStreet.prefix(28))
            : ""

        return (finalStreet, Self.extractSignificantWords(from: pickupRaw), Self.extractSignificantWords(from: destRaw))
    }

    private static func extractSignificantWords(from address: String) -> [String] {
        let stopWords: Set<String> = [
            "AVENIDA", "RUA", "TRAVESSA", "PASSAGEM", "RODOVIA", "ESTRADA", "ALAMEDA", "PRACA",
            "LOJA", "CASA", "BLOCO", "APTO", "CONJUNTO", "HABITACIONAL", "BAIRRO", "CENTRO",
            "CENTRAL", "MACAPA", "INFRAERO", "JARDIM", "PARADA", "PARADAS", "ACEITAR"
        ]
        let norm = stripDiacritics(address.uppercased())
        let parts = norm.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var words: [String] = []
        for p in parts where p.count >= 5 && !stopWords.contains(p) {
            if Int(p) == nil && !words.contains(p) {
                words.append(p)
            }
        }
        return Array(words.prefix(4))
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

        if upper.contains("HISTORICO DE VIAGENS") ||
           upper.contains("HISTORICO DE CORRIDAS") ||
           upper.contains("DETALHES DOS GANHOS") ||
           upper.contains("RESUMO DE GANHOS") {
            return true
        }

        return false
    }

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

    private func extractMainFareBRL(from lines: [RecognizedLine]) -> Double? {
        let fullJoined = lines.map(\.text).joined(separator: "\n")
        let fullNsRange = NSRange(fullJoined.startIndex..<fullJoined.endIndex, in: fullJoined)

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
            if let val = extractFareFromSingleLine(line) {
                candidates.append((value: val, height: line.height, midY: line.midY))
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

    private func sendAcceptedOfferViaUDP(_ offer: RideOfferPayload, reason: String) {
        let packet = AcceptedRideEventPayload(
            status: "RIDE_ACCEPTED",
            triggerReason: reason,
            offer: offer,
            previousOfferTimestamp: nil
        )
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

    private func sendAcceptedCorrectionViaUDP(_ correctOffer: RideOfferPayload, previousTimestamp: TimeInterval, reason: String) {
        let packet = AcceptedRideEventPayload(
            status: "RIDE_ACCEPTED_CORRECTION",
            triggerReason: reason,
            offer: correctOffer,
            previousOfferTimestamp: previousTimestamp
        )
        guard let data = try? JSONEncoder().encode(packet) else { return }
        sendRawUDP(data)
        processingQueue.asyncAfter(deadline: .now() + 0.50) { [weak self] in
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
