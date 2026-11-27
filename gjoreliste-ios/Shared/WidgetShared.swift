import Foundation
import AppIntents
import WidgetKit

/// Felles for appen og widgetene. Appen skriver et øyeblikksbilde av lista til App Group-en,
/// widgetene leser det. Avkrysninger i en widget legges i en kø som appen sender til Supabase.
enum Shared {
    static let appGroup = "group.no.sparhell.gjoreliste"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    private static let snapshotKey = "widgetSnapshot"
    private static let pendingKey = "pendingDone"

    static func loadSnapshot() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .empty }
        return snap
    }

    static func saveSnapshot(_ s: WidgetSnapshot) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: snapshotKey) }
    }

    static func pending() -> [String] { defaults.stringArray(forKey: pendingKey) ?? [] }

    static func addPending(_ id: String) {
        var p = pending()
        if !p.contains(id) { p.append(id) }
        defaults.set(p, forKey: pendingKey)
    }

    /// Henter og tømmer køen (brukes av appen).
    static func takePending() -> [String] {
        let p = pending()
        defaults.removeObject(forKey: pendingKey)
        return p
    }
}

struct WidgetItem: Codable, Hashable, Identifiable {
    var id: String
    var t: String
    var dueDate: String      // YYYY-MM-DD
    var star: Bool
    var minutes: Int
    var context: String      // PC, Telefon, Hjemme …
    var pts: Int

    var urgent: Bool { dueDate <= ShortDate.today }
    var dueLabel: String { ShortDate.label(dueDate) }
}

/// Datoer som "YYYY-MM-DD" i lokal tid, og korte etiketter som i appen.
enum ShortDate {
    private static let f: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static var today: String { f.string(from: Date()) }
    static func label(_ s: String) -> String {
        guard let d = f.date(from: String(s.prefix(10))), let t = f.date(from: today) else { return "" }
        let k = Calendar.current.dateComponents([.day], from: t, to: d).day ?? 0
        if k <= 0 { return "i dag" }
        if k == 1 { return "i morgen" }
        let wd = ["søn", "man", "tir", "ons", "tor", "fre", "lør"][Calendar.current.component(.weekday, from: d) - 1]
        return "\(wd) \(Calendar.current.component(.day, from: d)).\(Calendar.current.component(.month, from: d))"
    }
}

struct WidgetSnapshot: Codable {
    var points: Int
    var goal: Int
    var doneToday: Int
    var urgentLeft: Int
    var items: [WidgetItem]
    var day: String          // datoen øyeblikksbildet gjelder (YYYY-MM-DD)
    var loggedIn: Bool

    static let empty = WidgetSnapshot(points: 0, goal: 100, doneToday: 0, urgentLeft: 0, items: [], day: "", loggedIn: false)

    static let preview = WidgetSnapshot(
        points: 45, goal: 100, doneToday: 3, urgentLeft: 4,
        items: [
            WidgetItem(id: "a", t: "Svar Remi om kasserermøtene 2027", dueDate: "2000-01-01", star: true, minutes: 5, context: "Melding", pts: 30),
            WidgetItem(id: "b", t: "Send styreprotokollene til signering", dueDate: "2000-01-01", star: false, minutes: 30, context: "PC", pts: 30),
            WidgetItem(id: "c", t: "Kjøp adventskalenderbokser", dueDate: "2000-01-01", star: false, minutes: 5, context: "Ute", pts: 22),
            WidgetItem(id: "d", t: "Ring Henning om kronikken", dueDate: "2999-01-01", star: false, minutes: 15, context: "Telefon", pts: 25),
            WidgetItem(id: "e", t: "Les sakspapirene til styremøtet", dueDate: "2999-01-02", star: false, minutes: 15, context: "PC", pts: 15)
        ],
        day: "", loggedIn: true)
}

/// Krysser av en oppgave rett fra widgeten. Appen sender det til databasen neste gang den åpnes.
struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Merk som gjort"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Oppgave")
    var taskId: String

    init() {}
    init(taskId: String) { self.taskId = taskId }

    func perform() async throws -> some IntentResult {
        Shared.addPending(taskId)
        var snap = Shared.loadSnapshot()
        if let i = snap.items.firstIndex(where: { $0.id == taskId }) {
            let item = snap.items.remove(at: i)
            snap.points += item.pts
            snap.doneToday += 1
            if item.urgent { snap.urgentLeft = max(0, snap.urgentLeft - 1) }
            Shared.saveSnapshot(snap)
        }
        return .result()
    }
}

/// Åpner appen. Brukes av knappen på låst skjerm (kontrollsenteret og låseskjermen).
struct OpenGjorelisteIntent: AppIntent {
    static var title: LocalizedStringResource = "Åpne Gjøreliste"
    static var description = IntentDescription("Åpner gjørelista.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult { .result() }
}
