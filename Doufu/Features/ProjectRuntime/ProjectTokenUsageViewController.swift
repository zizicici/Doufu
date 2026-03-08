//
//  ProjectTokenUsageViewController.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

@MainActor
final class ProjectTokenUsageViewController: TokenUsageDashboardViewController {
    init(projectUsageIdentifier: String) {
        super.init(
            titleText: String(localized: "chat.project_usage.title"),
            projectIdentifier: projectUsageIdentifier,
            includeDoneButton: true
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
