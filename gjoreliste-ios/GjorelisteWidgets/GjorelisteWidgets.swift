import WidgetKit
import SwiftUI
import AppIntents

private let accent = Color(red: 0.12, green: 0.42, blue: 0.33)
private let accentLight = Color(red: 0.18, green: 0.59, blue: 0.45)

// MARK: - Tidslinje

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snap: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let s = current()
        completion(Entry(date: .now, snap: (context.isPreview && s.items.isEmpty) ? .preview : s))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        let next = min(midnight, Date().addingTimeInterval(3_600))
        completion(Timeline(entries: [Entry(date: .now, snap: current())], policy: .after(next)))
    }

    /// Poengene gjelder bare den dagen appen skrev dem.
    private func current() -> WidgetSnapshot {
        var s = Shared.loadSnapshot()
        if s.day != ShortDate.today {
            s.points = 0
            s.doneToday = 0
            s.urgentLeft = s.items.filter(\.urgent).count
        }
        return s
    }
}

private func taskURL(_ id: String) -> URL { URL(string: "gjoreliste://task/\(id)")! }
private let appURL = URL(string: "gjoreliste://open")!

// MARK: - Byggeklosser

struct CheckButton: View {
    let item: WidgetItem
    var size: CGFloat = 20
    var body: some View {
        Button(intent: CompleteTaskIntent(taskId: item.id)) {
            Image(systemName: "circle")
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(item.star ? Color.orange : accentLight)
        }
        .buttonStyle(.plain)
    }
}

struct TaskLine: View {
    let item: WidgetItem
    var showMeta = true
    var lines = 1
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CheckButton(item: item, size: 18)
            Link(destination: taskURL(item.id)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.t)
                        .font(.subheadline)
                        .lineLimit(lines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showMeta {
                        HStack(spacing: 6) {
                            Text(item.dueLabel)
                                .foregroundStyle(item.urgent ? Color.red : Color.secondary)
                            if item.minutes > 0 { Text("\(item.minutes) min") }
                            if !item.context.isEmpty { Text(item.context) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct PointsRing: View {
    let points: Int
    let goal: Int
    var body: some View {
        let frac = min(1, Double(points) / Double(max(goal, 1)))
        ZStack {
            Circle().stroke(accent.opacity(0.15), lineWidth: 7)
            Circle()
                .trim(from: 0, to: frac)
                .stroke(accentLight, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(points)").font(.system(.title2, design: .rounded).weight(.heavy)).foregroundStyle(accent)
                Text("poeng").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

struct EmptyState: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: snap.loggedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(accentLight)
            Text(snap.loggedIn ? "Alt er gjort. Ta fri." : "Åpne appen og logg inn")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hjemskjermen

struct HomeView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var snap: WidgetSnapshot { entry.snap }

    private var header: some View {
        HStack(alignment: .center) {
            ZStack {
                Circle().fill(accentLight)
                Image("Glyph").resizable().scaledToFit().foregroundStyle(.white).padding(6)
            }
            .frame(width: 28, height: 28)
            Spacer()
            Text("\(snap.urgentLeft)")
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(accent)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(snap.urgentLeft > 0 ? "Gjør først" : "Neste")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if snap.items.isEmpty {
                EmptyState(snap: snap)
            } else {
                ForEach(snap.items.prefix(3)) { item in
                    HStack(alignment: .top, spacing: 6) {
                        CheckButton(item: item, size: 16)
                        Text(item.t).font(.caption).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(appURL)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                PointsRing(points: snap.points, goal: snap.goal)
                    .frame(width: 74, height: 74)
                Text("\(snap.doneToday) gjort")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 84)
            VStack(alignment: .leading, spacing: 7) {
                if snap.items.isEmpty {
                    EmptyState(snap: snap)
                } else {
                    ForEach(snap.items.prefix(4)) { item in
                        TaskLine(item: item, showMeta: false)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .widgetURL(appURL)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PointsRing(points: snap.points, goal: snap.goal)
                    .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.urgentLeft > 0 ? "Gjør disse først" : "Neste")
                        .font(.headline)
                    Text(snap.points >= snap.goal
                         ? "\(snap.doneToday) gjort · dagsmålet nådd!"
                         : "\(snap.doneToday) gjort · \(snap.goal - snap.points) til dagsmålet")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            if snap.items.isEmpty {
                EmptyState(snap: snap)
            } else {
                ForEach(snap.items.prefix(6)) { item in
                    TaskLine(item: item, showMeta: true)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(appURL)
    }
}

struct HomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GjorelisteHome", provider: Provider()) { entry in
            HomeView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Gjøreliste")
        .description("Det du bør gjøre først. Trykk på sirkelen for å krysse av.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Låseskjermen

struct IconView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("Glyph")
                .resizable()
                .scaledToFit()
                .padding(11)
                .widgetAccentable()
        }
        .widgetURL(appURL)
    }
}

struct IconWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GjorelisteIcon", provider: Provider()) { _ in
            IconView().containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Åpne Gjøreliste")
        .description("Ikonet. Trykk for å åpne lista.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct NextView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        let snap = entry.snap
        let first = snap.items.first
        switch family {
        case .accessoryInline:
            if let first {
                Label(snap.urgentLeft > 1 ? "\(snap.urgentLeft) i dag · \(first.t)" : first.t, image: "Glyph")
                    .widgetURL(taskURL(first.id))
            } else {
                Label("Alt er gjort", image: "Glyph").widgetURL(appURL)
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image("Glyph").resizable().scaledToFit().frame(width: 12, height: 12)
                    Text(snap.urgentLeft > 0 ? "\(snap.urgentLeft) i dag" : "Neste")
                        .font(.caption2.weight(.bold))
                    Spacer(minLength: 0)
                    if snap.points > 0 {
                        Text("\(snap.points) p").font(.caption2.monospaced())
                    }
                }
                .widgetAccentable()
                if let first {
                    Text(first.t)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                } else {
                    Text(snap.loggedIn ? "Alt er gjort" : "Åpne appen")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(first.map { taskURL($0.id) } ?? appURL)
        }
    }
}

struct NextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GjorelisteNext", provider: Provider()) { entry in
            NextView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Neste oppgave")
        .description("Den øverste oppgaven i lista. Trykk for å åpne den.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Knapp på låst skjerm og i kontrollsenteret

struct OpenControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "no.sparhell.gjoreliste.open") {
            ControlWidgetButton(action: OpenGjorelisteIntent()) {
                Label("Gjøreliste", systemImage: "checklist")
            }
        }
        .displayName("Gjøreliste")
        .description("Åpner gjørelista.")
    }
}

// MARK: - Samling

@main
struct GjorelisteWidgetBundle: WidgetBundle {
    var body: some Widget {
        HomeWidget()
        IconWidget()
        NextWidget()
        OpenControl()
    }
}
