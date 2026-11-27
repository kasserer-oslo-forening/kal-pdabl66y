import Foundation
import AVFoundation
import Observation

// MARK: - Opptak: tar opp i biter (16 kHz mono WAV) og sender hver bit til transkripsjon

@MainActor
@Observable
final class Recorder {
    var session = RecSession()
    var isRecording = false
    var elapsed: TimeInterval = 0
    var pending = 0
    var lastError: String?
    var chunkSeconds: Double = 60

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var chunkStart: TimeInterval = 0
    private var chunkTimer: Timer?
    private var clockTimer: Timer?
    private var accumulated: TimeInterval = 0
    private var runStart: Date?
    private var queue: [(url: URL, at: TimeInterval, tries: Int)] = []
    private var working = false
    private var observing = false

    var statusText: String {
        if isRecording { return pending > 0 ? "Tar opp · \(pending) bit(er) behandles" : "Tar opp" }
        return pending > 0 ? "Behandler \(pending) bit(er) …" : "Klar"
    }

    var liveMinute: Int? { isRecording ? Int(elapsed / 60) : nil }

    func start() async {
        lastError = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Mikrofonen er ikke tillatt. Slå den på under Innstillinger → Referat."
            return
        }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .default)
            try s.setActive(true)
        } catch {
            lastError = "Kunne ikke starte lyd: \(error.localizedDescription)"
            return
        }
        observeInterruptions()
        accumulated = session.dur
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
        session.dur = elapsed
        runStart = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        if let runStart { elapsed = accumulated + Date().timeIntervalSince(runStart) }
    }

    func addNote(_ raw: String, minute: Int?) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let kind = text.hasPrefix("?") ? "q" : "note"
        if kind == "q" { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        tick()
        let t: Double = minute.map { Double($0 * 60) + 30 } ?? (isRecording ? elapsed : session.dur)
        session.notes.append(Note(id: newId(), t: t, text: text, kind: kind, answer: ""))
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
            queue.append((url, chunkStart, 0))
            pending += 1
            Task { await process() }
        }
        currentURL = nil
    }

    private func process() async {
        guard !working else { return }
        working = true
        while !queue.isEmpty {
            let item = queue.removeFirst()
            var done = true
            do {
                let data = try Data(contentsOf: item.url)
                if data.count > 4000 {
                    let text = try await Gemini.transcribe(wav: data)
                    if !text.isEmpty { session.segments.append(Seg(id: newId(), t: item.at, text: text)) }
                }
            } catch {
                if item.tries < 4 {
                    // Prøv igjen senere – lyden beholdes til det lykkes
                    done = false
                    queue.append((item.url, item.at, item.tries + 1))
                    try? await Task.sleep(for: .seconds(5 * Double(item.tries + 1)))
                } else {
                    session.segments.append(Seg(id: newId(), t: item.at, text: "", status: "fail"))
                    lastError = "En bit kunne ikke transkriberes: \(error.localizedDescription)"
                }
            }
            if done {
                try? FileManager.default.removeItem(at: item.url)
                pending -= 1
            }
        }
        session.segments.sort { $0.t < $1.t }
        working = false
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
        case .began: finishChunk()
        case .ended:
            try? AVAudioSession.sharedInstance().setActive(true)
            startChunk()
        @unknown default: break
        }
    }
}

// MARK: - Gemini (bytt eller legg til en annen tjeneste her senere, f.eks. Claude for oppsummering)

struct ServiceError: LocalizedError {
    let message: String
    var status = 0
    var errorDescription: String? { message }
}

@MainActor
enum Gemini {
    static var key: String { UserDefaults.standard.string(forKey: "geminiKey") ?? "" }
    static var vocab: [String] {
        (UserDefaults.standard.string(forKey: "vocab") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(100).map { $0 }
    }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "geminiModel") ?? ""
        return m.isEmpty ? "gemini-flash-latest" : m
    }
    private static var transcribeModelWorks = true

    /// Gemini 3.5 Transcribe (laget for tale, norsk nb-NO). Faller tilbake til vanlig Gemini.
    static func transcribe(wav: Data) async throws -> String {
        guard !key.isEmpty else { throw ServiceError(message: "Mangler Gemini-nøkkel i Innstillinger") }
        let b64 = wav.base64EncodedString()
        if transcribeModelWorks {
            do {
                let t = try await interact(b64: b64)
                if !t.isEmpty { return t }
            } catch let e as ServiceError where e.status == 400 || e.status == 404 {
                transcribeModelWorks = false
            }
        }
        let hint = vocab.isEmpty ? "" : " Ord og navn som kan forekomme: " + vocab.joined(separator: ", ")
        return try await call(parts: [
            ["text": "Transkriber talen i dette lydklippet på norsk. Skriv det som blir sagt så ordrett som mulig, men med riktig tegnsetting og hele setninger. Svar kun med teksten. Er det ingen tydelig tale, svar med en tom streng." + hint],
            ["inline_data": ["mime_type": "audio/wav", "data": b64]]
        ])
    }

    private static func interact(b64: String) async throws -> String {
        var cfg: [String: Any] = ["language_codes": ["nb-NO"], "mode": "smart"]
        if !vocab.isEmpty { cfg["custom_vocabulary"] = vocab }
        let body: [String: Any] = [
            "model": "gemini-3.5-transcribe",
            "input": [["type": "audio", "data": b64, "mime_type": "audio/wav"]],
            "generation_config": ["transcription_config": cfg]
        ]
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw ServiceError(message: msg, status: status)
        }
        // Svaret kan komme før teksten er ferdig: spør igjen til den er klar
        func done(_ j: [String: Any]) -> Bool { ["completed", "succeeded", "done"].contains((j["status"] as? String ?? "").lowercased()) }
        var i = 0
        while let id = json["id"] as? String, !done(json), read(json).isEmpty, i < 40 {
            if ["failed", "cancelled", "canceled", "error"].contains((json["status"] as? String ?? "").lowercased()) {
                throw ServiceError(message: "Transkripsjon feilet")
            }
            try await Task.sleep(for: .seconds(1.5))
            var g = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions/\(id)")!)
            g.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let (d2, _) = try await URLSession.shared.data(for: g)
            json = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any] ?? json
            i += 1
        }
        return read(json)
    }

    private static func read(_ j: [String: Any]) -> String {
        if let t = j["output_text"] as? String { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        let steps = (j["steps"] as? [[String: Any]] ?? []).filter { s in
            let type = s["type"] as? String ?? ""
            return type.isEmpty || type.lowercased().contains("output") || type.lowercased().contains("model")
        }
        let texts = steps.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(_ s: RecSession) async throws -> Summary {
        let prompt = """
        Du lager referat av et opptak på norsk. Det kan være et møte, seminar, konferanse, foredrag eller en samtale. Transkripsjonen er automatisk (kan ha feilhørte ord, ingen talernavn). Linjer merket [MITT NOTAT] og [MITT SPØRSMÅL] er brukerens egne notater, knyttet til minuttet de står under.

        Regler:
        - Se alltid etter beslutninger og oppgaver, men ta dem bare med hvis de faktisk forekommer. Ikke finn på noe.
        - Renskriv brukerens notater og spørsmål/svar til klar, fullstendig tekst, i sammenheng med det som ble sagt.
        - Skriv på norsk bokmål.

        Svar KUN med JSON i dette formatet:
        {"title":"kort, beskrivende tittel (maks 8 ord)","type":"Møte | Seminar | Konferanse | Foredrag | Samtale | Annet","summary":"3–6 setninger","keyPoints":["…"],"decisions":["…"],"tasks":[{"who":"navn eller rolle, tom hvis ukjent","what":"…","due":"frist hvis nevnt, ellers tom"}],"qa":[{"q":"renskrevet spørsmål","a":"renskrevet svar, tom hvis ubesvart"}],"notes":["renskrevne notater"],"open":["uavklarte ting / til oppfølging"]}

        Brukerens tittel: \(s.title.isEmpty ? "(ingen)" : s.title)

        TRANSKRIPSJON:
        \(s.transcriptForAI)
        """
        var raw = try await call(parts: [["text": prompt]], json: true)
        raw = raw.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = raw.data(using: .utf8) else { throw ServiceError(message: "Tomt svar") }
        return try JSONDecoder().decode(Summary.self, from: data)
    }

    private static func call(parts: [[String: Any]], json: Bool = false) async throws -> String {
        guard !key.isEmpty else { throw ServiceError(message: "Mangler Gemini-nøkkel i Innstillinger") }
        var models = [model]
        for m in ["gemini-3.5-flash", "gemini-3-flash-preview", "gemini-flash-lite-latest"] where !models.contains(m) { models.append(m) }
        var last = "Ukjent feil"
        for m in models {
            for attempt in 0..<3 {
                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m):generateContent") else { break }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.timeoutInterval = 120
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                var body: [String: Any] = ["contents": [["role": "user", "parts": parts]]]
                if json { body["generationConfig"] = ["responseMimeType": "application/json"] }
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let data: Data, response: URLResponse
                do { (data, response) = try await URLSession.shared.data(for: req) }
                catch { last = "Nettverksfeil: \(error.localizedDescription)"; try await Task.sleep(for: .seconds(2 * (attempt + 1))); continue }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if status == 200 {
                    let candidates = j?["candidates"] as? [[String: Any]]
                    let content = candidates?.first?["content"] as? [String: Any]
                    let ps = content?["parts"] as? [[String: Any]] ?? []
                    return ps.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let msg = (j?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
                last = "\(m): \(msg)"
                if [400, 401, 403].contains(status) { throw ServiceError(message: last, status: status) }
                if status == 404 { break }
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw ServiceError(message: last)
    }
}
