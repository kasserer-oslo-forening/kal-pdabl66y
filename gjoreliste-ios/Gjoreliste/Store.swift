import Foundation
import SwiftUI
import UIKit

// MARK: - Modeller (samme kolonner som i Supabase)

struct Src: Codable, Hashable {
    var k: String?; var at: String?; var who: String?; var q: String?; var t: String?; var url: String?
}
struct Doc: Codable, Hashable { var t: String?; var url: String? }

struct TaskRow: Codable, Identifiable, Hashable {
    var id: String
    var t: String
    var w: String?
    var p: String?
    var c: String?
    var m: Int?
    var i: Int?
    var d: String?
    var s: String?
    var e: Int?
    var mt: String?
    var after: String?
    var docs: [Doc]?
    var src: [Src]?
    var done: Bool?
    var done_at: String?
    var dropped: Bool?
    var snooze: String?
    var star: Int?
    var deleg: String?
    var log: [String]?
    var next: String?
    var needs_triage: Bool?
    var reminder_id: String?
    var created_at: String?
}
struct WaitRow: Codable, Identifiable { var id: String; var log: [String]? }
struct Win: Codable, Identifiable { var id: String; var d: String; var pts: Int? }
struct Meeting: Codable, Identifiable { var id: String; var d: String; var time: String?; var end: String?; var brief: Bool? }
struct Project: Codable { var k: String; var n: String }

struct UndoItem: Identifiable { let id = UUID(); let text: String; let prev: TaskRow }

// MARK: - Datoer (som "YYYY-MM-DD", lokal tid)

enum Day {
    private static let f: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func iso(_ d: Date) -> String { f.string(from: d) }
    static func parse(_ s: String) -> Date { f.date(from: String(s.prefix(10))) ?? Date() }
    static var today: String { iso(Date()) }
    static func add(_ s: String, _ n: Int) -> String {
        iso(Calendar.current.date(byAdding: .day, value: n, to: parse(s)) ?? Date())
    }
    static func diff(_ a: String, _ b: String) -> Int {
        Calendar.current.dateComponents([.day], from: parse(b), to: parse(a)).day ?? 0
    }
    static func nextMonday(_ today: String) -> String {
        let day = Calendar.current.component(.weekday, from: parse(today)) - 1   // 0 = søndag
        var k = (8 - day) % 7
        if k == 0 { k = 7 }
        return add(today, k)
    }
    static func label(_ s: String, today: String) -> String {
        let k = diff(s, today)
        if k <= 0 { return "i dag" }
        if k == 1 { return "i morgen" }
        let d = parse(s)
        let wd = ["søn", "man", "tir", "ons", "tor", "fre", "lør"][Calendar.current.component(.weekday, from: d) - 1]
        return "\(wd) \(Calendar.current.component(.day, from: d)).\(Calendar.current.component(.month, from: d))"
    }
    static func nowISO() -> String { ISO8601DateFormatter().string(from: Date()) }
}

private func nn<T>(_ x: T?) -> Any {
    if let x { return x }
    return NSNull()
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var tasks: [TaskRow] = []
    @Published var waiting: [WaitRow] = []
    @Published var wins: [Win] = []
    @Published var meetings: [Meeting] = []
    @Published var projects: [String: String] = [:]
    @Published var loggedIn = API.shared.isLoggedIn
    @Published var error: String?
    @Published var undoItem: UndoItem?
    @Published var syncReminders: Bool = (UserDefaults.standard.object(forKey: "syncReminders") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(syncReminders, forKey: "syncReminders")
            if syncReminders { scheduleSync() }
        }
    }

    let goal = 100
    var today: String { Day.today }
    private var syncTask: Task<Void, Never>?
    private let praise = ["Én mindre.", "Unnagjort.", "Bra jobba.", "Det var den.", "Godt. Neste?", "Ferdig med den.", "Sånn ja."]

    // MARK: Lasting

    func load() async {
        let since = Day.add(today, -7)
        do {
            async let t: [TaskRow] = API.shared.select("tasks")
            async let w: [WaitRow] = API.shared.select("waiting")
            async let wi: [Win] = API.shared.select("wins", [URLQueryItem(name: "d", value: "gte.\(since)")])
            async let m: [Meeting] = API.shared.select("meetings")
            async let p: [Project] = API.shared.select("projects")
            let (tt, ww, wiwi, mm, pp) = try await (t, w, wi, m, p)
            tasks = tt; waiting = ww; wins = wiwi; meetings = mm
            projects = Dictionary(pp.map { ($0.k, $0.n) }, uniquingKeysWith: { a, _ in a })
            error = nil
            if syncReminders { await RemindersSync.shared.run(store: self) }
        } catch APIError.notLoggedIn {
            loggedIn = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func logout() {
        API.shared.signOut()
        loggedIn = false
        tasks = []
    }

    func scheduleSync() {
        guard syncReminders, loggedIn else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            await RemindersSync.shared.run(store: self)
        }
    }

    // MARK: Regler (samme som nettsiden)

    func isHist(_ t: TaskRow) -> Bool {
        (t.done == true || t.dropped == true) && t.d == nil && t.c == nil && t.needs_triage != true
    }
    private func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }
    private func meetOver(_ m: Meeting) -> Bool {
        let hm = (m.end ?? m.time ?? "23:59").split(separator: ":").compactMap { Int($0) }
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Day.parse(m.d))
        c.hour = hm.first ?? 23
        c.minute = hm.count > 1 ? hm[1] : 59
        return Date() > (Calendar.current.date(from: c) ?? Date())
    }
    func isOpen(_ t: TaskRow) -> Bool {
        if isHist(t) || t.done == true || t.dropped == true { return false }
        if let dl = t.deleg, !dl.isEmpty { return false }
        if let mt = t.mt, let m = meeting(mt), m.brief == true || !meetOver(m) { return false }
        if let a = t.after, let m = meeting(a), !meetOver(m) { return false }
        if let s = t.s, s > today { return false }
        if let z = t.snooze, z > today { return false }
        return true
    }
    func dueOf(_ t: TaskRow) -> String {
        var d: String? = (t.e != nil && t.next != nil) ? t.next : t.d
        if let z = t.snooze, d == nil || z > d! { d = z }
        return d ?? String((t.s ?? t.created_at ?? today).prefix(10))
    }
    func bucket(_ t: TaskRow) -> Int {
        let d = dueOf(t)
        if t.star == -1 { return 6 }
        if d <= today { return 0 }
        if t.star == 1 { return 1 }
        if Day.diff(d, today) <= 2 { return 2 }
        if t.i == 2 { return 3 }
        return 4
    }
    func openList() -> [TaskRow] {
        tasks.filter(isOpen).sorted { a, b in
            let x = bucket(a), y = bucket(b)
            if x != y { return x < y }
            let da = dueOf(a), db = dueOf(b)
            if da != db { return da < db }
            if (a.i ?? 0) != (b.i ?? 0) { return (a.i ?? 0) > (b.i ?? 0) }
            return (a.m ?? 0) < (b.m ?? 0)
        }
    }
    func urgentCount(_ list: [TaskRow]) -> Int { list.filter { bucket($0) == 0 }.count }
    func topCount(_ list: [TaskRow]) -> Int { min(list.count, max(5, min(urgentCount(list), 7))) }
    func topList() -> [TaskRow] { let l = openList(); return Array(l.prefix(topCount(l))) }

    func pts(_ t: TaskRow) -> Int {
        if isHist(t) { return 10 }
        let base = [0: 10, 1: 20, 2: 30][t.i ?? 0] ?? 10
        return base + min(30, Int((Double(t.m ?? 0) / 3).rounded()))
    }
    func todayStats() -> (n: Int, p: Int) {
        var n = 0, p = 0
        for t in tasks {
            let log = t.log ?? []
            var k = log.filter { $0 == today }.count
            if t.done == true, let da = t.done_at, da.prefix(10) == today, !log.contains(today) { k += 1 }
            n += k; p += k * pts(t)
        }
        for w in waiting { let k = (w.log ?? []).filter { $0 == today }.count; n += k; p += k * 10 }
        for w in wins where w.d == today { n += 1; p += w.pts ?? 15 }
        return (n, p)
    }

    // MARK: Handlinger

    private func stateFields(_ t: TaskRow) -> [String: Any] {
        ["done": t.done ?? false, "done_at": nn(t.done_at), "dropped": t.dropped ?? false,
         "snooze": nn(t.snooze), "star": nn(t.star), "log": t.log ?? [], "next": nn(t.next)]
    }
    private func apply(_ n: TaskRow, undoText: String?, prev: TaskRow) async {
        guard let idx = tasks.firstIndex(where: { $0.id == n.id }) else { return }
        tasks[idx] = n
        if let undoText { showUndo(undoText, prev) }
        do { try await API.shared.update("tasks", id: n.id, stateFields(n)) }
        catch { self.error = "Kunne ikke lagre: \(error.localizedDescription)" }
        scheduleSync()
    }
    private func showUndo(_ text: String, _ prev: TaskRow) {
        let item = UndoItem(text: text, prev: prev)
        undoItem = item
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.undoItem?.id == item.id { self?.undoItem = nil }
        }
    }

    func complete(_ t: TaskRow, fromReminders: Bool = false) async {
        guard let cur = tasks.first(where: { $0.id == t.id }) else { return }
        var n = cur
        if let e = n.e {
            let nx = Day.add(today, e)
            n.next = nx; n.snooze = nx; n.log = (n.log ?? []) + [today]
        } else {
            n.done = true; n.done_at = Day.nowISO()
        }
        if !fromReminders { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        let left = openList().filter { $0.id != t.id && bucket($0) == 0 }.count
        let msg = (left == 0 && bucket(cur) == 0) ? "Alt som hastet i dag er gjort." : (praise.randomElement() ?? "Bra.")
        await apply(n, undoText: fromReminders ? nil : "\(msg) +\(pts(cur)) poeng", prev: cur)
    }
    func snooze(_ t: TaskRow, to: String) async {
        guard let cur = tasks.first(where: { $0.id == t.id }) else { return }
        var n = cur; n.snooze = to
        await apply(n, undoText: "Utsatt til \(Day.label(to, today: today)).", prev: cur)
    }
    func drop(_ t: TaskRow) async {
        guard let cur = tasks.first(where: { $0.id == t.id }) else { return }
        var n = cur; n.dropped = true; n.done_at = Day.nowISO()
        await apply(n, undoText: "Strøket.", prev: cur)
    }
    func star(_ t: TaskRow, _ v: Int) async {
        guard let cur = tasks.first(where: { $0.id == t.id }) else { return }
        var n = cur; n.star = (cur.star == v) ? nil : v
        await apply(n, undoText: nil, prev: cur)
    }
    func undo(_ item: UndoItem) async {
        undoItem = nil
        await apply(item.prev, undoText: nil, prev: item.prev)
    }

    func add(_ text: String) async {
        let id = "i" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36)
        let row: [String: Any] = ["id": id, "t": text, "p": "inn", "i": 1, "m": 0, "needs_triage": true, "origin": "ios"]
        do {
            try await API.shared.insert("tasks", row)
            tasks.append(TaskRow(id: id, t: text, p: "inn", i: 1, done: false, dropped: false, log: [],
                                 needs_triage: true, created_at: Day.nowISO()))
            scheduleSync()
        } catch {
            self.error = "Kunne ikke lagre: \(error.localizedDescription)"
        }
    }

    /// En påminnelse som er laget direkte i Påminnelser-appen blir en ny oppgave Claude sorterer.
    func addFromReminder(title: String, reminderId: String, due: DateComponents?) async {
        let id = "r" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(Int.random(in: 0..<1296), radix: 36)
        var row: [String: Any] = ["id": id, "t": title.isEmpty ? "(uten tittel)" : title, "p": "inn", "i": 1, "m": 0,
                                  "needs_triage": true, "origin": "paaminnelser", "reminder_id": reminderId]
        var d: String?
        if let due, let date = Calendar.current.date(from: due) { d = Day.iso(date); row["d"] = d }
        do {
            try await API.shared.insert("tasks", row)
            tasks.append(TaskRow(id: id, t: row["t"] as? String ?? title, p: "inn", i: 1, d: d, done: false, dropped: false,
                                 log: [], needs_triage: true, reminder_id: reminderId, created_at: Day.nowISO()))
        } catch {
            self.error = "Kunne ikke lagre påminnelsen: \(error.localizedDescription)"
        }
    }

    func setReminderId(_ taskId: String, _ rid: String?) async {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }), tasks[idx].reminder_id != rid else { return }
        tasks[idx].reminder_id = rid
        try? await API.shared.update("tasks", id: taskId, ["reminder_id": nn(rid)])
    }
}
