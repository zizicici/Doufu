//
//  OnboardingViewController.swift
//  Doufu
//

import UIKit

fileprivate nonisolated enum OnboardingSectionID: Int, Hashable, Sendable {
    case item0 = 0, item1, item2, item3
}

fileprivate nonisolated enum OnboardingItemID: Int, Hashable, Sendable {
    case item0 = 0, item1, item2, item3
}

@MainActor
final class OnboardingViewController: UIViewController {

    var onCompleted: (() -> Void)?

    private struct OnboardingItem {
        let titleKey: String.LocalizationValue
        let subtitleKey: String.LocalizationValue
    }

    private let items: [OnboardingItem] = [
        OnboardingItem(
            titleKey: "onboarding.item.llm_generation.title",
            subtitleKey: "onboarding.item.llm_generation.subtitle"
        ),
        OnboardingItem(
            titleKey: "onboarding.item.permissions.title",
            subtitleKey: "onboarding.item.permissions.subtitle"
        ),
        OnboardingItem(
            titleKey: "onboarding.item.third_party.title",
            subtitleKey: "onboarding.item.third_party.subtitle"
        ),
        OnboardingItem(
            titleKey: "onboarding.item.import_review.title",
            subtitleKey: "onboarding.item.import_review.subtitle"
        ),
    ]

    private static let allSections: [OnboardingSectionID] = [.item0, .item1, .item2, .item3]
    private static let allItems: [OnboardingItemID] = [.item0, .item1, .item2, .item3]

    private var revealedCount = 0
    private var diffableDataSource: UITableViewDiffableDataSource<OnboardingSectionID, OnboardingItemID>!

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .doufuBackground
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.separatorStyle = .none
        return tv
    }()

    private lazy var actionButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "onboarding.button.next")
        config.cornerStyle = .large
        config.baseBackgroundColor = .label
        config.baseForegroundColor = .systemBackground
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 0, bottom: 14, trailing: 0)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(didTapAction), for: .touchUpInside)
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "onboarding.title")
        view.backgroundColor = .doufuBackground

        view.addSubview(tableView)
        view.addSubview(actionButton)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -16),

            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            actionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        configureDiffableDataSource()
        revealNext()
    }

    // MARK: - DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = UITableViewDiffableDataSource(tableView: tableView) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            cell.selectionStyle = .none
            let item = self.items[itemID.rawValue]
            var config = UIListContentConfiguration.subtitleCell()
            config.text = String(localized: item.titleKey)
            config.secondaryText = String(localized: item.subtitleKey)
            config.textProperties.font = .preferredFont(forTextStyle: .title3, weight: .semibold)
            config.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 0
            config.textToSecondaryTextVerticalPadding = 4
            cell.contentConfiguration = config
            return cell
        }
        diffableDataSource.defaultRowAnimation = .fade

        let snapshot = NSDiffableDataSourceSnapshot<OnboardingSectionID, OnboardingItemID>()
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Actions

    @objc
    private func didTapAction() {
        if revealedCount < items.count {
            revealNext()
        } else {
            onCompleted?()
        }
    }

    private func revealNext() {
        guard revealedCount < items.count else { return }

        let section = Self.allSections[revealedCount]
        let item = Self.allItems[revealedCount]
        revealedCount += 1

        var snapshot = diffableDataSource.snapshot()
        snapshot.appendSections([section])
        snapshot.appendItems([item], toSection: section)
        diffableDataSource.apply(snapshot, animatingDifferences: true)

        if revealedCount == items.count {
            actionButton.configuration?.title = String(localized: "onboarding.button.start")
        }
    }
}
