//
//  HomeViewController.swift
//  Doufu
//
//  Created by Salley Garden on 2026/02/14.
//

import UIKit
import GRDB
import UniformTypeIdentifiers

private struct HomeProjectItem: Hashable {
    let id: String
    let name: String
    let summary: String
    let createdAt: Date
    let updatedAt: Date
    let projectURL: URL
    let previewImagePath: String?
    let sortOrder: Int
    let activityState: ProjectActivityStore.State
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
    private var isSearchActive = false
    private let projectActivityStore = ProjectActivityStore.shared
    private let projectChangeCenter = ProjectChangeCenter.shared
    private let coordinator = ProjectLifecycleCoordinator.shared
    private let archiveImportService = ProjectArchiveImportService.shared
    private let archiveExportService = ProjectArchiveExportService.shared
    private let projectTransitionDelegate = ProjectOpenTransitionDelegate()
    private var selectedCellIndexPath: IndexPath?
    private var projectActivityObserver: NSObjectProtocol?
    private var projectChangeObserver: NSObjectProtocol?
    private var importTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

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
        view.backgroundColor = .doufuBackground
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.dragDelegate = self
        view.dropDelegate = self
        view.dragInteractionEnabled = true
        view.register(ProjectCardCell.self, forCellWithReuseIdentifier: ProjectCardCell.reuseIdentifier)
        view.register(AddProjectCardCell.self, forCellWithReuseIdentifier: AddProjectCardCell.reuseIdentifier)
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


    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigation()
        configureViewHierarchy()
        projectActivityObserver = projectActivityStore.addObserver { [weak self] _ in
            self?.reloadProjects()
        }
        projectChangeObserver = projectChangeCenter.addObserver { [weak self] _ in
            self?.reloadProjects()
        }
        reloadProjects()
    }

    deinit {
        importTask?.cancel()
        exportTask?.cancel()
        if let projectActivityObserver {
            NotificationCenter.default.removeObserver(projectActivityObserver)
        }
        if let projectChangeObserver {
            NotificationCenter.default.removeObserver(projectChangeObserver)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProjects()
    }

    private func configureNavigation() {
        title = String(localized: "home.title")
        navigationController?.navigationBar.prefersLargeTitles = false

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(didTapImportButton)
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = String(
            localized: "home.menu.import_project",
            defaultValue: "Import Project"
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            style: .plain,
            target: self,
            action: #selector(didTapMoreButton)
        )
        definesPresentationContext = true
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .doufuBackground
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

    private func didTapAddButton() {
        Task {
            do {
                let project = try await coordinator.createProject()
                reloadProjects()
                openProject(project, cellIndexPath: nil)
            } catch {
                showPlaceholderAlert(title: String(localized: "home.alert.create_failed.title"), message: error.localizedDescription)
            }
        }
    }

    @objc
    private func didTapMoreButton() {
        let controller = SettingsViewController()
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc
    private func didTapImportButton() {
        presentImportPicker()
    }

    private func presentImportPicker() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: Self.supportedImportTypes,
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    func importProjectArchive(from url: URL) {
        importTask?.cancel()
        importTask = Task { [weak self] in
            guard let self else { return }
            defer { self.importTask = nil }

            do {
                // Phase 1: Extract to temp for preview — project is NOT created yet
                let preview = try await self.archiveImportService.extractForPreview(from: url)
                guard !Task.isCancelled else {
                    self.archiveImportService.cleanupPreview(preview)
                    return
                }
                self.presentImportScanVC(preview: preview)
            } catch is CancellationError {
                return
            } catch {
                self.showPlaceholderAlert(
                    title: String(
                        localized: "home.alert.import_failed.title",
                        defaultValue: "Import Failed"
                    ),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func exportProject(_ project: HomeProjectItem, kind: ProjectArchiveExportService.ArchiveKind) {
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }

            let appURL = project.projectURL.appendingPathComponent("App", isDirectory: true)
            let projectRootURL = project.projectURL

            do {
                let payload = try await self.archiveExportService.exportArchive(
                    kind: kind,
                    projectName: project.name,
                    appURL: appURL,
                    projectRootURL: projectRootURL
                )
                guard !Task.isCancelled else {
                    for url in payload.cleanupURLs { try? FileManager.default.removeItem(at: url) }
                    return
                }

                let activity = UIActivityViewController(activityItems: [payload.archiveURL], applicationActivities: nil)
                activity.completionWithItemsHandler = { _, _, _, _ in
                    for url in payload.cleanupURLs { try? FileManager.default.removeItem(at: url) }
                }
                self.present(activity, animated: true)
            } catch is CancellationError {
                return
            } catch {
                self.showPlaceholderAlert(
                    title: String(localized: "home.alert.export_failed.title", defaultValue: "Export Failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private static let supportedImportTypes: [UTType] = [
        UTType(exportedAs: "com.zizicici.doufu.archive"),
        UTType(exportedAs: "com.zizicici.doufull.archive"),
    ]

    private func presentImportScanVC(preview: ProjectArchiveImportService.PreviewResult) {
        let scanVC = ImportScanViewController(preview: preview)

        scanVC.onConfirmImport = { [weak self] preview in
            guard let self else { return }
            self.dismiss(animated: true) {
                self.completeImportAfterScan(preview: preview)
            }
        }

        scanVC.onCancel = { [weak self] in
            guard let self else { return }
            self.archiveImportService.cleanupPreview(preview)
            self.dismiss(animated: true)
        }

        let nav = UINavigationController(rootViewController: scanVC)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func completeImportAfterScan(preview: ProjectArchiveImportService.PreviewResult) {
        importTask?.cancel()
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.importTask = nil
                self.archiveImportService.cleanupPreview(preview)
            }

            do {
                let result = try await self.archiveImportService.completeImport(preview: preview)
                guard !Task.isCancelled else { return }
                self.reloadProjects()
                self.openProject(result.project, cellIndexPath: nil)
            } catch is CancellationError {
                return
            } catch {
                self.showPlaceholderAlert(
                    title: String(
                        localized: "home.alert.import_failed.title",
                        defaultValue: "Import Failed"
                    ),
                    message: error.localizedDescription
                )
            }
        }
    }

    private var reloadTask: Task<Void, Never>?

    private func reloadProjects() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.loadProjectItems()
            guard !Task.isCancelled else { return }
            self.allProjects = items
            self.updateSearchBarVisibility()
            self.applyFilter(using: self.searchController.searchBar.text)
        }
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

    /// Loads project records from the database and checks file existence off
    /// the main thread.  Activity state is queried on @MainActor afterwards.
    private func loadProjectItems() async -> [HomeProjectItem] {
        // Capture values needed off-main-thread.
        guard let dbPool = DatabaseManager.shared.dbPool else {
            assertionFailure("Database is unavailable before Home projects load")
            return []
        }

        struct ProjectDiskInfo: Sendable {
            let id: String
            let name: String
            let summary: String
            let createdAt: Date
            let updatedAt: Date
            let projectURL: URL
            let previewImagePath: String?
            let sortOrder: Int
        }

        let noDescription = String(localized: "home.project.no_description")

        let diskItems: [ProjectDiskInfo] = await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            guard let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return []
            }
            let projectsRootURL = documentURL.appendingPathComponent("Projects", isDirectory: true)

            guard let dbProjects = try? dbPool.read({ db in
                try DBProject.order(DBProject.Columns.sortOrder.asc, DBProject.Columns.updatedAt.desc).fetchAll(db)
            }) else {
                return []
            }

            var results: [ProjectDiskInfo] = []
            for dbProject in dbProjects {
                let projectURL = projectsRootURL.appendingPathComponent(dbProject.id, isDirectory: true)
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let name = dbProject.title.isEmpty ? dbProject.id : dbProject.title
                let summary = dbProject.description.isEmpty ? noDescription : dbProject.description
                let createdAt = Date(timeIntervalSince1970: Double(dbProject.createdAt) / 1_000_000_000)
                let updatedAt = Date(timeIntervalSince1970: Double(dbProject.updatedAt) / 1_000_000_000)
                let previewImagePath = Self.findPreviewImagePath(in: projectURL)

                results.append(ProjectDiskInfo(
                    id: dbProject.id,
                    name: name,
                    summary: summary,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    projectURL: projectURL,
                    previewImagePath: previewImagePath,
                    sortOrder: dbProject.sortOrder
                ))
            }
            return results
        }.value

        // Back on MainActor — query activity state.
        return diskItems.map { info in
            HomeProjectItem(
                id: info.id,
                name: info.name,
                summary: info.summary,
                createdAt: info.createdAt,
                updatedAt: info.updatedAt,
                projectURL: info.projectURL,
                previewImagePath: info.previewImagePath,
                sortOrder: info.sortOrder,
                activityState: projectActivityStore.state(for: info.id)
            )
        }
    }

    private nonisolated static func findPreviewImagePath(in projectURL: URL) -> String? {
        let fileManager = FileManager.default
        let candidates = ["preview.jpg", "preview.jpeg"]

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

        isSearchActive = !keyword.isEmpty

        if keyword.isEmpty {
            filteredProjects = allProjects
        } else {
            filteredProjects = allProjects.filter { project in
                project.name.lowercased().contains(keyword) || project.summary.lowercased().contains(keyword)
            }
        }

        collectionView.reloadData()
        updateEmptyState(for: keyword)
    }

    private func saveCustomProjectOrder(_ orderedIDs: [String]) {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            assertionFailure("Database is unavailable before saving project order")
            return
        }
        try? dbPool.write { db in
            for (index, projectID) in orderedIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE project SET sort_order = ? WHERE id = ?",
                    arguments: [index, projectID]
                )
            }
        }
    }

    private func openProjectSettings(_ project: HomeProjectItem) {
        let controller = ProjectSettingsViewController(projectURL: project.projectURL, projectName: project.name)

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
        Task {
            do {
                try await coordinator.deleteProject(projectID: project.id, projectURL: project.projectURL)
                reloadProjects()
            } catch {
                showPlaceholderAlert(title: String(localized: "home.alert.delete_failed.title"), message: error.localizedDescription)
            }
        }
    }

    private func updateEmptyState(for keyword: String) {
        // Only show empty state for search with no results (the add card is always visible otherwise)
        if !keyword.isEmpty && filteredProjects.isEmpty {
            emptyStateLabel.text = String(localized: "home.empty.no_match")
            emptyStateContainer.isHidden = false
        } else {
            emptyStateContainer.isHidden = true
        }
    }

    private func openProject(_ project: HomeProjectItem, at indexPath: IndexPath? = nil) {
        let record = AppProjectRecord(
            id: project.id,
            name: project.name,
            projectURL: project.projectURL,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
        let initialRoute: ProjectWorkspaceViewController.InitialRoute
        switch project.activityState {
        case .needsConfirmation, .error:
            initialRoute = .chat
        case .idle, .building, .newVersionAvailable:
            initialRoute = .workspace
        }
        openProject(record, cellIndexPath: indexPath, initialRoute: initialRoute)
    }

    private func openProject(
        _ project: AppProjectRecord,
        cellIndexPath: IndexPath? = nil,
        initialRoute: ProjectWorkspaceViewController.InitialRoute = .workspace
    ) {
        // Compute origin frame from the tapped cell
        if let indexPath = cellIndexPath,
           let cell = collectionView.cellForItem(at: indexPath) {
            let frameInWindow = cell.convert(cell.bounds, to: view.window)
            projectTransitionDelegate.originFrame = frameInWindow
            projectTransitionDelegate.originCornerRadius = cell.contentView.layer.cornerRadius
            selectedCellIndexPath = indexPath
        } else {
            // Fallback: center rect
            let center = view.center
            projectTransitionDelegate.originFrame = CGRect(x: center.x - 60, y: center.y - 60, width: 120, height: 120)
            projectTransitionDelegate.originCornerRadius = 14
            selectedCellIndexPath = nil
        }

        let controller = ProjectWorkspaceViewController(
            project: project,
            initialRoute: initialRoute
        )
        controller.modalPresentationStyle = .fullScreen
        controller.transitioningDelegate = projectTransitionDelegate
        controller.onDismissed = { [weak self] in
            self?.reloadProjects()
        }
        present(controller, animated: true)
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
        isSearchActive ? filteredProjects.count : filteredProjects.count + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if indexPath.item == filteredProjects.count {
            return collectionView.dequeueReusableCell(
                withReuseIdentifier: AddProjectCardCell.reuseIdentifier,
                for: indexPath
            )
        }

        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ProjectCardCell.reuseIdentifier,
                for: indexPath
            ) as? ProjectCardCell
        else {
            return UICollectionViewCell()
        }

        let project = filteredProjects[indexPath.item]
        cell.configure(project: project)
        return cell
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if indexPath.item == filteredProjects.count {
            didTapAddButton()
            return
        }
        let project = filteredProjects[indexPath.item]
        openProject(project, at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPath.item < filteredProjects.count else { return nil }
        let project = filteredProjects[indexPath.item]

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else {
                return UIMenu(title: "", children: [])
            }

            let exportDoufuAction = UIAction(
                title: ".doufu",
                subtitle: String(localized: "home.menu.export.doufu.subtitle", defaultValue: "Code only")
            ) { _ in
                self.exportProject(project, kind: .doufu)
            }

            let exportDoufullAction = UIAction(
                title: ".doufull",
                subtitle: String(localized: "home.menu.export.doufull.subtitle", defaultValue: "Code and data")
            ) { _ in
                self.exportProject(project, kind: .doufull)
            }

            let exportMenu = UIMenu(
                title: String(localized: "home.menu.export", defaultValue: "Export"),
                image: UIImage(systemName: "square.and.arrow.up"),
                children: [exportDoufuAction, exportDoufullAction]
            )

            let settingsAction = UIAction(title: String(localized: "home.menu.settings"), image: UIImage(systemName: "gearshape")) { _ in
                self.openProjectSettings(project)
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
                    exportMenu,
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
        // Preview: (itemWidth - 16) * screenAspectRatio, plus padding (8 top + 8 gap + ~30 title + 8 bottom)
        let screenRatio = UIScreen.main.bounds.height / UIScreen.main.bounds.width
        let previewWidth = itemWidth - 16 // 8pt padding on each side
        let previewHeight = previewWidth * screenRatio
        let itemHeight = 8 + previewHeight + 8 + 30 + 8 // top + preview + gap + title + bottom
        return CGSize(width: itemWidth, height: itemHeight)
    }
}

extension HomeViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard !isSearchActive, indexPath.item < filteredProjects.count else { return [] }
        let project = filteredProjects[indexPath.item]
        let itemProvider = NSItemProvider(object: project.id as NSString)
        return [UIDragItem(itemProvider: itemProvider)]
    }
}

extension HomeViewController: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        !isSearchActive
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard collectionView.hasActiveDrag else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        guard let destination = destinationIndexPath, destination.item <= filteredProjects.count else {
            return UICollectionViewDropProposal(operation: .cancel)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: UICollectionViewDropCoordinator
    ) {
        guard let item = coordinator.items.first,
              let sourceIndexPath = item.sourceIndexPath,
              sourceIndexPath.item < filteredProjects.count else { return }

        let destinationIndexPath = coordinator.destinationIndexPath ?? IndexPath(item: filteredProjects.count - 1, section: 0)
        // Clamp to last project position (don't land on AddProjectCardCell)
        let destItem = min(destinationIndexPath.item, filteredProjects.count - 1)

        guard sourceIndexPath.item != destItem else { return }

        let movedProject = allProjects.remove(at: sourceIndexPath.item)
        allProjects.insert(movedProject, at: destItem)
        filteredProjects = allProjects

        let finalIndexPath = IndexPath(item: destItem, section: 0)
        collectionView.performBatchUpdates {
            collectionView.moveItem(at: sourceIndexPath, to: finalIndexPath)
        }
        coordinator.drop(item.dragItem, toItemAt: finalIndexPath)

        saveCustomProjectOrder(allProjects.map(\.id))
    }
}

extension HomeViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        importProjectArchive(from: url)
    }
}

private final class ProjectCardCell: UICollectionViewCell {

    static let reuseIdentifier = "ProjectCardCell"

    /// Screen aspect ratio used for preview thumbnail (e.g. 19.5:9 ≈ 2.16).
    private static let screenAspectRatio: CGFloat = {
        let screen = UIScreen.main.bounds
        return max(screen.height, screen.width) / min(screen.height, screen.width)
    }()

    private let previewShadowView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.08
        view.layer.shadowRadius = 4
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        return view
    }()

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

    private let activityBadgeLabel: InsetLabel = {
        let label = InsetLabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textAlignment = .center
        label.layer.cornerRadius = 9
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .doufuText
        label.numberOfLines = 2
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
        activityBadgeLabel.isHidden = true
        activityBadgeLabel.text = nil
    }

    func configure(project: HomeProjectItem) {
        titleLabel.text = project.name

        if let previewImagePath = project.previewImagePath, let image = UIImage(contentsOfFile: previewImagePath) {
            previewImageView.image = image
            placeholderIconView.isHidden = true
        } else {
            previewImageView.image = nil
            placeholderIconView.isHidden = false
        }

        switch project.activityState {
        case .idle:
            activityBadgeLabel.isHidden = true
        case .building:
            activityBadgeLabel.text = String(localized: "home.project.activity.building")
            activityBadgeLabel.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.96)
            activityBadgeLabel.textColor = .white
            activityBadgeLabel.isHidden = false
        case .newVersionAvailable:
            activityBadgeLabel.text = String(localized: "home.project.activity.new_version")
            activityBadgeLabel.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.96)
            activityBadgeLabel.textColor = .white
            activityBadgeLabel.isHidden = false
        case .needsConfirmation:
            activityBadgeLabel.text = String(localized: "home.project.activity.needs_confirmation")
            activityBadgeLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.96)
            activityBadgeLabel.textColor = .white
            activityBadgeLabel.isHidden = false
        case .error:
            activityBadgeLabel.text = String(localized: "home.project.activity.error")
            activityBadgeLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.96)
            activityBadgeLabel.textColor = .white
            activityBadgeLabel.isHidden = false
        }
    }

    private func configureViewHierarchy() {
        // Cell background + shadow via UIBackgroundConfiguration
        var bgConfig = UIBackgroundConfiguration.clear()
        bgConfig.backgroundColor = .doufuPaper
        bgConfig.cornerRadius = 14
        bgConfig.shadowProperties.color = .black
        bgConfig.shadowProperties.opacity = 0.15
        bgConfig.shadowProperties.radius = 6
        bgConfig.shadowProperties.offset = CGSize(width: 0, height: 3)
        backgroundConfiguration = bgConfig

        contentView.addSubview(previewShadowView)
        previewShadowView.addSubview(previewContainer)
        previewContainer.addSubview(previewImageView)
        previewContainer.addSubview(placeholderIconView)
        previewContainer.addSubview(activityBadgeLabel)
        contentView.addSubview(titleLabel)
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            previewShadowView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            previewShadowView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            previewShadowView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            previewShadowView.heightAnchor.constraint(
                equalTo: previewShadowView.widthAnchor,
                multiplier: Self.screenAspectRatio
            ),

            previewContainer.topAnchor.constraint(equalTo: previewShadowView.topAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: previewShadowView.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: previewShadowView.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: previewShadowView.bottomAnchor),

            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            placeholderIconView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholderIconView.widthAnchor.constraint(equalToConstant: 24),
            placeholderIconView.heightAnchor.constraint(equalToConstant: 24),

            activityBadgeLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            activityBadgeLabel.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: previewShadowView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8)
        ])
    }
}

private final class InsetLabel: UILabel {
    var contentInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

    override var intrinsicContentSize: CGSize {
        let baseSize = super.intrinsicContentSize
        return CGSize(
            width: baseSize.width + contentInsets.left + contentInsets.right,
            height: baseSize.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }
}

private final class AddProjectCardCell: UICollectionViewCell {

    static let reuseIdentifier = "AddProjectCardCell"

    private static let screenAspectRatio: CGFloat = {
        let screen = UIScreen.main.bounds
        return max(screen.height, screen.width) / min(screen.height, screen.width)
    }()

    private let placeholderView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemGray6
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let plusIcon: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        let imageView = UIImageView(image: UIImage(systemName: "plus", withConfiguration: config))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .doufuText
        label.text = String(localized: "home.add_project.title")
        label.numberOfLines = 1
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        var bgConfig = UIBackgroundConfiguration.clear()
        bgConfig.backgroundColor = .doufuPaper
        bgConfig.cornerRadius = 14
        bgConfig.shadowProperties.color = .black
        bgConfig.shadowProperties.opacity = 0.15
        bgConfig.shadowProperties.radius = 6
        bgConfig.shadowProperties.offset = CGSize(width: 0, height: 3)
        backgroundConfiguration = bgConfig

        contentView.addSubview(placeholderView)
        placeholderView.addSubview(plusIcon)
        contentView.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            placeholderView.heightAnchor.constraint(
                equalTo: placeholderView.widthAnchor,
                multiplier: Self.screenAspectRatio
            ),

            plusIcon.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            plusIcon.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: placeholderView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
