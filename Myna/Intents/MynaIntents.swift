import AppIntents
import Foundation

// Siri, Shortcuts, the Action button and Spotlight can all reach Myna — handy
// when the phone is across the room from you but your Watch or AirPods aren't.

struct AddToShoppingListIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Shopping List"
    static var description = IntentDescription("Adds one or more things to Myna's shopping list.")

    @Parameter(title: "Items", requestValueDialog: "What should I add?")
    var items: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppServices.shared.brain.perform(
            .addItems(.shopping, CommandParser.splitItems(items)), heard: items, origin: .siri
        )
        return .result(dialog: "\(reply)")
    }
}

struct AddToDoIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a To-Do"
    static var description = IntentDescription("Adds a task to Myna's to-do list.")

    @Parameter(title: "Task", requestValueDialog: "What do you need to do?")
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppServices.shared.brain.perform(.addItems(.todo, [task]), heard: task, origin: .siri)
        return .result(dialog: "\(reply)")
    }
}

struct RemindMeIntent: AppIntent {
    static var title: LocalizedStringResource = "Remind Me"
    static var description = IntentDescription("Asks Myna to remind you of something, optionally at a time.")

    @Parameter(title: "Reminder", requestValueDialog: "What should I remind you about?")
    var reminder: String

    @Parameter(title: "When")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // "call Mom at 6" works as well as an explicit date.
        let spoken = TimePhrase.find(in: reminder)
        let text = date == nil ? (spoken?.remainder ?? reminder) : reminder
        let reply = await AppServices.shared.brain.perform(
            .remind(text.isEmpty ? reminder : text, at: date ?? spoken?.date, phrase: spoken?.phrase),
            heard: reminder,
            origin: .siri
        )
        return .result(dialog: "\(reply)")
    }
}

struct AskMynaIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Myna"
    static var description = IntentDescription("Ask Myna anything — about your conversations, lists or day — or tell it what to do.")
    static var openAppWhenRun = true

    @Parameter(title: "Request", requestValueDialog: "What can I do for you?")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await AppServices.shared.brain.handleTyped(request)
        return .result(dialog: "\(reply)")
    }
}

struct StartListeningIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Listening"
    static var description = IntentDescription("Opens Myna and starts listening.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let pilot = AppServices.shared.pilot
        if pilot.phase == .idle { pilot.startListening() }
        return .result()
    }
}

struct MynaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToShoppingListIntent(),
            phrases: [
                "Add to my \(.applicationName) shopping list",
                "Add to \(.applicationName) shopping list",
                "\(.applicationName) shopping list",
            ],
            shortTitle: "Add to Shopping",
            systemImageName: "cart.fill.badge.plus"
        )
        AppShortcut(
            intent: AddToDoIntent(),
            phrases: [
                "Add a to-do in \(.applicationName)",
                "Add a task to \(.applicationName)",
            ],
            shortTitle: "Add To-Do",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: RemindMeIntent(),
            phrases: [
                "Remind me with \(.applicationName)",
                "Set a \(.applicationName) reminder",
            ],
            shortTitle: "Remind Me",
            systemImageName: "bell.badge.fill"
        )
        AppShortcut(
            intent: AskMynaIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Talk to \(.applicationName)",
            ],
            shortTitle: "Ask Myna",
            systemImageName: "bubble.left.and.text.bubble.right.fill"
        )
        AppShortcut(
            intent: StartListeningIntent(),
            phrases: [
                "Start \(.applicationName)",
                "Start listening with \(.applicationName)",
            ],
            shortTitle: "Start Listening",
            systemImageName: "waveform"
        )
    }
}
