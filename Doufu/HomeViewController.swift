//
//  HomeViewController.swift
//  Doufu
//
//  Created by Salley Garden on 2026/02/14.
//

import UIKit

private struct HomeProjectItem: Hashable {
    let id: String
    let name: String
    let summary: String
    let updatedAt: Date
    let projectURL: URL
    let previewImagePath: String?
}

final class HomeViewController: UIViewController {

    private enum LayoutMetric {
        static let columns: CGFloat = 3
        static let horizontalPadding: CGFloat = 16
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 20
        static let itemSpacing: CGFloat = 10
    }

    private var allProjects: [HomeProjectItem] = []
    private var filteredProjects: [HomeProjectItem] = []
    private let projectStore = AppProjectStore.shared
    private let defaults = UserDefaults.standard
    private let customOrderKey = "home.project.custom_order.v1"
    private var customProjectOrder: [String] = []

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = LayoutMetric.itemSpacing
        layout.minimumInteritemSpacing = LayoutMetric.itemSpacing
        layout.sectionInset = UIEdgeInsets(
            top: LayoutMetric.topPadding,
            left: LayoutMetric.horizontalPadding,
            bottom: LayoutMetric.bottomPadding,
            right: LayoutMetric.horizontalPadding
        )

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.register(ProjectCardCell.self, forCellWithReuseIdentifier: ProjectCardCell.reuseIdentifier)
        return view
    }()

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = String(localized: "home.search.placeholder")
        controller.searchResultsUpdater = self
        return controller
    }()

    private lazy var emptyStateContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private lazy var emptyStateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.text = String(localized: "home.empty.default")
        return label
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigation()
        configureViewHierarchy()
        loadCustomProjectOrder()
        reloadProjects()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProjects()
    }

    private func configureNavigation() {
        title = String(localized: "home.title")
        navigationController?.navigationBar.prefersLargeTitles = false

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(didTapSettingsButton)
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(didTapAddButton)
        )
        definesPresentationContext = true
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .systemBackground
        view.addSubview(collectionView)
        view.addSubview(emptyStateContainer)
        emptyStateContainer.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            emptyStateLabel.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor, constant: -24),
            emptyStateLabel.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor)
        ])
    }

    @objc
    private func didTapAddButton() {
        do {
            let project = try projectStore.createBlankProject()
            reloadProjects()
            openProject(name: project.name, projectURL: project.projectURL, isNewlyCreated: true)
        } catch {
            showPlaceholderAlert(title: String(localized: "home.alert.create_failed.title"), message: error.localizedDescription)
        }
    }

    @objc
    private func didTapSettingsButton() {
        let controller = SettingsViewController()
        navigationController?.pushViewController(controller, animated: true)
    }

    private func reloadProjects() {
        allProjects = loadProjectsFromDisk()
        customProjectOrder = normalizedProjectOrder(from: customProjectOrder, projects: allProjects)
        saveCustomProjectOrder()
        updateSearchBarVisibility()
        applyFilter(using: searchController.searchBar.text)
    }

    private func updateSearchBarVisibility() {
        let hasProjects = !allProjects.isEmpty

        if hasProjects {
            if navigationItem.searchController == nil {
                navigationItem.searchController = searchController
            }
            navigationItem.hidesSearchBarWhenScrolling = false
            return
        }

        if searchController.isActive {
            searchController.isActive = false
        }
        if !(searchController.searchBar.text?.isEmpty ?? true) {
            searchController.searchBar.text = nil
        }
        navigationItem.searchController = nil
    }

    private func loadProjectsFromDisk() -> [HomeProjectItem] {
        let fileManager = FileManager.default
        guard let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }

        let projectsRootURL = documentURL.appendingPathComponent("AppProjects", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var projects: [HomeProjectItem] = []
        for projectURL in urls {
            let values = try? projectURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else {
                continue
            }

            let manifestURL = projectURL.appendingPathComponent("manifest.json")
            let manifest = loadManifest(from: manifestURL)
            let projectId = (manifest["projectId"] as? String) ?? projectURL.lastPathComponent
            let name = (manifest["name"] as? String) ?? projectURL.lastPathComponent
            let summary = (manifest["prompt"] as? String)
                ?? (manifest["description"] as? String)
                ?? String(localized: "home.project.no_description")
            let updatedAt = parseUpdatedAt(from: manifest) ?? values?.contentModificationDate ?? Date()
            let previewImagePath = findPreviewImagePath(in: projectURL)

            projects.append(
                HomeProjectItem(
                    id: projectId,
                    name: name,
                    summary: summary,
                    updatedAt: updatedAt,
                    projectURL: projectURL,
                    previewImagePath: previewImagePath
                )
            )
        }

        return projects
    }

    private func loadManifest(from url: URL) -> [String: Any] {
        guard
            let data = try? Data(contentsOf: url),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let json = rawObject as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    private func parseUpdatedAt(from manifest: [String: Any]) -> Date? {
        guard let rawValue = manifest["updatedAt"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: rawValue)
    }

    private func findPreviewImagePath(in projectURL: URL) -> String? {
        let fileManager = FileManager.default
        let candidates = ["preview.jpg", "preview.jpeg", "preview.png", "thumbnail.png", "snapshot.png"]

        for fileName in candidates {
            let imageURL = projectURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: imageURL.path) {
                return imageURL.path
            }
        }

        return nil
    }

    private func applyFilter(using query: String?) {
        let keyword = (query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if keyword.isEmpty {
            filteredProjects = allProjects
        } else {
            filteredProjects = allProjects.filter { project in
                project.name.lowercased().contains(keyword) || project.summary.lowercased().contains(keyword)
            }
        }
        filteredProjects = applyCustomOrder(to: filteredProjects)

        collectionView.reloadData()
        updateEmptyState(for: keyword)
    }

    private func loadCustomProjectOrder() {
        customProjectOrder = defaults.array(forKey: customOrderKey) as? [String] ?? []
    }

    private func saveCustomProjectOrder() {
        defaults.set(customProjectOrder, forKey: customOrderKey)
    }

    private func normalizedProjectOrder(from persistedOrder: [String], projects: [HomeProjectItem]) -> [String] {
        let existingIDs = Set(projects.map(\.id))
        var normalizedOrder: [String] = []
        var seen = Set<String>()

        for id in persistedOrder where existingIDs.contains(id) && !seen.contains(id) {
            normalizedOrder.append(id)
            seen.insert(id)
        }

        let tailIDs = projects
            .filter { !seen.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.updatedAt > rhs.updatedAt
            }
            .map(\.id)

        normalizedOrder.append(contentsOf: tailIDs)
        return normalizedOrder
    }

    private func applyCustomOrder(to projects: [HomeProjectItem]) -> [HomeProjectItem] {
        guard !projects.isEmpty else {
            return []
        }

        let lookup = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var ordered: [HomeProjectItem] = []
        var seen = Set<String>()

        for id in customProjectOrder {
            guard let project = lookup[id], !seen.contains(id) else {
                continue
            }
            ordered.append(project)
            seen.insert(id)
        }

        if ordered.count < projects.count {
            let remaining = projects
                .filter { !seen.contains($0.id) }
                .sorted { lhs, rhs in
                    lhs.updatedAt > rhs.updatedAt
                }
            ordered.append(contentsOf: remaining)
        }

        return ordered
    }

    private func updateCustomProjectOrder(_ orderedIDs: [String]) {
        customProjectOrder = normalizedProjectOrder(from: orderedIDs, projects: allProjects)
        saveCustomProjectOrder()
        applyFilter(using: searchController.searchBar.text)
    }

    private func openProjectSettings(_ project: HomeProjectItem) {
        let controller = ProjectSettingsViewController(projectURL: project.projectURL, projectName: project.name)
        controller.onProjectUpdated = { [weak self] _ in
            self?.reloadProjects()
        }

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func presentProjectSortPage() {
        let orderedProjects = applyCustomOrder(to: allProjects)
        let items = orderedProjects.map { project in
            ProjectSortViewController.Item(id: project.id, name: project.name)
        }

        let controller = ProjectSortViewController(items: items)
        controller.onDone = { [weak self] orderedIDs in
            self?.updateCustomProjectOrder(orderedIDs)
        }

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func presentDeleteConfirmation(for project: HomeProjectItem) {
        let alert = UIAlertController(
            title: String(localized: "home.alert.delete.title"),
            message: String(format: String(localized: "home.alert.delete.message_format"), project.name),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.action.delete"), style: .destructive, handler: { [weak self] _ in
            self?.deleteProject(project)
        }))
        present(alert, animated: true)
    }

    private func deleteProject(_ project: HomeProjectItem) {
        do {
            try projectStore.deleteProject(projectURL: project.projectURL)
            reloadProjects()
        } catch {
            showPlaceholderAlert(title: String(localized: "home.alert.delete_failed.title"), message: error.localizedDescription)
        }
    }

    private func updateEmptyState(for keyword: String) {
        emptyStateLabel.text = keyword.isEmpty
            ? String(localized: "home.empty.default")
            : String(localized: "home.empty.no_match")
        emptyStateContainer.isHidden = !filteredProjects.isEmpty
    }

    private func openProject(_ project: HomeProjectItem) {
        openProject(name: project.name, projectURL: project.projectURL, isNewlyCreated: false)
    }

    private func openProject(name: String, projectURL: URL, isNewlyCreated: Bool) {
        let controller = ProjectWorkspaceViewController(
            projectName: name,
            projectURL: projectURL,
            isNewlyCreated: isNewlyCreated
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func showPlaceholderAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

}

extension HomeViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        applyFilter(using: searchController.searchBar.text)
    }
}

extension HomeViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredProjects.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ProjectCardCell.reuseIdentifier,
                for: indexPath
            ) as? ProjectCardCell
        else {
            return UICollectionViewCell()
        }

        let project = filteredProjects[indexPath.item]
        let dateText = dateFormatter.string(from: project.updatedAt)
        cell.configure(project: project, dateText: dateText)
        return cell
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let project = filteredProjects[indexPath.item]
        openProject(project)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let project = filteredProjects[indexPath.item]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else {
                return UIMenu(title: "", children: [])
            }

            let settingsAction = UIAction(title: String(localized: "home.menu.settings"), image: UIImage(systemName: "gearshape")) { _ in
                self.openProjectSettings(project)
            }

            let sortAction = UIAction(title: String(localized: "home.menu.sort"), image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in
                self.presentProjectSortPage()
            }

            let deleteAction = UIAction(
                title: String(localized: "common.action.delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                self.presentDeleteConfirmation(for: project)
            }

            return UIMenu(
                title: "",
                children: [
                    settingsAction,
                    sortAction,
                    deleteAction
                ]
            )
        }
    }
}

extension HomeViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let totalSpacing = LayoutMetric.itemSpacing * (LayoutMetric.columns - 1)
        let availableWidth = collectionView.bounds.width
            - LayoutMetric.horizontalPadding * 2
            - totalSpacing
        let itemWidth = floor(availableWidth / LayoutMetric.columns)
        return CGSize(width: itemWidth, height: itemWidth * 1.22)
    }
}

private final class ProjectCardCell: UICollectionViewCell {

    static let reuseIdentifier = "ProjectCardCell"

    private let previewContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemGray6
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private let previewImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }()

    private let placeholderIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "doc.richtext"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 2
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewImageView.image = nil
        placeholderIconView.isHidden = false
    }

    func configure(project: HomeProjectItem, dateText: String) {
        titleLabel.text = project.name
        dateLabel.text = dateText

        if let previewImagePath = project.previewImagePath, let image = UIImage(contentsOfFile: previewImagePath) {
            previewImageView.image = image
            placeholderIconView.isHidden = true
        } else {
            previewImageView.image = nil
            placeholderIconView.isHidden = false
        }
    }

    private func configureViewHierarchy() {
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 0
        contentView.clipsToBounds = true

        contentView.addSubview(previewContainer)
        previewContainer.addSubview(previewImageView)
        previewContainer.addSubview(placeholderIconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(dateLabel)
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            previewContainer.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.63),

            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            placeholderIconView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholderIconView.widthAnchor.constraint(equalToConstant: 24),
            placeholderIconView.heightAnchor.constraint(equalToConstant: 24),

            titleLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            dateLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8)
        ])
    }
}
