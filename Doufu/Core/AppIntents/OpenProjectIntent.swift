//
//  OpenProjectIntent.swift
//  Doufu
//

import AppIntents

struct OpenProjectIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource("shortcuts.open_project.title", defaultValue: "Open Project")

    static var description: IntentDescription = IntentDescription(LocalizedStringResource("shortcuts.open_project.description", defaultValue: "Opens a project in Doufu"))

    static var openAppWhenRun: Bool = true

    static var pendingProjectID: String?

    static let openProjectNotification = Notification.Name("OpenProjectIntentNotification")

    @Parameter(title: LocalizedStringResource("shortcuts.open_project.parameter.project", defaultValue: "Project"))
    var project: ProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.pendingProjectID = project.id
        NotificationCenter.default.post(
            name: Self.openProjectNotification,
            object: nil,
            userInfo: ["projectID": project.id]
        )
        return .result()
    }
}
