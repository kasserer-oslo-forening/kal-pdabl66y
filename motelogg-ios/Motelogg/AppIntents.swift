import AppIntents
import Observation

/// Signal fra låseskjerm-kontrollen, Snarveier eller Action-knappen om å starte opptak.
@MainActor
@Observable
final class LaunchAction {
    static let shared = LaunchAction()
    var startRequested = false
}

/// Åpner Referat og starter opptak med en gang.
/// Samme type finnes i widget-utvidelsen, så låseskjerm-kontrollen kan bruke den.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start opptak"
    static let description = IntentDescription("Åpner Referat og starter opptak med en gang.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchAction.shared.startRequested = true
        return .result()
    }
}

/// Gjør handlingen tilgjengelig i Snarveier, for Siri og for Action-knappen.
struct ReferatShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start opptak i \(.applicationName)", "Ta opp med \(.applicationName)"],
            shortTitle: "Start opptak",
            systemImageName: "record.circle"
        )
    }
}
