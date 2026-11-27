import WidgetKit
import SwiftUI
import AppIntents

@main
struct ReferatWidgets: WidgetBundle {
    var body: some Widget {
        ReferatLockWidget()
        StartRecordingControl()
    }
}

// MARK: - Låseskjerm-widget: ikon som åpner appen

struct SimpleEntry: TimelineEntry { let date: Date }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }
}

struct ReferatLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReferatLock", provider: Provider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
            }
            .widgetURL(URL(string: "referat://open"))
            .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Referat")
        .description("Åpner Referat.")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - Kontroll for låseskjermen og Kontrollsenter: starter opptak med en gang

struct StartRecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "no.sparhell.motelogg.start") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Start opptak", systemImage: "record.circle")
            }
        }
        .displayName("Start opptak")
        .description("Starter opptak i Referat med en gang.")
    }
}

/// Samme handling som i appen. Når den kjøres, åpnes Referat og appens versjon starter opptaket.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start opptak"
    static let description = IntentDescription("Åpner Referat og starter opptak med en gang.")
    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
