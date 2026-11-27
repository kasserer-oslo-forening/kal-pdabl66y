import SwiftUI
import Observation

@main
struct MoteloggApp: App {
    @State private var store = MeetingStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .onOpenURL { url in
                    if url.host == "record" { LaunchAction.shared.startRequested = true }
                }
        }
    }
}

// MARK: - Modell

struct Meeting: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var date = Date()
    var transcript: String = ""
    var summary: String = ""

    var exportText: String {
        var s = title.isEmpty ? "Møte" : title
        s += "\n" + date.formatted(date: .long, time: .shortened) + "\n\n"
        if !summary.isEmpty { s += "OPPSUMMERING\n" + summary + "\n\n" }
        s += "TRANSKRIPSJON\n" + transcript
        return s
    }
}

// MARK: - Lagring (JSON-fil i appens dokumentmappe)

@MainActor
@Observable
final class MeetingStore {
    var meetings: [Meeting] = []

    private let url = URL.documentsDirectory.appending(path: "meetings.json")

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Meeting].self, from: data) else { return }
        meetings = list.sorted { $0.date > $1.date }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(meetings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func upsert(_ m: Meeting) {
        if let i = meetings.firstIndex(where: { $0.id == m.id }) {
            meetings[i] = m
        } else {
            meetings.insert(m, at: 0)
        }
        save()
    }

    func delete(ids: [UUID]) {
        meetings.removeAll { ids.contains($0.id) }
        save()
    }
}
