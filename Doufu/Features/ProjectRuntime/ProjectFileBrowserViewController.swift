//
//  ProjectFileBrowserViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import UIKit
import UniformTypeIdentifiers
#if canImport(Runestone)
import Runestone
#endif
#if canImport(TreeSitterJavaScriptRunestone)
import TreeSitterJavaScriptRunestone
#endif
#if canImport(TreeSitterTypeScriptRunestone)
import TreeSitterTypeScriptRunestone
#endif
#if canImport(TreeSitterTSXRunestone)
import TreeSitterTSXRunestone
#endif
#if canImport(TreeSitterJSONRunestone)
import TreeSitterJSONRunestone
#endif
#if canImport(TreeSitterHTMLRunestone)
import TreeSitterHTMLRunestone
#endif
#if canImport(TreeSitterCSSRunestone)
import TreeSitterCSSRunestone
#endif
#if canImport(TreeSitterMarkdownRunestone)
import TreeSitterMarkdownRunestone
#endif
#if canImport(TreeSitterSwiftRunestone)
import TreeSitterSwiftRunestone
#endif

@MainActor
final class ProjectFileBrowserViewController: UITableViewController {

    private enum ExportKind {
        case code
        case projectBackup
    }

    private struct Item {
        let name: String
        let url: URL
        let isDirectory: Bool
        let isHidden: Bool
        let fileSize: Int?
    }

    private let projectName: String
    private let rootURL: URL
    private let projectRootURL: URL?
    private let appURL: URL?
    private let directoryURL: URL
    private let showHiddenFiles: Bool
    private let readOnly: Bool
    private let directoryPickerMode: Bool
    private let excludedURL: URL?
    private var onDirectoryPicked: ((URL) -> Void)?
    private var items: [Item] = []
    private let fileManager: FileManager
    private let archiveExportService = ProjectArchiveExportService.shared
    private var exportTask: Task<Void, Never>?

    private var isInsideAppDirectory: Bool {
        let effectiveAppURL: URL
        if let appURL = appURL {
            effectiveAppURL = appURL
        } else if let projectRootURL = projectRootURL {
            effectiveAppURL = projectRootURL.appendingPathComponent("App", isDirectory: true)
        } else {
            return true
        }
        let appPath = effectiveAppURL.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = appPath.hasSuffix("/") ? appPath : appPath + "/"
        return dirPath == appPath || dirPath.hasPrefix(prefix)
    }

    private var projectID: String? {
        if let projectRootURL = projectRootURL {
            return projectRootURL.standardizedFileURL.lastPathComponent
        }
        return rootURL.standardizedFileURL.lastPathComponent
    }

    init(
        projectName: String,
        rootURL: URL,
        projectRootURL: URL? = nil,
        appURL: URL? = nil,
        directoryURL: URL? = nil,
        showHiddenFiles: Bool = false,
        readOnly: Bool = false,
        directoryPickerMode: Bool = false,
        excludedURL: URL? = nil,
        onDirectoryPicked: ((URL) -> Void)? = nil,
        fileManager: FileManager = .default
    ) {
        self.projectName = projectName
        self.rootURL = rootURL
        self.projectRootURL = projectRootURL
        self.appURL = appURL
        self.directoryURL = directoryURL ?? rootURL
        self.showHiddenFiles = showHiddenFiles
        self.readOnly = readOnly
        self.directoryPickerMode = directoryPickerMode
        self.excludedURL = excludedURL
        self.onDirectoryPicked = onDirectoryPicked
        self.fileManager = fileManager
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        exportTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleForCurrentDirectory()
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectFileRow")

        if directoryPickerMode {
            let selectStyle: UIBarButtonItem.Style = {
                if #available(iOS 26.0, *) { return .prominent }
                return .done
            }()
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: String(localized: "file_browser.move.select_directory"),
                style: selectStyle,
                target: self,
                action: #selector(didTapSelectDirectory)
            )
            if navigationController?.viewControllers.first === self {
                navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: String(localized: "common.action.cancel"),
                    style: .plain,
                    target: self,
                    action: #selector(didTapCancelPicker)
                )
            }
        } else {
            var rightItems: [UIBarButtonItem] = []
            if !readOnly, directoryURL.standardizedFileURL == rootURL.standardizedFileURL {
                rightItems.append(UIBarButtonItem(
                    image: UIImage(systemName: "square.and.arrow.up"),
                    style: .plain,
                    target: self,
                    action: #selector(didTapShare)
                ))
            }
            if !readOnly, isInsideAppDirectory {
                rightItems.append(UIBarButtonItem(
                    image: UIImage(systemName: "plus"),
                    style: .plain,
                    target: self,
                    action: #selector(didTapAdd)
                ))
            }
            if !rightItems.isEmpty {
                navigationItem.rightBarButtonItems = rightItems
            }
        }

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadItems()
    }

    private func titleForCurrentDirectory() -> String {
        if directoryURL.standardizedFileURL == rootURL.standardizedFileURL {
            return String(format: String(localized: "file_browser.title.root_format"), projectName)
        }
        let relative = relativePath(for: directoryURL)
        return relative.isEmpty ? directoryURL.lastPathComponent : relative
    }

    private func reloadItems() {
        do {
            items = try loadItems()
            tableView.reloadData()
        } catch {
            showLoadError(error.localizedDescription)
        }
    }

    private func loadItems() throws -> [Item] {
        let childURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsPackageDescendants]
        )

        let mapped: [Item] = childURLs.compactMap { childURL in
            guard isSafeChildURL(childURL) else {
                return nil
            }
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isHiddenKey])
            let hidden = values?.isHidden ?? false
            if hidden, !showHiddenFiles {
                return nil
            }

            let isDirectory = values?.isDirectory == true

            return Item(
                name: childURL.lastPathComponent,
                url: childURL,
                isDirectory: isDirectory,
                isHidden: hidden || childURL.lastPathComponent.hasPrefix("."),
                fileSize: values?.fileSize
            )
        }

        var filtered = directoryPickerMode ? mapped.filter(\.isDirectory) : mapped
        if let excludedURL {
            let excludedPath = excludedURL.standardizedFileURL.resolvingSymlinksInPath().path
            filtered = filtered.filter {
                $0.url.standardizedFileURL.resolvingSymlinksInPath().path != excludedPath
            }
        }

        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func isSafeChildURL(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        // Resolve only the parent directory (which exists on disk) and re-append the last component.
        // This avoids resolvingSymlinksInPath() failing to resolve /var → /private/var
        // for paths where the final component doesn't yet exist on disk.
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let childPath = parentPath + "/" + url.lastPathComponent
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return childPath.hasPrefix(prefix)
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if path.hasPrefix(prefix) {
            path.removeFirst(prefix.count)
        }
        return path
    }

    private func showLoadError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "file_browser.alert.load_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(items.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectFileRow", for: indexPath)
        var configuration = UIListContentConfiguration.valueCell()
        if items.isEmpty {
            configuration.text = String(localized: "file_browser.empty_directory")
            configuration.secondaryText = nil
            configuration.image = UIImage(systemName: "tray")
            cell.accessoryType = .none
        } else {
            let item = items[indexPath.row]
            if item.isHidden {
                let tag = String(localized: "file_browser.hidden_tag", defaultValue: "[hidden]")
                configuration.text = "\(tag) \(item.name)"
                configuration.textProperties.color = .secondaryLabel
            } else {
                configuration.text = item.name
            }
            if item.isDirectory {
                configuration.secondaryText = String(localized: "file_browser.item.folder")
                configuration.image = UIImage(systemName: "folder")
                cell.accessoryType = .disclosureIndicator
            } else {
                configuration.secondaryText = item.fileSize.map(Self.formatBytes(_:))
                    ?? String(localized: "file_browser.item.file")
                configuration.image = UIImage(systemName: "doc.text")
                cell.accessoryType = .disclosureIndicator
            }
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !items.isEmpty else {
            return
        }

        let item = items[indexPath.row]
        if item.isDirectory {
            let controller = ProjectFileBrowserViewController(
                projectName: projectName,
                rootURL: rootURL,
                projectRootURL: projectRootURL,
                appURL: appURL,
                directoryURL: item.url,
                showHiddenFiles: showHiddenFiles,
                readOnly: readOnly,
                directoryPickerMode: directoryPickerMode,
                excludedURL: excludedURL,
                onDirectoryPicked: onDirectoryPicked,
                fileManager: fileManager
            )
            navigationController?.pushViewController(controller, animated: true)
            return
        }

        if directoryPickerMode { return }

        let viewer = ProjectFileContentViewController(fileURL: item.url, rootURL: rootURL, readOnly: readOnly)
        navigationController?.pushViewController(viewer, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !readOnly, !directoryPickerMode, isInsideAppDirectory, !items.isEmpty else {
            return nil
        }
        let item = items[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return self.makeContextMenu(for: item)
        }
    }

    // MARK: - Share

    @objc private func didTapShare() {
        let alert = UIAlertController(
            title: String(localized: "home.menu.export", defaultValue: "Export"),
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: ".doufu — " + String(localized: "home.menu.export.doufu.subtitle", defaultValue: "Code only"),
            style: .default
        ) { [weak self] _ in
            self?.export(.code)
        })
        if canExportProjectBackup {
            alert.addAction(UIAlertAction(
                title: ".doufull — " + String(localized: "home.menu.export.doufull.subtitle", defaultValue: "Code and data"),
                style: .default
            ) { [weak self] _ in
                self?.export(.projectBackup)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(alert, animated: true)
    }

    private var canExportProjectBackup: Bool {
        projectRootURL != nil
    }

    private func export(_ kind: ExportKind) {
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.exportTask = nil }

            let archiveKind: ProjectArchiveExportService.ArchiveKind = {
                switch kind {
                case .code:
                    return .doufu
                case .projectBackup:
                    return .doufull
                }
            }()

            do {
                let exportAppURL = self.appURL ?? self.rootURL.appendingPathComponent("App", isDirectory: true)
                let payload = try await self.archiveExportService.exportArchive(
                    kind: archiveKind,
                    projectName: self.projectName,
                    appURL: exportAppURL,
                    projectRootURL: self.projectRootURL
                )
                guard !Task.isCancelled else {
                    self.cleanupExportArtifacts(payload)
                    return
                }

                let activity = UIActivityViewController(activityItems: [payload.archiveURL], applicationActivities: nil)
                activity.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItem
                activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
                    self?.cleanupExportArtifacts(payload)
                }
                self.present(activity, animated: true)
            } catch is CancellationError {
                return
            } catch {
                let alert = UIAlertController(
                    title: String(localized: "file_browser.alert.zip_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func cleanupExportArtifacts(_ payload: ProjectArchiveExportService.ExportResult) {
        for url in payload.cleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Add (Create Folder / Upload)

    @objc private func didTapAdd() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: String(localized: "file_browser.action.create_folder"),
            style: .default
        ) { [weak self] _ in
            self?.showCreateFolderAlert()
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "file_browser.action.upload_file"),
            style: .default
        ) { [weak self] _ in
            self?.showDocumentPicker()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.last
        present(sheet, animated: true)
    }

    private func showCreateFolderAlert() {
        let alert = UIAlertController(
            title: String(localized: "file_browser.action.create_folder"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = String(localized: "file_browser.create_folder.placeholder")
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default) { [weak self] _ in
            guard let self,
                  let raw = alert.textFields?.first?.text,
                  let name = self.validatedFileName(raw) else { return }
            let target = self.directoryURL.appendingPathComponent(name, isDirectory: true)
            guard self.isSafeChildURL(target) else { return }
            do {
                try self.fileManager.createDirectory(at: target, withIntermediateDirectories: false)
                self.reloadAndNotify()
            } catch {
                self.showOperationError(error)
            }
        })
        present(alert, animated: true)
    }

    private func showDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - Context Menu

    private func makeContextMenu(for item: Item) -> UIMenu {
        let rename = UIAction(
            title: String(localized: "file_browser.action.rename"),
            image: UIImage(systemName: "pencil")
        ) { [weak self] _ in
            self?.showRenameAlert(for: item)
        }
        let move = UIAction(
            title: String(localized: "file_browser.action.move"),
            image: UIImage(systemName: "folder")
        ) { [weak self] _ in
            self?.showDirectoryPicker(for: item)
        }
        let delete = UIAction(
            title: String(localized: "file_browser.action.delete"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.showDeleteConfirmation(for: item)
        }
        return UIMenu(children: [rename, move, delete])
    }

    private func showRenameAlert(for item: Item) {
        let alert = UIAlertController(
            title: String(localized: "file_browser.action.rename"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = item.name
            textField.placeholder = String(localized: "file_browser.rename.placeholder")
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default) { [weak self] _ in
            guard let self,
                  let raw = alert.textFields?.first?.text,
                  let newName = self.validatedFileName(raw) else { return }
            guard newName != item.name else { return }
            let target = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            guard self.isSafeChildURL(target) else { return }
            do {
                try self.fileManager.moveItem(at: item.url, to: target)
                self.reloadAndNotify()
            } catch {
                self.showOperationError(error)
            }
        })
        present(alert, animated: true)
    }

    private func showDirectoryPicker(for item: Item) {
        let pickerRootURL: URL
        if let appURL = appURL {
            pickerRootURL = appURL
        } else if let projectRootURL = projectRootURL {
            pickerRootURL = projectRootURL.appendingPathComponent("App", isDirectory: true)
        } else {
            pickerRootURL = rootURL
        }

        let sourceParent = item.url.deletingLastPathComponent().standardizedFileURL
        let picker = ProjectFileBrowserViewController(
            projectName: projectName,
            rootURL: pickerRootURL,
            projectRootURL: projectRootURL,
            appURL: appURL,
            showHiddenFiles: showHiddenFiles,
            directoryPickerMode: true,
            excludedURL: item.isDirectory ? item.url : nil,
            onDirectoryPicked: { [weak self] destinationURL in
                guard let self else { return }
                if destinationURL.standardizedFileURL == sourceParent { return }
                self.performMove(item: item, to: destinationURL)
            },
            fileManager: fileManager
        )
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    private func performMove(item: Item, to destinationURL: URL) {
        if item.isDirectory {
            let srcPath = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            let dstPath = destinationURL.standardizedFileURL.resolvingSymlinksInPath().path
            let srcPrefix = srcPath.hasSuffix("/") ? srcPath : srcPath + "/"
            if dstPath == srcPath || dstPath.hasPrefix(srcPrefix) {
                let alert = UIAlertController(
                    title: String(localized: "file_browser.error.move_into_self"),
                    message: nil,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                present(alert, animated: true)
                return
            }
        }
        let target = destinationURL.appendingPathComponent(item.name)
        guard isSafeChildURL(target) else { return }
        do {
            try fileManager.moveItem(at: item.url, to: target)
            reloadAndNotify()
        } catch {
            showOperationError(error)
        }
    }

    private func showDeleteConfirmation(for item: Item) {
        let alert = UIAlertController(
            title: String(format: String(localized: "file_browser.delete.confirm.title"), item.name),
            message: String(localized: "file_browser.delete.confirm.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: String(localized: "file_browser.action.delete"),
            style: .destructive
        ) { [weak self] _ in
            guard let self else { return }
            do {
                try self.fileManager.removeItem(at: item.url)
                self.reloadAndNotify()
            } catch {
                self.showOperationError(error)
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Directory Picker Mode

    @objc private func didTapSelectDirectory() {
        let picked = directoryURL
        let callback = onDirectoryPicked
        if let nav = navigationController, nav.presentingViewController != nil {
            nav.dismiss(animated: true) {
                callback?(picked)
            }
        } else {
            callback?(picked)
        }
    }

    @objc private func didTapCancelPicker() {
        navigationController?.dismiss(animated: true)
    }

    // MARK: - Helpers

    private func validatedFileName(_ name: String, showError: Bool = true) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed != ".", trimmed != ".." else {
            if showError {
                let alert = UIAlertController(
                    title: String(localized: "file_browser.error.invalid_name"),
                    message: nil,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                present(alert, animated: true)
            }
            return nil
        }
        return trimmed
    }

    private func reloadAndNotify() {
        reloadItems()
        if let projectID {
            ProjectChangeCenter.shared.notifyFilesChanged(projectID: projectID)
        }
    }

    private func showOperationError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "file_browser.error.operation_failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(max(bytes, 0)))
    }
}

// MARK: - UIDocumentPickerDelegate

extension ProjectFileBrowserViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        performUpload(urls: urls, index: 0, didCopyAny: false)
    }

    private func performUpload(urls: [URL], index: Int, didCopyAny: Bool) {
        guard index < urls.count else {
            if didCopyAny {
                reloadAndNotify()
            }
            return
        }
        let url = urls[index]
        let target = directoryURL.appendingPathComponent(url.lastPathComponent)
        guard isSafeChildURL(target) else {
            performUpload(urls: urls, index: index + 1, didCopyAny: didCopyAny)
            return
        }

        if fileManager.fileExists(atPath: target.path) {
            let alert = UIAlertController(
                title: String(format: String(localized: "file_browser.upload.overwrite.title"), url.lastPathComponent),
                message: nil,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel) { [weak self] _ in
                self?.performUpload(urls: urls, index: index + 1, didCopyAny: didCopyAny)
            })
            alert.addAction(UIAlertAction(
                title: String(localized: "file_browser.upload.overwrite.replace"),
                style: .destructive
            ) { [weak self] _ in
                guard let self else { return }
                if self.copyUploadedFile(from: url, to: target) {
                    self.performUpload(urls: urls, index: index + 1, didCopyAny: true)
                } else if didCopyAny {
                    self.reloadAndNotify()
                }
            })
            present(alert, animated: true)
        } else {
            if copyUploadedFile(from: url, to: target) {
                performUpload(urls: urls, index: index + 1, didCopyAny: true)
            } else if didCopyAny {
                reloadAndNotify()
            }
        }
    }

    @discardableResult
    private func copyUploadedFile(from source: URL, to target: URL) -> Bool {
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: source)
            } else {
                try fileManager.copyItem(at: source, to: target)
            }
            return true
        } catch {
            showOperationError(error)
            return false
        }
    }
}

@MainActor
private final class ProjectFileContentViewController: UIViewController {
    private let fileURL: URL
    private let rootURL: URL
    private let readOnly: Bool
    private var originalText: String = ""
    private var canEditFile = false
    private var isSaving = false {
        didSet {
            updateSaveButtonState()
        }
    }
    private var isDirty = false {
        didSet {
            updateSaveButtonState()
        }
    }

    private lazy var saveBarButtonItem: UIBarButtonItem = {
        UIBarButtonItem(
            title: String(localized: "common.action.save"),
            style: Self.saveButtonStyle,
            target: self,
            action: #selector(didTapSave)
        )
    }()

    private static var saveButtonStyle: UIBarButtonItem.Style {
        if #available(iOS 26.0, *) {
            return .prominent
        }
        return .plain
    }

#if canImport(Runestone)
    private lazy var editorView: TextView = {
        let view = TextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.showLineNumbers = true
        view.lineSelectionDisplayType = .line
        view.isEditable = true
        view.isSelectable = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.editorDelegate = self
        return view
    }()
#else
    private lazy var editorView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alwaysBounceVertical = true
        view.isEditable = true
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.backgroundColor = .systemBackground
        view.textColor = .label
        view.delegate = self
        return view
    }()
#endif

    init(fileURL: URL, rootURL: URL, readOnly: Bool = false) {
        self.fileURL = fileURL
        self.rootURL = rootURL
        self.readOnly = readOnly
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        title = fileURL.lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.prompt = nil
        if !readOnly {
            navigationItem.rightBarButtonItem = saveBarButtonItem
        }
        view.addSubview(editorView)
        NSLayoutConstraint.activate([
            editorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            editorView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        loadContent()
        updateSaveButtonState()
    }

    private func loadContent() {
        guard isSafeFileURL(fileURL) else {
            setEditorText(String(localized: "file_viewer.error.unsafe_path"))
            canEditFile = false
            setEditorEditable(false)
            isDirty = false
            return
        }

        // Disable editing while loading to prevent user input from being
        // silently overwritten when the async read completes.
        setEditorEditable(false)

        let url = fileURL
        Task { [weak self] in
            let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8) else {
                        return .failure(NSError(
                            domain: "Doufu", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "non-utf8"]
                        ))
                    }
                    return .success(text)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            switch result {
            case .success(let text):
                self.originalText = text
                self.setEditorText(text)
                self.canEditFile = !self.readOnly
                self.setEditorEditable(!self.readOnly)
                self.isDirty = false
            case .failure(let error):
                let isNonUTF8 = (error as NSError).domain == "Doufu" && (error as NSError).code == -1
                if isNonUTF8 {
                    self.setEditorText(String(localized: "file_viewer.error.non_utf8"))
                } else {
                    self.setEditorText(
                        String(
                            format: String(localized: "file_viewer.error.read_failed.message_format"),
                            error.localizedDescription
                        )
                    )
                }
                self.canEditFile = false
                self.setEditorEditable(false)
                self.isDirty = false
            }
        }
    }

    private func updateSaveButtonState() {
        saveBarButtonItem.isEnabled = canEditFile && isDirty && !isSaving
    }

    private func currentEditorText() -> String {
#if canImport(Runestone)
        editorView.text
#else
        editorView.text ?? ""
#endif
    }

    private func setEditorText(_ text: String) {
#if canImport(Runestone)
        let state = makeRunestoneState(text: text)
        editorView.setState(state)
#else
        editorView.text = text
#endif
    }

    private func setEditorEditable(_ editable: Bool) {
#if canImport(Runestone)
        editorView.isEditable = editable
        editorView.isSelectable = true
#else
        editorView.isEditable = editable
        editorView.isSelectable = true
#endif
    }

    private func updateDirtyStateFromEditor() {
        guard canEditFile else {
            isDirty = false
            return
        }
        let currentText = currentEditorText()
        isDirty = currentText != originalText
    }

    @objc
    private func didTapSave() {
        guard canEditFile, !isSaving else {
            return
        }

        let currentText = currentEditorText()
        guard currentText != originalText else {
            isDirty = false
            return
        }

        let url = fileURL
        let textToWrite = currentText
        isSaving = true

        let projectID = rootURL.deletingLastPathComponent().lastPathComponent

        Task { [weak self] in
            let writeError: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try textToWrite.write(to: url, atomically: true, encoding: .utf8)
                    return nil
                } catch {
                    return error
                }
            }.value

            if writeError == nil {
                ProjectChangeCenter.shared.notifyFilesChanged(projectID: projectID)
            }

            guard let self else { return }
            self.isSaving = false

            if let writeError {
                let alert = UIAlertController(
                    title: String(localized: "file_viewer.alert.save_failed.title"),
                    message: writeError.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            } else {
                self.originalText = textToWrite
                // Re-derive dirty state from current editor content,
                // which may have changed while the write was in flight.
                self.updateDirtyStateFromEditor()
            }
        }
    }

    private func isSafeFileURL(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return filePath.hasPrefix(prefix)
    }

#if canImport(Runestone)
    private func makeRunestoneState(text: String) -> TextViewState {
        if let language = treeSitterLanguageForCurrentFile() {
            return TextViewState(text: text, theme: DefaultTheme(), language: language)
        } else {
            return TextViewState(text: text, theme: DefaultTheme())
        }
    }

    private func treeSitterLanguageForCurrentFile() -> TreeSitterLanguage? {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "js", "mjs", "cjs":
#if canImport(TreeSitterJavaScriptRunestone)
            return .javaScript
#else
            return nil
#endif
        case "jsx":
#if canImport(TreeSitterJavaScriptRunestone)
            return .jsx
#else
            return nil
#endif
        case "ts":
#if canImport(TreeSitterTypeScriptRunestone)
            return .typeScript
#else
            return nil
#endif
        case "tsx":
#if canImport(TreeSitterTSXRunestone)
            return .tsx
#else
            return nil
#endif
        case "json", "json5":
#if canImport(TreeSitterJSONRunestone)
            return .json
#else
            return nil
#endif
        case "html", "htm":
#if canImport(TreeSitterHTMLRunestone)
            return .html
#else
            return nil
#endif
        case "css", "scss":
#if canImport(TreeSitterCSSRunestone)
            return .css
#else
            return nil
#endif
        case "md", "markdown", "mdx":
#if canImport(TreeSitterMarkdownRunestone)
            return .markdown
#else
            return nil
#endif
        case "swift":
#if canImport(TreeSitterSwiftRunestone)
            return .swift
#else
            return nil
#endif
        default:
            return nil
        }
    }
#endif
}

#if canImport(Runestone)
extension ProjectFileContentViewController: TextViewDelegate {
    func textViewDidChange(_ textView: TextView) {
        updateDirtyStateFromEditor()
    }
}
#else
extension ProjectFileContentViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateDirtyStateFromEditor()
    }
}
#endif
