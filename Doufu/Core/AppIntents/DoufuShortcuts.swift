//
//  DoufuShortcuts.swift
//  Doufu
//

import AppIntents

struct DoufuShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenProjectIntent(),
            phrases: [
                "Open \(\.$project) in \(.applicationName)",
                "在 \(.applicationName) 中打开 \(\.$project)"
            ],
            shortTitle: LocalizedStringResource("shortcuts.open_project.title", defaultValue: "Open Project"),
            systemImageName: "folder"
        )
    }
}
