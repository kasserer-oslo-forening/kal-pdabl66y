import Foundation
import AVFoundation
import Observation

// MARK: - Opptak: tar opp i biter (16 kHz mono WAV) og sender hver bit til transkripsjon

@MainActor
@Observable
final class Recorder {
    var meeting = Meeting()
    var isRecording = false
    var elapsed: TimeInterval = 0
    var pending = 0
    var lastError: String?
    var chunkSeconds: Double = 20

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var chunkStart: TimeInterval = 0
    private var chunkTimer: Timer?
    private var clockTimer: Timer?
    private var accumulated: TimeInterval = 0
    private var runStart: Date?
    private var queue: [(URL, TimeInterval)] = []
    private var working = false
    private var observing = false

    var statusText: String {
        if isRecording { return pending > 0 ? "Tar opp · \(pending) bit(er) behandles" : "Tar opp" }
        return pending > 0 ? "Behandler \(pending) bit(er) …" : "Klar"
    }

    func start() async {
        lastError = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Mikrofonen er ikke tillatt. Slå den på under Innstillinger → Møtelogg."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            lastError = "Kunne ikke starte lyd: \(error.localizedDescription)"
            return
        }
        observeInterruptions()
        isRecording = true
        runStart = Date()
        startChunk()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        finishChunk()
        clockTimer?.invalidate()
        tick()
        accumulated = elapsed
        runStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        if let runStart { elapsed = accumulated + Date().timeIntervalSince(runStart) }
    }

    private func startChunk() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r
            currentURL = url
            tick()
            chunkStart = elapsed
        } catch {
            lastError = "Opptak feilet: \(error.localizedDescription)"
            stop()
            return
        }
        chunkTimer = Timer.scheduledTimer(withTimeInterval: max(10, chunkSeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rotate() }
        }
    }

    private func rotate() {
        finishChunk()
        if isRecording { startChunk() }
    }

    private func finishChunk() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        recorder?.stop()
        recorder = nil
        if let url = currentURL {
            queue.append((url, chunkStart))
            pending += 1
            Task { await process() }
        }
        currentURL = nil
    }

    private func process() async {
        guard !working else { return }
        working = true
        while !queue.isEmpty {
            let (url, at) = queue.removeFirst()
            do {
                let data = try Data(contentsOf: url)
                if data.count > 4000 {
                    let text = try await Gemini.transcribe(wav: data)
                    if !text.isEmpty { append("[\(Self.stamp(at))] \(text)") }
                }
            } catch {
                append("[\(Self.stamp(at))] (feil: \(error.localizedDescription))")
            }
            try? FileManager.default.removeItem(at: url)
            pending -= 1
        }
        working = false
    }

    private func append(_ line: String) {
        if !meeting.transcript.isEmpty && !meeting.transcript.hasSuffix("\n") { meeting.transcript += "\n" }
        meeting.transcript += line
    }

    // Telefonsamtaler o.l. avbryter opptaket; vi fortsetter når avbruddet er over.
    private func observeInterruptions() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.handleInterruption(raw) }
        }
    }

    private func handleInterruption(_ raw: UInt?) {
        guard isRecording, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            finishChunk()
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            startChunk()
        @unknown default:
            break
        }
    }

    static func stamp(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Gemini (bytt eller legg til en annen tjeneste her senere, f.eks. Claude for oppsummering)

struct ServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum Gemini {
    static var key: String { UserDefaults.standard.string(forKey: "geminiKey") ?? "" }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
        return m.isEmpty ? "gemini-flash-latest" : m
    }

    static func transcribe(wav: Data) async throws -> String {
        try await call(parts: [
            ["text": "Transkriber talen i dette lydklippet ordrett på norsk. Svar kun med teksten, uten kommentarer. Er det ingen tydelig tale, svar med en tom streng."],
            ["inline_data": ["mime_type": "audio/wav", "data": wav.base64EncodedString()]]
        ])
    }

    static func summarize(_ text: String, title: String) async throws -> String {
        try await call(parts: [[
            "text": """
            Her er en automatisk transkripsjon av et fysisk møte på norsk (kan ha feilhørte ord, ingen talernavn). Skriv på norsk bokmål, uten markdown-tegn:

            KORT SAMMENDRAG (3–5 setninger)
            HOVEDPUNKTER (linjer som starter med –)
            BESLUTNINGER
            OPPGAVER (hvem, hva, frist)
            UAVKLART

            Møte: \(title.isEmpty ? "ukjent" : title)

            \(text)
            """
        ]])
    }

    private static func call(parts: [[String: Any]]) async throws -> String {
        guard !key.isEmpty else { throw ServiceError(message: "Mangler API-nøkkel i Innstillinger") }
        var models = [model]
        for m in ["gemini-3.5-flash", "gemini-3-flash-preview", "gemini-flash-lite-latest"] where !models.contains(m) {
            models.append(m)
        }
        var last = "Ukjent feil"
        for m in models {
            for attempt in 0..<3 {
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent") else { break }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 120
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["contents": [["role": "user", "parts": parts]]])

                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

                if status == 200 {
                    let candidates = json?["candidates"] as? [[String: Any]]
                    let content = candidates?.first?["content"] as? [String: Any]
                    let ps = content?["parts"] as? [[String: Any]] ?? []
                    return ps.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
                last = "\(m): \(msg)"
                if [400, 401, 403].contains(status) { throw ServiceError(message: last) }
                if status == 404 { break }
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw ServiceError(message: last)
    }
}
