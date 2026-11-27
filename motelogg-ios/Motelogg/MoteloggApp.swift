import SwiftUI
import Observation

@main
struct MoteloggApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .onOpenURL { url in
                    if url.host == "record" { LaunchAction.shared.startRequested = true }
                }
        }
    }
}

// MARK: - Modell (samme JSON-format som nettappen, så de kan synke)

struct Seg: Codable, Hashable, Identifiable {
    var id: String
    var t: Double
    var text: String
    var status: String?
}

struct Note: Codable, Hashable, Identifiable {
    var id: String
    var t: Double
    var text: String
    var kind: String          // "note" eller "q"
    var answer: String?
}

struct TaskItem: Codable, Hashable { var who: String?; var what: String; var due: String? }
struct QA: Codable, Hashable { var q: String; var a: String? }

struct Summary: Codable, Hashable {
    var title: String?
    var type: String?
    var summary: String?
    var keyPoints: [String]?
    var decisions: [String]?
    var tasks: [TaskItem]?
    var qa: [QA]?
    var notes: [String]?
    var open: [String]?
}

func newId() -> String { String(UUID().uuidString.lowercased().prefix(12)) }
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

func stamp(_ t: Double) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

struct RecSession: Codable, Hashable, Identifiable {
    var id: String = newId()
    var title: String = ""
    var created: String = ISO8601DateFormatter().string(from: Date())
    var dur: Double = 0
    var segments: [Seg] = []
    var notes: [Note] = []
    var summary: Summary?
    var updated: Double?

    init() {}

    // Tåler at nettappen har felt vi ikke kjenner, eller mangler noen
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        created = (try? c.decodeIfPresent(String.self, forKey: .created)) ?? ISO8601DateFormatter().string(from: Date())
        dur = (try? c.decodeIfPresent(Double.self, forKey: .dur)) ?? 0
        segments = (try? c.decodeIfPresent([Seg].self, forKey: .segments)) ?? []
        notes = (try? c.decodeIfPresent([Note].self, forKey: .notes)) ?? []
        summary = try? c.decodeIfPresent(Summary.self, forKey: .summary)
        updated = try? c.decodeIfPresent(Double.self, forKey: .updated)
    }

    var hasContent: Bool { !segments.isEmpty || !notes.isEmpty || !title.isEmpty }

    var date: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: created) ?? ISO8601DateFormatter().date(from: created) ?? Date()
    }

    /// Tekst og notater gruppert per minutt.
    struct Block: Identifiable { let id: Int; var segs: [Seg]; var notes: [Note] }
    func blocks(live: Int? = nil) -> [Block] {
        var map: [Int: Block] = [:]
        for s in segments { let k = Int(s.t / 60); map[k, default: Block(id: k, segs: [], notes: [])].segs.append(s) }
        for n in notes { let k = Int(n.t / 60); map[k, default: Block(id: k, segs: [], notes: [])].notes.append(n) }
        if let live, map[live] == nil { map[live] = Block(id: live, segs: [], notes: []) }
        return map.values.sorted { $0.id < $1.id }
    }

    var transcriptForAI: String {
        blocks().map { b in
            var line = "[\(stamp(Double(b.id * 60)))] " + b.segs.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            for n in b.notes {
                if n.kind == "q" {
                    let a = (n.answer ?? "").isEmpty ? " | (ubesvart)" : " | SVAR JEG FIKK: \(n.answer ?? "")"
                    line += "\n   [MITT SPØRSMÅL: \(n.text)\(a)]"
                } else {
                    line += "\n   [MITT NOTAT: \(n.text)]"
                }
            }
            return line
        }.joined(separator: "\n")
    }

    var exportText: String {
        var l: [String] = [title.isEmpty ? "Referat" : title, date.formatted(date: .long, time: .shortened), ""]
        if let m = summary {
            if let s = m.summary { l += ["SAMMENDRAG", s, ""] }
            func sec(_ h: String, _ a: [String]?) { if let a, !a.isEmpty { l.append(h); l += a.map { "– " + $0 }; l.append("") } }
            sec("HOVEDPUNKTER", m.keyPoints)
            sec("BESLUTNINGER", m.decisions)
            sec("OPPGAVER", m.tasks?.map { t in
                let who = (t.who ?? "").isEmpty ? "Uavklart" : (t.who ?? "")
                let due = (t.due ?? "").isEmpty ? "" : " (frist \(t.due ?? ""))"
                return "\(who): \(t.what)\(due)"
            })
            sec("SPØRSMÅL OG SVAR", m.qa?.map { "\($0.q) → \(($0.a ?? "").isEmpty ? "Ikke besvart" : ($0.a ?? ""))" })
            sec("MINE NOTATER", m.notes)
            sec("UAVKLART", m.open)
        }
        l += ["TRANSKRIPSJON", transcriptForAI]
        return l.joined(separator: "\n")
    }
}

// MARK: - Lagring lokalt + synk med Supabase (samme som nettappen)

@MainActor
@Observable
final class SessionStore {
    var sessions: [RecSession] = []
    var syncStatus = ""
    var loggedIn = API.shared.isLoggedIn
    var activeRecordingId: String?

    private let url = URL.documentsDirectory.appending(path: "referat.json")
    private var pushTasks: [String: Task<Void, Never>] = [:]

    init() {
        load()
        migrateOld()
    }

    func session(_ id: String) -> RecSession? { sessions.first { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([RecSession].self, from: data) else { return }
        sessions = list
    }

    private func saveLocal() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ s: RecSession) {
        var s = s
        s.updated = nowMs()
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
        saveLocal()
        schedulePush(s)
    }

    func delete(ids: [String]) {
        for id in ids {
            if let s = session(id) { Task { try? await API.shared.upsertSession(s, deleted: true) } }
        }
        sessions.removeAll { ids.contains($0.id) }
        saveLocal()
    }

    private func schedulePush(_ s: RecSession) {
        guard loggedIn, s.hasContent else { return }
        pushTasks[s.id]?.cancel()
        pushTasks[s.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            await self?.pushNow(s)
        }
    }

    private func pushNow(_ s: RecSession) async {
        do { try await API.shared.upsertSession(s); syncStatus = "Synket" }
        catch { syncStatus = "Synk feilet" }
    }

    func pull() async {
        guard loggedIn else { return }
        do {
            let rows = try await API.shared.fetchSessions()
            var remoteUpdated: [String: Double] = [:]
            var deletedIds = Set<String>()
            for row in rows {
                if row.deleted { deletedIds.insert(row.id) }
                if row.id == activeRecordingId { continue }   // opptaket pågår her
                let i = sessions.firstIndex { $0.id == row.id }
                if row.deleted { if let i { sessions.remove(at: i) }; continue }
                guard var r = row.data else { continue }
                if r.updated == nil { r.updated = row.updatedMs }
                remoteUpdated[r.id] = r.updated ?? 0
                if let i {
                    if (r.updated ?? 0) > (sessions[i].updated ?? 0) { sessions[i] = r }
                } else {
                    sessions.append(r)
                }
            }
            // Last opp lokale opptak som mangler eller er nyere enn på serveren
            for s in sessions where s.hasContent && !deletedIds.contains(s.id) && (s.updated ?? 0) > (remoteUpdated[s.id] ?? -1) {
                schedulePush(s)
            }
            saveLocal()
            syncStatus = "Synket"
        } catch APIError.notLoggedIn {
            loggedIn = false
        } catch {
            syncStatus = "Synk feilet"
        }
    }

    func pullSettings() async {
        guard loggedIn else { return }
        let d = UserDefaults.standard
        if let s = try? await API.shared.fetchSettings() {
            if (d.string(forKey: "geminiKey") ?? "").isEmpty, let k = s.gemini_key, !k.isEmpty { d.set(k, forKey: "geminiKey") }
            if (d.string(forKey: "vocab") ?? "").isEmpty, let v = s.vocab, !v.isEmpty { d.set(v, forKey: "vocab") }
            if (s.gemini_key ?? "").isEmpty { await pushSettings() }
        } else {
            await pushSettings()
        }
    }

    func pushSettings() async {
        guard loggedIn else { return }
        let d = UserDefaults.standard
        let key = d.string(forKey: "geminiKey") ?? ""
        guard !key.isEmpty else { return }
        try? await API.shared.upsertSettings(key: key, vocab: d.string(forKey: "vocab") ?? "")
    }

    func signIn(email: String, password: String) async throws {
        try await API.shared.signIn(email: email, password: password)
        loggedIn = true
        await pullSettings()
        await pull()
    }

    func signOut() { API.shared.signOut(); loggedIn = false }

    /// Flytter opptak fra den første versjonen av appen (Møtelogg) over til nytt format.
    private func migrateOld() {
        let old = URL.documentsDirectory.appending(path: "meetings.json")
        guard let data = try? Data(contentsOf: old),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for m in list {
            var s = RecSession()
            s.id = (m["id"] as? String)?.lowercased() ?? newId()
            if session(s.id) != nil { continue }
            s.title = m["title"] as? String ?? ""
            let transcript = m["transcript"] as? String ?? ""
            for line in transcript.split(separator: "\n") {
                let str = String(line)
                if str.hasPrefix("["), let end = str.firstIndex(of: "]") {
                    let ts = str[str.index(after: str.startIndex)..<end].split(separator: ":").compactMap { Double($0) }
                    let t = ts.count == 2 ? ts[0] * 60 + ts[1] : 0
                    let rest = String(str[str.index(after: end)...]).trimmingCharacters(in: .whitespaces)
                    s.segments.append(Seg(id: newId(), t: t, text: rest))
                } else {
                    s.segments.append(Seg(id: newId(), t: 0, text: str))
                }
            }
            if let sum = m["summary"] as? String, !sum.isEmpty { s.summary = Summary(summary: sum) }
            s.dur = s.segments.last?.t ?? 0
            s.updated = nowMs()
            if s.hasContent { sessions.append(s) }
        }
        saveLocal()
        try? FileManager.default.moveItem(at: old, to: URL.documentsDirectory.appending(path: "meetings-migrert.json"))
    }
}
