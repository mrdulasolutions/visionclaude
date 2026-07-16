import Foundation
import Combine
import UIKit
import CoreLocation
import Vision

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case waitingForWake = "Say “OK, Flux”"
    case listening = "Listening"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

@MainActor
class SessionViewModel: ObservableObject {
    @Published var state: SessionState = .disconnected
    @Published var transcript: [TranscriptMessage] = []
    @Published var currentTranscription: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false
    @Published var connectionMode: ClaudeBridge.ConnectionMode = .channel

    @Published var config: ClaudeConfig {
        didSet {
            bridge.updateConfig(config)
            speechManager.configureElevenLabs(
                apiKey: config.elevenLabsAPIKey,
                voiceId: config.elevenLabsVoiceId
            )
            speechManager.setVoice(config.elevenLabsVoiceId)
            speechManager.setPauseThreshold(config.speechPauseThreshold)
            speechManager.preferAppleVoice = config.useAppleVoice
            rayBanManager.videoPreset = config.glassesVideoPreset
            config.save()
        }
    }

    // Frame sources
    private static let frameSourceKey = "VisionClaude_ActiveFrameSource"
    @Published var activeFrameSource: FrameSourceType = {
        guard let raw = UserDefaults.standard.string(forKey: frameSourceKey),
              let saved = FrameSourceType(rawValue: raw) else { return .iPhone }
        return saved
    }() {
        didSet {
            UserDefaults.standard.set(activeFrameSource.rawValue, forKey: Self.frameSourceKey)
            switchFrameSource()
        }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?

    // Mode system
    @Published var modeManager = ModeManager()

    // QR/Barcode toast
    @Published var codeToastMessage: String?
    @Published var codeToastDetectedCode: DetectedCode?

    let bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private let plantNetService = PlantNetService()
    private let musicService = MusicRecognitionService()
    private let foodService = OpenFoodFactsService()
    private var pendingFoodBarcode: String?
    private let bookService = BookLookupService()
    private var pendingBookISBN: String?

    // "Scan book" price comparison (BookFinder + AddALL)
    private let bookPriceService = BookPriceService()
    @Published var bookOffers: [BookPriceService.Offer] = []
    @Published var bookOffersTitle: String = ""
    @Published var showBookOffers = false
    private var bookScanDeadline: Date = .distantPast
    private var bookScanCameraWasStarted = false
    private var bookScanFrameSub: AnyCancellable?
    private var isBookScanActive: Bool { Date() < bookScanDeadline }

    // General "scan the code" voice command (QR + product barcodes, any mode)
    private var codeScanDeadline: Date = .distantPast
    private var isCodeScanActive: Bool { Date() < codeScanDeadline }
    private var lastLocalScanWasBook = false  // "scan again" repeats the right scanner
    private let vehicleService = VehicleCheckService()
    private var lastVehicleVRN: String?
    private var quizQueue: [String] = []
    private var inFlightQuestion: String?
    private var previousModeId: String?
    private var hasGreetedThisLaunch = false

    /// Normalization for comparing a transcription against the question echo
    /// the app itself just spoke (ASR won't reproduce punctuation/case).
    private static func echoKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    private let locationService = LocationService()
    private let historyService = HistoricalSitesService()
    private let venueFinder = VenueFinderService()
    private var lastVenues: [VenueFinderService.Venue] = []
    private var lastVenueFetch: (location: CLLocation, time: Date)?
    private var cancellables = Set<AnyCancellable>()

    /// True while the glasses' Bluetooth audio is absent (user out of range).
    private var glassesWereOutOfRange = false

    // Keeps the mic alive: HFP drops (phone in pocket) can outlast the
    // one-shot start retries, leaving the app deaf until this loop revives it.
    private var listeningSupervisorTask: Task<Void, Never>?

    // Wake word / on-demand camera state
    private var awakeUntil: Date = .distantPast
    private var lastReplyWasQuestion = false
    private var wakeExpiryTask: Task<Void, Never>?
    private var cameraIdleTask: Task<Void, Never>?
    private let wakeQuestionWindow: TimeInterval = 12  // after a bare "OK Flux"
    private let followUpWindow: TimeInterval = 30      // after Claude finishes replying
    private let conversationWindow: TimeInterval = 30  // rolling window after any accepted utterance

    /// True while speech should be sent without needing the wake phrase again.
    private var isAwake: Bool { Date() < awakeUntil }

    /// QR-scanner mode auto-detects codes, which needs a live iPhone camera.
    private var shouldStreamContinuously: Bool {
        if !config.onDemandCamera { return true }
        return modeManager.activeMode.id == "qr_scanner" && activeFrameSource == .iPhone
    }

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        setupBindings()
        setupBridgeCallbacks()
        setupCodeDetection()
        rayBanManager.startMonitoringRegistration()
        speechManager.configureElevenLabs(
            apiKey: config.elevenLabsAPIKey,
            voiceId: config.elevenLabsVoiceId
        )
        // ElevenLabs is reserved for AI replies; acks/echoes/mode switches use
        // local Apple TTS. The one exception is the launch greeting — a single
        // phrase, disk-cached, so it's synthesized once ever per voice.
        speechManager.prewarmAcknowledgments([Self.greetingText])

        // Forward Ray-Ban frames for SwiftUI reactivity
        rayBanManager.$latestImage
            .receive(on: RunLoop.main)
            .assign(to: &$rayBanFrame)

        // Forward Ray-Ban connection status
        rayBanManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .rayBan else { return }
                let wasConnected: Bool = {
                    if case .connected = self.frameSourceStatus { return true }
                    return false
                }()
                self.frameSourceStatus = status
                if case .connected = status, !wasConnected {
                    self.greetOnFirstGlassesConnectionIfNeeded()
                }
            }
            .store(in: &cancellables)

        // Greet when the glasses' Bluetooth audio arrives. The DAT status above
        // only turns .connected once a camera stream starts — with on-demand
        // camera that can be long after the glasses actually connect, so the
        // audio route is the real "glasses are here" signal.
        NotificationCenter.default.publisher(for: .glassesAudioConnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.greetOnFirstGlassesConnectionIfNeeded()
                // Walked back into Bluetooth range: restore standby, re-grab
                // the mic, restart a continuous stream if the mode needs one,
                // and say so — reconnection should need zero taps.
                if self.glassesWereOutOfRange {
                    self.glassesWereOutOfRange = false
                    self.rayBanManager.noteGlassesReturned()
                    AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
                    if self.isConnected, self.shouldStreamContinuously, self.activeFrameSource == .rayBan {
                        self.startActiveFrameSourceIfNeeded()
                    }
                    self.speechManager.speakAcknowledgment("Glasses reconnected.")
                    print("[Session] Glasses returned to range — auto-reconnected")
                }
            }
            .store(in: &cancellables)

        // Any input route change while listening leaves the engine tapping a
        // stale bus — it looks alive but hears nothing until the 50s watchdog
        // cycles it. Cycle immediately instead (1s settle for the new route).
        NotificationCenter.default.publisher(for: .audioInputRouteChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Track range: audio route lost + no glasses input = walked away.
                if !AudioSessionManager.glassesAudioInputAvailable() {
                    if !self.glassesWereOutOfRange {
                        self.glassesWereOutOfRange = true
                        self.rayBanManager.noteGlassesOutOfRange()
                        print("[Session] Glasses out of Bluetooth range")
                    }
                }
                guard self.isConnected,
                      self.state == .listening || self.state == .waitingForWake,
                      !self.isProcessing, !self.speechManager.isSpeaking,
                      !AudioSessionManager.shared.musicCaptureActive else { return }
                print("[Session] Input route changed — cycling the mic")
                self.speechManager.stopListening()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startListening()
                }
            }
            .store(in: &cancellables)

        // SwiftUI doesn't observe nested ObservableObjects, and @Published on
        // a reference type only fires when the reference is REPLACED — so a
        // mode change inside ModeManager never re-rendered ContentView.
        // Tapping a mode pill looked frozen until an unrelated @Published
        // changed (e.g. the next spoken interaction). Forward the signal.
        modeManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Quiz mode privacy (spec §7): first-run consent notice on entry;
        // session-scoped Q&A history cleared on exit.
        modeManager.$activeMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                guard let self else { return }
                let previous = self.previousModeId
                self.previousModeId = mode.id
                guard previous != mode.id else { return }
                if previous == "quiz" {
                    self.quizQueue.removeAll()
                    Task { await self.resetConversation() }
                    print("[Session] Quiz: session history cleared on mode exit")
                }
                if mode.id == "quiz" {
                    self.showQuizNoticeIfNeeded()
                    // Quiz mode has no wake gate — reflect that immediately
                    // instead of showing "Say Aelita" until the next mic cycle.
                    if self.state == .waitingForWake { self.state = .listening }
                }
            }
            .store(in: &cancellables)

        // Forward bridge connection state
        bridge.$isConnected
            .receive(on: RunLoop.main)
            .assign(to: &$isConnected)

        bridge.$mode
            .receive(on: RunLoop.main)
            .assign(to: &$connectionMode)
    }

    // MARK: - Bridge Callbacks

    private func setupBridgeCallbacks() {
        // When Claude replies via the channel
        bridge.onReply = { [weak self] text, audioUrl in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A voice "stop" cancelled this request — drop the late reply.
                guard self.isProcessing else {
                    print("[Session] Dropping reply for cancelled request")
                    return
                }
                // The mic stays open while thinking (to hear "stop") — close
                // it before playback so the reply doesn't transcribe itself.
                self.speechManager.stopListening()

                self.transcript.append(TranscriptMessage(role: .assistant, text: text))
                self.isProcessing = false
                self.lastReplyWasQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")

                if let audioUrl, let url = URL(string: audioUrl), !self.config.useAppleVoice {
                    // Play TTS audio from channel server
                    self.state = .speaking
                    self.speechManager.playRemoteAudio(url: url) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isConnected, self.state == .speaking else { return }
                            self.startFollowUpListening()
                        }
                    }
                } else {
                    // Fallback to local TTS
                    self.state = .speaking
                    self.speechManager.speak(text)
                    self.observeSpeechCompletion()
                }
            }
        }

        bridge.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == "connected" {
                    self.state = .idle
                    self.errorMessage = nil
                    try? AudioSessionManager.shared.configureForVoiceChat()
                    self.startListeningSupervisor()
                    // On-demand policy: leave the camera off until a question needs
                    // vision — continuous streaming drains the glasses and the phone.
                    if self.shouldStreamContinuously {
                        self.startActiveFrameSource()
                    }
                    // Hands-free: listen for "aelita" right away.
                    if self.config.wakeWordEnabled && !self.speechManager.isListening {
                        self.startListening()
                    }
                }
            }
        }

        bridge.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.state = .disconnected
            }
        }
    }

    // MARK: - QR/Barcode Detection

    private func setupCodeDetection() {
        cameraManager.$lastDetectedCode
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self else { return }
                self.handleDetectedCode(code)
            }
            .store(in: &cancellables)
    }

    private func handleDetectedCode(_ code: DetectedCode) {
        // An active "scan book" price scan claims ISBN barcodes before the
        // regular Books-mode auto-lookup does.
        if isBookScanActive, BookLookupService.isISBN(code.value) {
            bookScanDeadline = .distantPast
            let isbn = code.value
            Task { await self.runBookPriceFlow(isbn: isbn) }
            return
        }
        // An active "scan the code" command claims ANY code next.
        if isCodeScanActive {
            codeScanDeadline = .distantPast
            Task { await self.handleScannedCode(code) }
            return
        }
        if modeManager.activeMode.id == "qr_scanner" {
            // In QR Scanner mode: automatically send to Claude
            let message = "I scanned a \(code.type) code: \(code.value). What is this?"
            Task { await self.sendText(message) }
        } else if modeManager.activeMode.id == "food", isProductBarcode(code) {
            // In Food mode: product barcodes trigger an automatic lookup
            pendingFoodBarcode = code.value
            Task { await self.sendText("I scanned a product barcode. Is this good for me?") }
        } else if modeManager.activeMode.id == "books", BookLookupService.isISBN(code.value) {
            // In Books mode: ISBN barcodes (978/979 EAN-13) trigger an automatic lookup
            pendingBookISBN = code.value
            Task { await self.sendText("I scanned a book's barcode. Is it any good?") }
        } else {
            // In other modes: show a toast notification
            codeToastDetectedCode = code
            codeToastMessage = "\(code.type): \(code.value)"
            // Auto-dismiss toast after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.codeToastDetectedCode?.timestamp == code.timestamp {
                    self?.codeToastMessage = nil
                    self?.codeToastDetectedCode = nil
                }
            }
        }
    }

    private func isProductBarcode(_ code: DetectedCode) -> Bool {
        // EAN/UPC types from AVFoundation (e.g. "org.gs1.EAN-13"), or an
        // all-digit payload of typical retail barcode length
        if code.type.contains("EAN") || code.type.contains("UPC") { return true }
        let digits = CharacterSet(charactersIn: code.value)
        return CharacterSet.decimalDigits.isSuperset(of: digits) && (8...14).contains(code.value.count)
    }

    func sendCodeToChat(_ code: DetectedCode) {
        codeToastMessage = nil
        codeToastDetectedCode = nil
        let message = "I scanned a \(code.type) code: \(code.value). What is this?"
        Task { await self.sendText(message) }
    }

    func copyCodeToClipboard(_ code: DetectedCode) {
        UIPasteboard.general.string = code.value
        codeToastMessage = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.codeToastMessage = nil
            self?.codeToastDetectedCode = nil
        }
    }

    // MARK: - "Scan Book" Price Comparison

    /// Apple Speech mangles "scan book" freely in live use — observed:
    /// "scanned book", "Dan book", "scandal" (= "scan the…"). Primary match is
    /// scan-verb + book-word; fallback accepts a short utterance whose only
    /// content is a scan-ish word. A false trigger just prompts for a barcode
    /// and times out, which is cheap.
    static func isScanBookCommand(_ text: String) -> Bool {
        if text.range(of: #"\b(?:s?can\w*|dan|stan|span|scam)\s+(?:the\s+|a\s+|this\s+|my\s+)?(?:books?|barcodes?|bar\s?codes?|isbn)\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard tokens.count <= 3 else { return false }
        return tokens.contains { $0.hasPrefix("scan") || $0 == "scandal" || $0 == "scandals" }
    }

    /// Arms barcode capture for a book price scan on the ACTIVE frame source:
    /// glasses frames run through Vision barcode detection; the iPhone camera
    /// uses its AVFoundation metadata output.
    private func startBookPriceScan() {
        bookScanDeadline = Date().addingTimeInterval(25)
        if activeFrameSource == .rayBan {
            startActiveFrameSourceIfNeeded()
            armGlassesBarcodeDetection()
            state = .listening
            speechManager.speak("Look at the book's barcode and hold steady.")
            scheduleScanTimeout()
            return
        }
        bookScanCameraWasStarted = !cameraManager.isRunning
        if bookScanCameraWasStarted {
            try? cameraManager.start()
        }
        state = .listening
        speechManager.speak("Show me the book's barcode.")
        scheduleScanTimeout()
    }

    /// Runs Vision barcode detection over incoming glasses frames while the
    /// scan is armed. Frames arrive ~1/s; `busy` drops frames that land while
    /// a detection pass is still running.
    private func armGlassesBarcodeDetection() {
        var busy = false
        bookScanFrameSub = rayBanManager.$latestImage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                guard let self, self.isBookScanActive, !busy else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    guard let isbn = await Self.detectISBN(in: image),
                          self.isBookScanActive else { return }
                    self.bookScanDeadline = .distantPast
                    self.bookScanFrameSub = nil
                    await self.runBookPriceFlow(isbn: isbn)
                }
            }
    }

    private static func detectISBN(in image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.ean13, .ean8]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
                continuation.resume(returning: payloads.first(where: { BookLookupService.isISBN($0) }))
            }
        }
    }

    private func scheduleScanTimeout() {

        // Give up quietly if no barcode shows up before the deadline. The
        // captured value identifies THIS scan — a barcode capture resets the
        // deadline and a newer scan replaces it, and both must cancel this.
        let armedDeadline = bookScanDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.bookScanDeadline == armedDeadline else { return }
            self.bookScanDeadline = .distantPast
            self.finishBookScanCamera()
            self.speechManager.speak("I didn't catch a barcode. Say scan book to try again.")
            self.startListening()
        }
    }

    private func finishBookScanCamera() {
        bookScanFrameSub = nil
        if bookScanCameraWasStarted && activeFrameSource != .iPhone {
            cameraManager.stop()
        }
        bookScanCameraWasStarted = false
        // A glasses stream started just for the scan winds down via the
        // normal on-demand idle timer.
        if activeFrameSource == .rayBan {
            scheduleCameraIdleStop()
        }
    }

    /// Barcode in hand: confirm the title and author by voice the moment the
    /// ISBN lookup lands (the price scrape takes tens of seconds — the user
    /// needs to know the right book was scanned), then announce the cheapest
    /// offer when the price search finishes. Full list goes to the UI.
    private func runBookPriceFlow(isbn: String) async {
        finishBookScanCamera()
        state = .thinking

        let offerSearch = Task { await bookPriceService.findOffers(isbn: isbn) }
        let book = try? await bookService.fetchBook(isbn: isbn)

        let title = book?.title ?? "ISBN \(isbn)"
        if let book {
            let byline = book.authors.isEmpty ? "" : " by \(book.authors.joined(separator: " and "))"
            speechManager.speak("Got it — \(book.title)\(byline). Checking prices on BookFinder and AddALL.")
        } else {
            speechManager.speak("I read the barcode but couldn't match the ISBN to a title. Checking prices anyway.")
        }

        let offers = await offerSearch.value
        bookOffersTitle = title
        bookOffers = offers
        showBookOffers = true
        state = .idle

        guard let cheapest = offers.first else {
            speechManager.speak("No prices came back from BookFinder or AddALL for this one.")
            startListening()
            return
        }
        let spokenPrice = cheapest.priceLabel
            .replacingOccurrences(of: "£", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "€", with: "")
        let currencyWord = cheapest.currencySymbol == "£" ? "pounds"
            : cheapest.currencySymbol == "$" ? "dollars" : "euros"
        speechManager.speak(
            "Cheapest is \(spokenPrice) \(currencyWord) from \(cheapest.seller), found via \(cheapest.source). \(offers.count) offers are on your screen, cheapest first."
        )
        startListening()
    }

    // MARK: - "Scan the Code" (QR + product barcodes, any mode)

    /// "scan/search/find/read/look at … the QR code / barcode / code".
    /// The verb tolerates the same STT manglings as the book scanner.
    static func isScanCodeCommand(_ text: String) -> Bool {
        text.range(of: #"\b(?:s?can\w*|search|find|read|look\s+at|check)\s+(?:for\s+)?(?:the\s+|a\s+|this\s+|my\s+)?(?:(?:qr|q\s?r|cure|queue\s?are)\s*codes?|barcodes?|bar\s?codes?|codes?)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Arms native code scanning on the active frame source: the iPhone
    /// camera's AVFoundation metadata output, or Vision over glasses frames.
    private func startCodeScan() {
        codeScanDeadline = Date().addingTimeInterval(25)
        speechManager.speak("Scanning now with the camera.")
        state = .listening

        if activeFrameSource == .rayBan {
            startActiveFrameSourceIfNeeded()
            armGlassesCodeDetection()
        } else {
            bookScanCameraWasStarted = !cameraManager.isRunning
            if bookScanCameraWasStarted {
                try? cameraManager.start()
            }
        }

        let armedDeadline = codeScanDeadline
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard let self, self.codeScanDeadline == armedDeadline else { return }
            self.codeScanDeadline = .distantPast
            self.finishBookScanCamera()
            self.speechManager.speak("I didn't spot a code. Ask me to scan again when it's in view.")
            self.startListening()
        }
    }

    /// Vision-based detection over glasses frames for the general code scan —
    /// QR and the common retail barcode symbologies.
    private func armGlassesCodeDetection() {
        var busy = false
        bookScanFrameSub = rayBanManager.$latestImage
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] image in
                guard let self, self.isCodeScanActive, !busy else { return }
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    guard let found = await Self.detectAnyCode(in: image),
                          self.isCodeScanActive else { return }
                    self.codeScanDeadline = .distantPast
                    self.bookScanFrameSub = nil
                    await self.handleScannedCode(found)
                }
            }
    }

    private static func detectAnyCode(in image: UIImage) async -> DetectedCode? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr, .ean13, .ean8, .upce, .code128, .code39, .pdf417, .aztec, .dataMatrix]
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let hit = (request.results ?? []).first { $0.payloadStringValue != nil }
                continuation.resume(returning: hit.flatMap { result in
                    result.payloadStringValue.map {
                        DetectedCode(type: result.symbology.rawValue, value: $0, timestamp: Date())
                    }
                })
            }
        }
    }

    /// Code in hand: QR links open in iOS; product barcodes get identified
    /// (books via ISBN lookup, groceries via Open Food Facts).
    private func handleScannedCode(_ code: DetectedCode) async {
        finishBookScanCamera()
        state = .thinking
        let isQR = code.type.localizedCaseInsensitiveContains("qr")

        if isQR {
            let payload = code.value
            if let url = URL(string: payload),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                speechManager.speak("Got the QR code — it links to \(url.host ?? "a website"). Opening it now.")
                await UIApplication.shared.open(url)
            } else {
                speechManager.speak("Got the QR code. It says: \(payload.prefix(120))")
                codeToastMessage = "QR: \(payload)"
            }
        } else if BookLookupService.isISBN(code.value), let book = try? await bookService.fetchBook(isbn: code.value) {
            let byline = book.authors.isEmpty ? "" : " by \(book.authors.joined(separator: " and "))"
            speechManager.speak("Scanned — it's a book: \(book.title)\(byline). Say scan book in Books mode if you want prices.")
        } else if let product = try? await foodService.fetchProduct(barcode: code.value) {
            let brand = (product.brands?.isEmpty == false) ? " by \(product.brands!)" : ""
            speechManager.speak("Scanned — that's \(product.name)\(brand). Switch to Food mode and scan again for a health verdict.")
        } else {
            speechManager.speak("I scanned a \(code.type.replacingOccurrences(of: "org.gs1.", with: "").replacingOccurrences(of: "org.iso.", with: "")) code reading \(code.value), but couldn't find a product match.")
            codeToastMessage = "\(code.type): \(code.value)"
        }

        state = .idle
        startListening()
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil

        // Try channel mode first (WebSocket -> Claude Code session)
        bridge.mode = .channel
        bridge.connectWebSocket()

        // Also check health endpoint for status
        do {
            let health = try await bridge.checkHealth()
            if health.status == "ok" {
                print("[Session] Channel server health OK")
            }
        } catch {
            print("[Session] Health check failed (channel may still connect via WS): \(error.localizedDescription)")
        }
    }

    func disconnect() {
        listeningSupervisorTask?.cancel()
        listeningSupervisorTask = nil
        speechManager.stopListening()
        speechManager.stopSpeaking()
        cameraIdleTask?.cancel()
        wakeExpiryTask?.cancel()
        awakeUntil = .distantPast
        cameraManager.stop()
        rayBanManager.stop()
        bridge.disconnect()
        frameSourceStatus = .disconnected
        state = .disconnected
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    // MARK: - Frame Source

    private func switchFrameSource() {
        cameraIdleTask?.cancel()
        cameraManager.stop()
        rayBanManager.stop()
        frameSourceStatus = .disconnected

        if activeFrameSource == .rayBan {
            // Reconfigure audio session for Bluetooth, then route mic
            try? AudioSessionManager.shared.configureForVoiceChat()
            // Retry mic routing after DAT SDK has had time to set up streaming
            // The SDK may reset the audio route when it starts
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
                }
            }
            if isConnected && !speechManager.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.startListening()
                }
            }
        }
        if shouldStreamContinuously {
            startActiveFrameSource()
        }
    }

    /// Starts the active source only when it isn't already running or mid-startup —
    /// re-entering RayBanManager.start() during its async session dance would
    /// rebuild the DAT session underneath the in-flight one.
    private func startActiveFrameSourceIfNeeded() {
        let status = activeFrameSource == .iPhone
            ? cameraManager.connectionStatus
            : rayBanManager.connectionStatus
        switch status {
        case .connected, .connecting: return
        default: startActiveFrameSource()
        }
    }

    private func startActiveFrameSource() {
        do {
            switch activeFrameSource {
            case .iPhone:
                cameraManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try cameraManager.start()
                frameSourceStatus = .connected
            case .rayBan:
                rayBanManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try rayBanManager.start()
            }
            errorMessage = nil
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Interrupt

    func interruptSpeaking() {
        speechManager.stopSpeaking()
        print("[Session] Speaking interrupted by user — resuming listening")
        // Brief delay for audio session to settle after stopping playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startFollowUpListening()
        }
    }

    // MARK: - Voice

    func toggleListening() {
        if speechManager.isListening {
            if state == .waitingForWake {
                // Mic tap while passively waiting = "I want to talk now" — skip the wake word.
                extendAwake(by: wakeQuestionWindow)
                state = .listening
            } else {
                speechManager.stopListening()
                state = .idle
            }
        } else {
            startListening()
        }
    }

    func startListening() {
        startListening(retriesRemaining: 3)
    }

    private func startListening(retriesRemaining: Int) {
        // ShazamKit owns the mic right now — restarting speech capture would
        // reconfigure the session back to voice chat and re-grab the glasses'
        // HFP mic mid-fingerprint. The Shazam flow restarts listening itself
        // once it finishes.
        guard !AudioSessionManager.shared.musicCaptureActive else { return }
        if speechManager.isSpeaking {
            speechManager.stopSpeaking()
        }
        // Re-assert the glasses mic on EVERY listening start. The HFP link
        // bounces around DAT camera streaming, and when it drops iOS falls
        // back to the iPhone mic silently — nothing else ever routes back, so
        // speech capture would stay on the pocketed phone indefinitely.
        // (No-op when glasses are absent, reserved, or Shazam is capturing.)
        AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
        do {
            try speechManager.startListening()
            // Quiz mode has no wake gate — it's always actively listening.
            let passiveQuiz = modeManager.activeMode.id == "quiz"
            state = (config.wakeWordEnabled && !isAwake && !passiveQuiz) ? .waitingForWake : .listening
            errorMessage = nil
            // Glasses connected before launch never fire a route-change
            // notification — but by now the audio session is live, so their
            // mic is visible if they're here.
            if AudioSessionManager.glassesAudioInputAvailable() {
                greetOnFirstGlassesConnectionIfNeeded()
            }
        } catch {
            print("[Session] startListening failed (retries left: \(retriesRemaining)): \(error)")
            // Audio route transitions (glasses HFP <-> iPhone after TTS playback)
            // briefly reject the engine's input format — CoreAudio -10868
            // kAudioUnitErr_FormatNotSupported. The route settles within a
            // second, so retry before surfacing an error to the user.
            if retriesRemaining > 0, isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.isConnected,
                          !self.speechManager.isListening, !self.speechManager.isSpeaking else { return }
                    self.startListening(retriesRemaining: retriesRemaining - 1)
                }
            } else {
                // Nearly every mic-start failure is a transient CoreAudio
                // route/engine state that the supervisor recovers from —
                // banner only the genuinely permanent ones (permissions).
                // Enumerating "transient" numeric codes proved error-prone
                // (the 'what' code was mis-transcribed once already).
                let ns = error as NSError
                let description = ns.localizedDescription.lowercased()
                let permanent = description.contains("denied") || description.contains("restrict")
                    || description.contains("authoriz") || description.contains("permission")
                if permanent {
                    errorMessage = "Mic: \(ns.localizedDescription)"
                } else {
                    print("[Session] Mic start failed (code \(ns.code)) — supervisor will keep retrying")
                }
            }
        }
    }

    /// Resume listening after Claude replies, keeping a short window where
    /// follow-ups don't need the wake phrase again.
    private func startFollowUpListening() {
        if config.wakeWordEnabled {
            extendAwake(by: followUpWindow)
        }
        startListening()
    }

    /// Marks the session awake for `window` seconds and schedules the state pill
    /// to drop back to "Say Aelita" when the window lapses unused.
    /// Every 5 seconds: if the mic should be listening but isn't — and no
    /// other subsystem legitimately owns it — restart it. This is what
    /// recovers from Bluetooth route drops that outlast the inline retries
    /// (glasses HFP renegotiation takes 5–10s; the engine retries give up
    /// after ~2s). Runs for the life of the connection.
    private func startListeningSupervisor() {
        listeningSupervisorTask?.cancel()
        listeningSupervisorTask = Task { @MainActor [weak self] in
            var failedRevives = 0
            var processingSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.isConnected else { continue }

                // isProcessing wedge: if a reply never arrives (WebSocket blip
                // mid-answer), isProcessing stays true forever and this loop
                // would honour it forever — the app goes permanently deaf.
                // 90 seconds with no reply is a lost request: clear it, tell
                // the user, and get the mic back.
                if self.isProcessing {
                    if processingSince == nil { processingSince = Date() }
                    if let since = processingSince, Date().timeIntervalSince(since) > 90 {
                        print("[Session] Supervisor: request stuck \(Int(Date().timeIntervalSince(since)))s — unwedging")
                        processingSince = nil
                        self.isProcessing = false
                        self.state = .idle
                        self.speechManager.speak("Sorry, that one got lost. Ask me again.")
                        self.startListening()
                    }
                    continue
                }
                processingSince = nil

                guard !self.speechManager.isListening,
                      !self.speechManager.isSpeaking,
                      !AudioSessionManager.shared.musicCaptureActive,
                      self.state == .listening || self.state == .waitingForWake || self.state == .idle
                else { failedRevives = 0; continue }
                failedRevives += 1
                // Three straight failed revives means the engine or session is
                // wedged in a state retries can't fix — rebuild from scratch.
                if failedRevives >= 3 {
                    print("[Session] Listening supervisor: escalating — full audio reset (attempt \(failedRevives))")
                    self.speechManager.rebuildEngine()
                    try? AudioSessionManager.shared.configureForVoiceChat()
                } else {
                    print("[Session] Listening supervisor: mic is down — reviving (attempt \(failedRevives))")
                }
                self.startListening()
            }
        }
    }

    private func extendAwake(by window: TimeInterval) {
        awakeUntil = Date().addingTimeInterval(window)
        wakeExpiryTask?.cancel()
        wakeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.state == .listening && !self.isAwake && self.config.wakeWordEnabled {
                self.state = .waitingForWake
            }
        }
    }

    private func setupBindings() {
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .assign(to: &$currentTranscription)

        // Pre-warm the camera the moment the vision trigger ("look at") shows up
        // in the PARTIAL transcription — the stream cold-start then overlaps with
        // the user finishing their sentence instead of adding to answer latency.
        // A bare wake word no longer pre-warms: most questions are text-only.
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.config.wakeWordEnabled, self.config.onDemandCamera,
                      self.isConnected, !text.isEmpty,
                      let question = QuestionRouter.questionAfterWakeWord(in: text),
                      QuestionRouter.needsVision(question, mode: self.modeManager.activeMode)
                else { return }
                self.preWarmCamera()
            }
            .store(in: &cancellables)

        speechManager.onSpeechPause = { [weak self] text in
            Task { @MainActor in
                await self?.handleVoiceSpeech(text)
            }
        }

        // Recognition died on its own (route change, iOS task limit) — restart it
        // so hands-free wake-word listening survives long idle stretches.
        speechManager.onListeningStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.isConnected, self.config.wakeWordEnabled,
                      !self.isProcessing, !self.speechManager.isSpeaking,
                      self.state == .listening || self.state == .waitingForWake else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !self.speechManager.isListening else { return }
                self.startListening()
            }
        }

        // QR-scanner mode needs the camera running to auto-detect codes;
        // leaving it re-arms the on-demand idle shutdown.
        modeManager.$activeMode
            .receive(on: RunLoop.main)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] mode in
                guard let self, self.isConnected, self.config.onDemandCamera else { return }
                if mode.id == "qr_scanner" && self.activeFrameSource == .iPhone {
                    self.cameraIdleTask?.cancel()
                    self.startActiveFrameSourceIfNeeded()
                } else {
                    self.scheduleCameraIdleStop()
                }
            }
            .store(in: &cancellables)

        speechManager.setPauseThreshold(config.speechPauseThreshold)
            speechManager.preferAppleVoice = config.useAppleVoice
            rayBanManager.videoPreset = config.glassesVideoPreset

        NotificationCenter.default.publisher(for: .audioInterruptionBegan)
            .sink { [weak self] _ in
                self?.speechManager.stopListening()
                self?.speechManager.stopSpeaking()
                self?.state = .idle
            }
            .store(in: &cancellables)
    }

    // MARK: - Send Message

    func sendText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await handleUserSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Voice input goes through the wake-word gate; typed messages and quick
    /// actions call handleUserSpeech directly and skip it.
    private func handleVoiceSpeech(_ text: String) async {
        // Stop word: a short utterance containing "stop" cancels whatever is
        // in flight — spoken reply, pending AI request, queued quiz questions.
        // Length-capped so conversation that merely mentions "stop" ("we
        // should stop by the shop") doesn't trigger it. Works without the
        // wake word in every mode.
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // "Stop listening" closes the open conversation window on the spot:
        // back to wake-gated, mic still running for the next "OK Flux".
        if tokens.count <= 4, tokens.contains("stop"),
           tokens.contains("listening") || tokens.contains("listen") || tokens.contains("now") {
            cancelInFlightWork()
            awakeUntil = .distantPast
            wakeExpiryTask?.cancel()
            speechManager.speak("Okay — say OK Flux when you need me.")
            currentTranscription = ""
            state = config.wakeWordEnabled ? .waitingForWake : .listening
            startListening()
            return
        }

        if tokens.count <= 3, tokens.contains("stop") {
            cancelInFlightWork()
            return
        }

        // Quiz mode listens passively — no wake word. QuestionDetector decides
        // what counts as a question; everything else is discarded on-device.
        guard config.wakeWordEnabled, modeManager.activeMode.id != "quiz" else {
            await handleUserSpeech(text)
            return
        }

        if let question = QuestionRouter.questionAfterWakeWord(in: text) {
            if question.isEmpty {
                // A bare "aelita" — stay hot and capture the actual question next.
                print("[Session] Wake word heard — listening for the question")
                extendAwake(by: wakeQuestionWindow)
                currentTranscription = ""
                startListening()
                return
            }
            // Conversation stays open: everything said in the next 30
            // seconds is accepted without repeating the wake phrase.
            extendAwake(by: conversationWindow)
            await handleUserSpeech(question)
        } else if isAwake {
            // Follow-up window: filter out conversational fragments ("Wait", "Yeah")
            // that aren't addressed to Claude — each junk send costs a round trip
            // and a spoken reply, which re-opens the window and compounds. Single
            // words only count when they answer a question Claude just asked.
            let wordCount = text.split(whereSeparator: { $0 == " " }).count
            if wordCount < 2 && !lastReplyWasQuestion {
                print("[Session] Ignoring one-word follow-up: \"\(text)\"")
                currentTranscription = ""
                startListening()
                return
            }
            extendAwake(by: conversationWindow)
            await handleUserSpeech(text)
        } else {
            // "Flux mode plants" — mode switching gets its own mini wake word,
            // so it works without the full "Aelita" address. The "flux" token
            // is required here so ambient chatter that happens to mention a
            // mode name can't hijack the app.
            let lowered = text.lowercased()
            if lowered.contains("flux") || lowered.contains("flex"),
               let target = modeManager.mode(matchingVoiceCommand: text) {
                performVoiceModeSwitch(to: target, userText: text)
                return
            }

            // "Scan book" acts as its own wake phrase in Books mode — the
            // command phrase is distinctive enough, and the wake word itself
            // is what STT garbles most ("Leader", "Plex" for Aelita/Flux
            // observed live). Without this, the scan feature dies at this
            // gate whenever the name is misheard.
            if modeManager.activeMode.id == "books", Self.isScanBookCommand(text) {
                print("[Session] Scan-book command accepted without wake word: \"\(text.prefix(60))\"")
                currentTranscription = ""
                startBookPriceScan()
                return
            }

            // Ambient speech without the wake word — discard and keep waiting.
            print("[Session] Ignoring speech without wake word: \"\(text.prefix(60))\"")
            currentTranscription = ""
            startListening()
        }
    }

    /// Applies a voice-commanded mode switch: updates the mode, echoes it in
    /// the transcript, and confirms out loud. Shared by the wake-word path
    /// ("Aelita, plants mode") and the "Flux mode …" shortcut.
    private func performVoiceModeSwitch(to target: VisionMode, userText: String) {
        modeManager.setActiveMode(target)
        transcript.append(TranscriptMessage(role: .user, text: userText))
        transcript.append(TranscriptMessage(role: .assistant, text: "Switched to \(target.name) mode."))
        currentTranscription = ""
        print("[Session] Voice command switched mode to: \(target.name)")
        // Pre-cached ElevenLabs audio (warmed at launch for every mode) —
        // plays instantly in the assistant's voice; mic comes straight back.
        speechManager.speakAcknowledgment("Switched to \(target.name) mode.")
        startListening()
    }

    private func handleUserSpeech(_ text: String) async {
        // Books mode: "scan book" (or "scan the barcode" — people phrase it
        // loosely) runs the local barcode → price-comparison flow
        // (BookFinder + AddALL) instead of a round trip to Claude.
        if modeManager.activeMode.id == "books", Self.isScanBookCommand(text) {
            lastLocalScanWasBook = true
            startBookPriceScan()
            return
        }

        // Any mode: "scan the QR code" / "read the barcode" / "find the code"
        // runs the local code scanner — QR payloads open in iOS, product
        // barcodes get looked up.
        if Self.isScanCodeCommand(text) {
            lastLocalScanWasBook = false
            startCodeScan()
            return
        }

        // "Scan again" repeats whichever local scan ran last (people say
        // this instead of the full command — observed live as "scanned again").
        if text.range(of: #"\b(?:s?can\w*|try)\s+(?:it\s+|that\s+)?again\b"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            if lastLocalScanWasBook, modeManager.activeMode.id == "books" {
                startBookPriceScan()
            } else {
                startCodeScan()
            }
            return
        }

        // Quiz mode: passive question detection. Non-questions are discarded
        // on-device — never sent or added to the transcript (spec §6). While
        // an answer is in flight, further questions queue (up to 3) and are
        // answered in order. Mode-switch commands bypass the filter.
        if modeManager.activeMode.id == "quiz",
           modeManager.mode(matchingVoiceCommand: text) == nil {
            // Every speech pause stops the mic (SpeechManager.handleSpeechPause),
            // so each early-out here MUST restart listening — quiz mode listens
            // continuously, and a dropped restart means it goes deaf on the
            // first overheard non-question.
            if !QuestionDetector.isLikelyQuestion(text) {
                currentTranscription = ""
                print("[Session] Quiz: non-question discarded")
                startListening()
                return
            }
            if isProcessing {
                // The mic is open while the answer is generated, so the app can
                // hear its own spoken echo of the in-flight question — don't
                // queue our own audio as a new question.
                if let inflight = inFlightQuestion,
                   Self.echoKey(text) == Self.echoKey(inflight) {
                    currentTranscription = ""
                    print("[Session] Quiz: ignored echo of the in-flight question")
                    startListening()
                    return
                }
                if quizQueue.count < 3 {
                    quizQueue.append(text)
                    print("[Session] Quiz: queued question (\(quizQueue.count) waiting)")
                } else {
                    transcript.append(TranscriptMessage(role: .assistant, text: "(Missed a question — queue full.)"))
                    print("[Session] Quiz: queue full, dropped question")
                }
                currentTranscription = ""
                startListening()
                return
            }
        }

        // Busy with an earlier question — drop this one, but keep the mic
        // alive (it's deliberately open during thinking so "stop" works).
        guard !isProcessing else {
            startListening()
            return
        }

        // Trip mode navigation ("navigate to Franco's") — opens Apple Maps
        // walking directions; voice guidance plays through the glasses.
        if modeManager.activeMode.id == "trip", let venue = navigationTarget(for: text) {
            transcript.append(TranscriptMessage(role: .user, text: text))
            transcript.append(TranscriptMessage(role: .assistant, text: "Starting walking directions to \(venue.name)."))
            currentTranscription = ""
            state = .speaking
            speechManager.speak("Starting directions to \(venue.name)")
            observeSpeechCompletion()
            if let url = URL(string: "http://maps.apple.com/?daddr=\(venue.latitude),\(venue.longitude)&dirflg=w") {
                await UIApplication.shared.open(url)
            }
            return
        }

        // Vehicle mode insurance handoff ("check insurance") — deliberately
        // human-in-the-loop: opens askMID with the reg on the clipboard; the
        // user completes the CAPTCHA and reads the result themselves. The app
        // never automates or scrapes the askMID check.
        if modeManager.activeMode.id == "vehicle",
           text.lowercased().contains("insurance"),
           let vrn = lastVehicleVRN {
            transcript.append(TranscriptMessage(role: .user, text: text))
            transcript.append(TranscriptMessage(role: .assistant, text: "Opening askMID for \(vrn) — the reg is on your clipboard. Complete the check there."))
            currentTranscription = ""
            UIPasteboard.general.string = vrn
            state = .speaking
            speechManager.speak("Opening ask M I D. Your reg is on the clipboard — paste it in and complete the check there.")
            observeSpeechCompletion()
            await UIApplication.shared.open(VehicleCheckService.askMIDURL)
            return
        }

        // Voice mode switching ("plumber mode", "switch to music mode",
        // "Aelita Flux mode plants") — handled locally, never sent to Claude.
        if let target = modeManager.mode(matchingVoiceCommand: text) {
            performVoiceModeSwitch(to: target, userText: text)
            return
        }

        isProcessing = true
        if modeManager.activeMode.id == "quiz" { inFlightQuestion = text }

        transcript.append(TranscriptMessage(role: .user, text: text))
        currentTranscription = ""
        state = .thinking
        errorMessage = nil

        // Route: does this question need eyes, or just text?
        let wantsVision = QuestionRouter.needsVision(text, mode: modeManager.activeMode)

        // Immediate spoken confirmation — no AI involved, so the user hears
        // feedback while the answer is in flight. Quiz mode echoes the captured
        // question back (spec: confirm what was heard); other modes state the
        // plan. Music mode stays silent (the ack would contaminate ShazamKit's
        // mic sample).
        if modeManager.activeMode.id == "quiz" {
            speechManager.speakConfirmation(text)
        } else if modeManager.activeMode.id != "music" {
            speechManager.speakAcknowledgment(acknowledgment(forMode: modeManager.activeMode.id, wantsVision: wantsVision))
        }

        var image: Data?
        if wantsVision {
            image = await captureFrameOnDemand()
            scheduleCameraIdleStop()
        }
        let source = activeFrameSource == .iPhone ? "iphone" : "rayban"
        print("[Session] Routing: \(wantsVision ? "vision" : "text-only")\(wantsVision && image == nil ? " (frame unavailable)" : "")")

        // Prepend mode system prompt as context
        let modeContext = modeManager.activeMode.systemPrompt
        var fullText = "[Mode: \(modeManager.activeMode.name)] \(modeContext)\n\nUser: \(text)"
        if wantsVision && image == nil {
            fullText += "\n\n(Note: the camera could not provide a frame for this question — answer from context or say you can't see right now.)"
        }

        // Music mode: sample ambient audio via ShazamKit and inject the match
        if modeManager.activeMode.id == "music" {
            // Free the mic — ShazamKit runs its own capture session — and give
            // it a clean full-bandwidth path: the glasses' 16kHz HFP mic can't
            // fingerprint music, and a half-switched route (built-in input,
            // HFP output) delivers empty buffers. Full session reconfig, then
            // back to voice chat.
            speechManager.stopListening()
            try? AudioSessionManager.shared.configureForMusicRecognition()
            print("[Session] Shazam: listening for a song (iPhone mic)…")
            let outcome = await musicService.identify()
            try? AudioSessionManager.shared.configureForVoiceChat()
            switch outcome {
            case .match(let song):
                fullText += "\n\n[\(song.promptSummary)]"
                print("[Session] Shazam match: \(song.title) — \(song.artist)")
            case .noMatch:
                fullText += "\n\n[Note: ShazamKit listened but found no match. Tell the user briefly and suggest getting closer to the audio source.]"
                print("[Session] Shazam: no match")
            case .failed(let message):
                fullText += "\n\n[Note: ShazamKit failed (\(message)). Answer from the image and context if possible.]"
                print("[Session] Shazam error: \(message)")
            }
        }

        // Plants mode: run the frame through Pl@ntNet and inject the results
        if modeManager.activeMode.id == "plants", let imageData = image {
            if config.plantNetAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullText += "\n\n[Note: No Pl@ntNet API key configured — identify visually and mention that adding a Pl@ntNet key in Settings improves accuracy.]"
            } else {
                do {
                    let result = try await plantNetService.identify(imageData: imageData, apiKey: config.plantNetAPIKey)
                    fullText += "\n\n[\(result.promptSummary)]"
                    print("[Session] Pl@ntNet best match: \(result.bestMatch) (\(result.remainingRequests.map { "\($0) requests left today" } ?? "quota unknown"))")
                } catch {
                    fullText += "\n\n[Note: Pl@ntNet lookup failed (\(error.localizedDescription)) — identify visually instead.]"
                    print("[Session] Pl@ntNet error: \(error.localizedDescription)")
                }
            }
        }

        // Food mode: barcode → Open Food Facts lookup + user's health profile
        if modeManager.activeMode.id == "food" {
            // Barcode from live camera detection, or scan the frame (Ray-Ban path)
            var barcode = pendingFoodBarcode
            pendingFoodBarcode = nil
            if barcode == nil, let imageData = image {
                barcode = await BarcodeDetector.detectProductBarcode(in: imageData)
            }

            if let barcode {
                do {
                    let product = try await foodService.fetchProduct(barcode: barcode)
                    fullText += "\n\n[\(product.promptSummary)]"
                    print("[Session] Open Food Facts: \(product.name) (barcode \(barcode))")
                } catch {
                    fullText += "\n\n[Note: Barcode \(barcode) was scanned but the product isn't in Open Food Facts — read the packaging, nutrition label, or ingredients from the image instead.]"
                    print("[Session] Open Food Facts miss for \(barcode): \(error.localizedDescription)")
                }
            }

            fullText += "\n\n[User's food health profile: \(foodHealthProfile)]"
        }

        // Books mode: ISBN → Google Books + Open Library lookup
        if modeManager.activeMode.id == "books" {
            var isbn = pendingBookISBN
            pendingBookISBN = nil
            if isbn == nil, let imageData = image,
               let detected = await BarcodeDetector.detectProductBarcode(in: imageData),
               BookLookupService.isISBN(detected) {
                isbn = detected
            }

            if let isbn {
                do {
                    let book = try await bookService.fetchBook(isbn: isbn)
                    fullText += "\n\n[\(book.promptSummary)]"
                    print("[Session] Book lookup: \(book.title) (ISBN \(isbn))")
                } catch {
                    fullText += "\n\n[Note: ISBN \(isbn) was scanned but no database match — read the cover from the image and use your own knowledge of the book.]"
                    print("[Session] Book lookup miss for \(isbn): \(error.localizedDescription)")
                }
            }
        }

        // Vehicle mode: read a UK plate (spoken reg first, else OCR the frame)
        // and inject the gov.uk tax/MOT record. Claude compares the record's
        // make/colour/year with the car in the image to flag cloned plates.
        if modeManager.activeMode.id == "vehicle" {
            var vrn = PlateReader.extractVRN(fromText: text)
            if vrn == nil, let imageData = image {
                vrn = await PlateReader.readPlate(in: imageData)
            }

            if let vrn {
                lastVehicleVRN = vrn
                do {
                    let vehicle = try await vehicleService.fetchVehicle(vrn: vrn)
                    fullText += "\n\n[\(vehicle.promptSummary)\nCompare this record against the vehicle visible in the image and warn if they don't match (possible cloned plates). If the plate read looks wrong for the car, ask the user to confirm the registration.]"
                    print("[Session] DVLA lookup OK for \(PlateReader.masked(vrn))")
                } catch {
                    fullText += "\n\n[Note: Plate read as \(vrn), but the DVLA lookup failed: \(error.localizedDescription). Tell the user, and if the read may be wrong ask them to say the registration out loud.]"
                    print("[Session] DVLA lookup failed for \(PlateReader.masked(vrn)): \(error.localizedDescription)")
                }
            } else {
                fullText += "\n\n[Note: No UK number plate could be read from the frame or the user's words. Ask the user to get closer to the plate or say the registration out loud.]"
                print("[Session] Vehicle: no plate read")
            }
        }

        // History mode: nearby historic sites from Wikipedia GeoSearch, with
        // summaries prefetched so narration is grounded in retrieved text.
        // Claude ranks the candidates against the camera frame it already sees.
        if modeManager.activeMode.id == "history" {
            do {
                let location = try await locationService.currentLocation()
                let sites = try await historyService.findSites(near: location)
                fullText += "\n\n[\(HistoricalSitesService.promptSummary(sites))]"
                print("[Session] History: \(sites.count) candidates")
            } catch {
                fullText += "\n\n[Note: Historic site search failed (\(error.localizedDescription)). Tell the user briefly and suggest trying again — do not narrate history from memory.]"
                print("[Session] History error: \(error.localizedDescription)")
            }
        }

        // Trip mode: fetch nearby venues (cached for follow-up questions)
        if modeManager.activeMode.id == "trip" {
            if config.googlePlacesAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullText += "\n\n[Note: No Google Places API key configured — tell the user to add one in Settings under Trip Mode to enable venue search.]"
            } else {
                do {
                    let location = try await locationService.currentLocation()
                    if venueCacheIsStale(for: location) {
                        lastVenues = try await venueFinder.findVenues(
                            near: location.coordinate,
                            googleKey: config.googlePlacesAPIKey,
                            tripAdvisorKey: config.tripAdvisorAPIKey
                        )
                        lastVenueFetch = (location, Date())
                        print("[Session] Trip: fetched \(lastVenues.count) venues")
                    } else {
                        print("[Session] Trip: reusing cached venues (\(lastVenues.count))")
                    }
                    fullText += "\n\n[\(VenueFinderService.promptSummary(lastVenues))]"
                } catch {
                    fullText += "\n\n[Note: Venue search failed (\(error.localizedDescription)). Tell the user briefly.]"
                    print("[Session] Trip error: \(error.localizedDescription)")
                }
            }
        }

        // Fastest model first; explicit "tell me more" escalates to the smart tier.
        let tier = modelTier(for: text)
        if tier == "smart" { print("[Session] Escalating to smart model tier") }

        if bridge.mode == .channel {
            // Channel mode: send via WebSocket or HTTP upload
            if let imageData = image, imageData.count > 100_000 {
                // Large images: use HTTP multipart (avoids base64 bloat)
                do {
                    try await bridge.uploadImage(text: fullText, image: imageData, source: source)
                } catch {
                    print("[Session] Upload error, falling back to WS: \(error)")
                    bridge.sendMessage(text: fullText, image: imageData, source: source, tier: tier)
                }
            } else {
                // Small images or text-only: send via WebSocket
                bridge.sendMessage(text: fullText, image: image, source: source, tier: tier)
            }
            print("[Session] Sent to channel: \"\(text)\" with \(image != nil ? "image" : "no image") [mode: \(modeManager.activeMode.name)]")
            // Reply comes back via onReply callback — don't set isProcessing = false here.
            // Keep the mic open while the answer is generated so "stop" works.
            startListening()

        } else {
            // Gateway mode: REST fallback — reopen the mic during the await
            // so a voice "stop" can cancel; the reply path closes it again.
            startListening()
            do {
                let response = try await bridge.chatREST(text: fullText, images: image.map { [$0] } ?? [], tier: tier)
                guard isProcessing else {
                    print("[Session] Dropping REST reply for cancelled request")
                    return
                }
                speechManager.stopListening()
                transcript.append(TranscriptMessage(
                    role: .assistant,
                    text: response.text,
                    toolCalls: response.tool_calls
                ))
                state = .speaking
                speechManager.speak(response.text)
                observeSpeechCompletion()
            } catch {
                errorMessage = error.localizedDescription
                state = .idle
            }
            isProcessing = false
        }
    }

    // MARK: - On-Demand Frame Capture

    /// Starts the active frame source speculatively (no-op if already running or
    /// starting). The idle timer is armed immediately so a text-only question
    /// doesn't leave a pre-warmed stream running forever; a vision question
    /// re-arms it after the frame is captured.
    private func preWarmCamera() {
        let status = activeFrameSource == .iPhone
            ? cameraManager.connectionStatus
            : rayBanManager.connectionStatus
        if case .connected = status { return }
        if case .connecting = status { return }
        print("[Session] Wake word heard — pre-warming \(activeFrameSource.rawValue)")
        startActiveFrameSource()
        scheduleCameraIdleStop()
    }

    /// Spins up the active frame source (if it isn't already streaming) just long
    /// enough to grab one fresh JPEG. Returns nil on timeout — glasses cold-starts
    /// go through the whole DAT session dance and can legitimately take a while.
    private func captureFrameOnDemand() async -> Data? {
        cameraIdleTask?.cancel()
        let source: any FrameSource = activeFrameSource == .iPhone ? cameraManager : rayBanManager
        if !source.isRunning {
            print("[Session] Vision question — starting \(activeFrameSource.rawValue) on demand")
            startActiveFrameSourceIfNeeded()
        }

        let timeout: TimeInterval = activeFrameSource == .rayBan ? 15 : 5
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = source.consumeFrame() { return frame }
            if case .error = source.connectionStatus { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("[Session] Timed out waiting for a frame from \(activeFrameSource.rawValue)")
        return nil
    }

    /// Shuts the stream back down after a quiet period so follow-up vision
    /// questions stay snappy without leaving the camera burning battery.
    private func scheduleCameraIdleStop() {
        cameraIdleTask?.cancel()
        guard config.onDemandCamera, !shouldStreamContinuously else { return }
        let timeout = config.cameraIdleTimeout
        cameraIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard !self.isProcessing else {
                self.scheduleCameraIdleStop()  // still waiting on a reply — check again later
                return
            }
            // Stopping the DAT stream makes the glasses chirp (firmware privacy
            // indicator — not silenceable) and churns the Bluetooth route. Mid-
            // speech that stomps on the voice output, so wait for quiet: poll
            // briefly until the assistant has finished talking.
            while self.speechManager.isSpeaking && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled, !self.isProcessing else {
                self.scheduleCameraIdleStop()
                return
            }
            print("[Session] Camera idle for \(Int(timeout))s — stopping stream to save battery")
            self.stopFrameSources()
        }
    }

    private func stopFrameSources() {
        cameraManager.stop()
        rayBanManager.stop()
        // Idle shutdown, not a lost connection — the source restarts on the
        // next vision question.
        frameSourceStatus = activeFrameSource == .rayBan
            ? rayBanManager.connectionStatus
            : .standby
    }

    /// Venue data is stable for hours; refetch only after 10 minutes or a >250m move.
    private func venueCacheIsStale(for location: CLLocation) -> Bool {
        guard let last = lastVenueFetch, !lastVenues.isEmpty else { return true }
        return Date().timeIntervalSince(last.time) > 600
            || location.distance(from: last.location) > 250
    }

    /// Matches "navigate to <venue>", "take me to <venue>", "directions to <venue>"
    /// against the venues from the last Trip search.
    private func navigationTarget(for text: String) -> VenueFinderService.Venue? {
        guard !lastVenues.isEmpty else { return nil }
        let lowered = text.lowercased()
        let triggers = ["navigate to ", "take me to ", "directions to ", "walk me to ", "go to "]
        guard let trigger = triggers.first(where: { lowered.contains($0) }),
              let range = lowered.range(of: trigger) else { return nil }
        let spokenName = lowered[range.upperBound...]
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !spokenName.isEmpty else { return nil }

        return lastVenues.first { venue in
            let name = venue.name.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return name.contains(spokenName) || spokenName.contains(name)
        }
    }

    private var foodHealthProfile: String {
        var concerns: [String] = []
        if config.foodAvoidUPF { concerns.append("avoiding ultra-processed foods (NOVA 4)") }
        if config.foodWatchSalt { concerns.append("watching salt intake") }
        if config.foodWatchSaturatedFat { concerns.append("watching saturated fat") }
        return concerns.isEmpty
            ? "no specific restrictions configured — give balanced general advice"
            : concerns.joined(separator: "; ")
    }

    private func observeSpeechCompletion() {
        speechManager.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected, self.state == .speaking else { return }
                self.startFollowUpListening()
            }
            .store(in: &cancellables)
    }

    /// Voice "stop": silences any speech, abandons the pending request (its
    /// late reply is dropped by the isProcessing guard in onReply), clears the
    /// quiz queue, and goes straight back to listening.
    private func cancelInFlightWork() {
        print("[Session] Stop command — cancelling in-flight work")
        let hadWork = isProcessing || speechManager.isSpeaking || !quizQueue.isEmpty
        isProcessing = false
        quizQueue.removeAll()
        currentTranscription = ""
        // Leave .speaking before stopping so the speech-completion sink's
        // state guard fails and doesn't double-restart the mic.
        state = .idle
        speechManager.stopSpeaking()
        if hadWork {
            transcript.append(TranscriptMessage(role: .assistant, text: "(Stopped.)"))
        }
        startListening()
    }

    /// "Tell me more"-style follow-ups escalate from the fast model (Haiku) to
    /// the smart one (Sonnet). Everything else takes the fast path — the whole
    /// point is first-answer latency.
    private func modelTier(for text: String) -> String {
        let lowered = text.lowercased()
        let escalations = ["tell me more", "more detail", "more details", "in depth",
                           "go deeper", "elaborate", "more information", "explain more"]
        return escalations.contains(where: lowered.contains) ? "smart" : "fast"
    }

    /// Canned per-mode confirmations — a fixed set so their ElevenLabs audio
    /// can be pre-synthesized once and played with zero latency.
    private static let modeAcknowledgments: [String: String] = [
        "vehicle": "Checking the plate for tax and MOT.",
        "plants": "Taking a look at the plant.",
        "food": "Scanning the product.",
        "books": "Looking up the book.",
        "history": "Finding the history around you.",
        "trip": "Finding places nearby.",
    ]
    private static let genericAcknowledgments = ["Taking a look.", "On it."]

    /// Every ack phrase, for pre-warming the ElevenLabs audio cache.
    static var allAcknowledgmentPhrases: [String] {
        Array(modeAcknowledgments.values) + genericAcknowledgments
    }

    /// The plan, stated deterministically per mode — what the app is about to
    /// do for this question. Spoken as an instant acknowledgment; never
    /// generated by AI.
    private func acknowledgment(forMode modeId: String, wantsVision: Bool) -> String {
        Self.modeAcknowledgments[modeId] ?? (wantsVision ? "Taking a look." : "On it.")
    }

    /// Spoken on the first glasses connection of each app launch; session-
    /// scoped so BT drops and reconnects within a run stay quiet.
    static let greetingText = "I'm Flux — ask me anything by saying, OK Flux."

    private func greetOnFirstGlassesConnectionIfNeeded() {
        guard !hasGreetedThisLaunch else { return }
        hasGreetedThisLaunch = true
        let greeting = Self.greetingText
        transcript.append(TranscriptMessage(role: .assistant, text: greeting))
        // Mic may be live (greet fires right after listening starts) — stop it
        // so the greeting doesn't transcribe itself; completion restarts it.
        if speechManager.isListening { speechManager.stopListening() }
        state = .speaking
        speechManager.speak(greeting)
        observeSpeechCompletion()
        print("[Session] First glasses connection — spoke greeting")
    }

    private func showQuizNoticeIfNeeded() {
        let key = "VisionClaude_QuizNoticeShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        transcript.append(TranscriptMessage(
            role: .assistant,
            text: "Quiz mode listens continuously and auto-answers questions it hears. Speech is transcribed on this phone and anything that isn't a question is discarded without leaving the device; this session's Q&A clears when you leave the mode. In shared spaces, be mindful that recording others may require their consent."
        ))
    }

    /// After an answer finishes speaking: in Quiz mode, answer the next queued
    /// question before going back to listening.
    private func resumeAfterReply() {
        if modeManager.activeMode.id == "quiz", !quizQueue.isEmpty {
            let next = quizQueue.removeFirst()
            print("[Session] Quiz: answering queued question (\(quizQueue.count) left)")
            Task { await handleUserSpeech(next) }
        } else {
            startListening()
        }
    }

    func resetConversation() async {
        transcript.removeAll()
        bridge.resetConversation()
        errorMessage = nil
    }
}
