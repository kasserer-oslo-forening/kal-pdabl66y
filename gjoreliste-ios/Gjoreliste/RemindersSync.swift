import Foundation
import EventKit

/// Holder listen «Gjøreliste» i Påminnelser lik toppen av «Nå» (det du bør gjøre først), begge veier:
/// - Oppgavene øverst i lista ligger som påminnelser. Resten holdes utenfor, så listen aldri blir lang.
/// - Krysser du av en påminnelse (også på klokka eller med Siri), blir oppgaven gjort i databasen.
/// - En ny påminnelse du lager i listen, blir en ny oppgave som Claude sorterer (needs_triage).
/// - Utsetter eller stryker du en oppgave, forsvinner påminnelsen.
@MainActor
final class RemindersSync {
    static let shared = RemindersSync()
    let ek = EKEventStore()
    private var running = false
    static let listName = "Gjøreliste"

    private func calendar() -> EKCalendar? {
        if let c = ek.calendars(for: .reminder).first(where: { $0.title == Self.listName }) { return c }
        let c = EKCalendar(for: .reminder, eventStore: ek)
        c.title = Self.listName
        guard let source = ek.defaultCalendarForNewReminders()?.source
                ?? ek.sources.first(where: { $0.sourceType == .local }) else { return nil }
        c.source = source
        do { try ek.saveCalendar(c, commit: true); return c } catch { return nil }
    }

    private func fetch(_ cal: EKCalendar) async -> [EKReminder] {
        let pred = ek.predicateForReminders(in: [cal])
        return await withCheckedContinuation { cont in
            ek.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
        }
    }

    private func access() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await ek.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }

    /// Fristen i Påminnelser er aldri før i dag – det som er forsinket, står på i dag.
    private func dueComponents(_ t: TaskRow, _ s: Store) -> DateComponents {
        let due = max(s.dueOf(t), s.today)
        return Calendar.current.dateComponents([.year, .month, .day], from: Day.parse(due))
    }

    private func fill(_ r: EKReminder, from t: TaskRow, _ s: Store, isNew: Bool) -> Bool {
        var changed = false
        if r.title != t.t { r.title = t.t; changed = true }
        let want = dueComponents(t, s)
        let have = r.dueDateComponents
        if have?.year != want.year || have?.month != want.month || have?.day != want.day {
            r.dueDateComponents = want; changed = true
        }
        if isNew, let w = t.w, !w.isEmpty { r.notes = w; changed = true }
        let prio = t.star == 1 ? 1 : (t.i == 2 ? 5 : 0)   // 1 = høy, 5 = middels
        if r.priority != prio { r.priority = prio; changed = true }
        return changed
    }

    func run(store s: Store) async {
        guard !running, s.syncReminders, s.loggedIn else { return }
        running = true
        defer { running = false }
        guard await access(), let cal = calendar() else { return }

        let reminders = await fetch(cal)
        var byId: [String: EKReminder] = [:]
        for r in reminders { byId[r.calendarItemIdentifier] = r }
        let top = s.topList()
        let topIds = Set(top.map(\.id))
        var linked = Set<String>()

        // 1. Oppgaver som allerede har en påminnelse
        for t in s.tasks {
            guard let rid = t.reminder_id else { continue }
            guard let r = byId[rid] else {
                // Påminnelsen er borte. Trengs den, lages den på nytt i steg 3.
                if !topIds.contains(t.id) { await s.setReminderId(t.id, nil) }
                continue
            }
            linked.insert(rid)
            let finished = t.done == true || t.dropped == true
            if r.isCompleted {
                if !finished && !s.isHist(t) { await s.complete(t, fromReminders: true) }
                continue
            }
            if finished {
                r.isCompleted = true
                try? ek.save(r, commit: false)
                continue
            }
            if !topIds.contains(t.id) {
                try? ek.remove(r, commit: false)
                await s.setReminderId(t.id, nil)
                continue
            }
            if fill(r, from: t, s, isNew: false) { try? ek.save(r, commit: false) }
        }

        // 2. Nye påminnelser du har laget selv i listen
        for r in reminders where !r.isCompleted && !linked.contains(r.calendarItemIdentifier) {
            await s.addFromReminder(title: r.title ?? "", reminderId: r.calendarItemIdentifier, due: r.dueDateComponents)
        }

        // 3. Oppgaver øverst i lista som mangler påminnelse
        for t in top {
            if let rid = t.reminder_id, byId[rid] != nil { continue }
            let r = EKReminder(eventStore: ek)
            r.calendar = cal
            _ = fill(r, from: t, s, isNew: true)
            do {
                try ek.save(r, commit: true)
                await s.setReminderId(t.id, r.calendarItemIdentifier)
            } catch {}
        }
        try? ek.commit()
    }
}
