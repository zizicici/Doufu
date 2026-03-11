//
//  ProjectFileBrowserViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/06.
//

import UIKit
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

    private struct Item {
        let name: String
        let url: URL
        let isDirectory: Bool
        let fileSize: Int?
    }

    private let projectName: String
    private let rootURL: URL
    private let directoryURL: URL
    private var items: [Item] = []
    private let fileManager: FileManager

    init(
        projectName: String,
        rootURL: URL,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.projectName = projectName
        self.rootURL = rootURL
        self.directoryURL = directoryURL ?? rootURL
        self.fileManager = fileManager
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleForCurrentDirectory()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectFileRow")

        if directoryURL.standardizedFileURL == rootURL.standardizedFileURL {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"),
                style: .plain,
                target: self,
                action: #selector(didTapShare)
            )
        }

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
            if hidden {
                return nil
            }

            let isDirectory = values?.isDirectory == true
            if childURL.lastPathComponent == ".git", isDirectory {
                return nil
            }

            return Item(
                name: childURL.lastPathComponent,
                url: childURL,
                isDirectory: isDirectory,
                fileSize: values?.fileSize
            )
        }

        return mapped.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func isSafeChildURL(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let childPath = url.standardizedFileURL.path
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
            configuration.text = item.name
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
                directoryURL: item.url,
                fileManager: fileManager
            )
            navigationController?.pushViewController(controller, animated: true)
            return
        }

        let viewer = ProjectFileContentViewController(fileURL: item.url, rootURL: rootURL)
        navigationController?.pushViewController(viewer, animated: true)
    }

    // MARK: - Share

    @objc private func didTapShare() {
        let zipName = projectName.isEmpty ? "project" : projectName
        let tempDir = FileManager.default.temporaryDirectory
        let zipURL = tempDir.appendingPathComponent("\(zipName).zip")

        // Remove any previous zip at the same path.
        try? fileManager.removeItem(at: zipURL)

        do {
            try zipDirectory(at: rootURL, to: zipURL)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "file_browser.alert.zip_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
            return
        }

        let activity = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        activity.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: zipURL)
        }
        present(activity, animated: true)
    }

    private func zipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var zipError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempURL in
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            } catch {
                zipError = error
            }
        }

        if let error = coordinatorError { throw error }
        if let error = zipError { throw error }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(max(bytes, 0)))
    }
}

@MainActor
private final class ProjectFileContentViewController: UIViewController {
    private let fileURL: URL
    private let rootURL: URL
    private let projectStore = AppProjectStore.shared
    private var originalText: String = ""
    private var canEditFile = false
    private var isDirty = false {
        didSet {
            updateSaveButtonState()
        }
    }

    private lazy var saveBarButtonItem: UIBarButtonItem = {
        UIBarButtonItem(
            title: String(localized: "common.action.save"),
            style: .done,
            target: self,
            action: #selector(didTapSave)
        )
    }()

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

    init(fileURL: URL, rootURL: URL) {
        self.fileURL = fileURL
        self.rootURL = rootURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = fileURL.lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.prompt = nil
        navigationItem.rightBarButtonItem = saveBarButtonItem
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

        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                setEditorText(String(localized: "file_viewer.error.non_utf8"))
                canEditFile = false
                setEditorEditable(false)
                isDirty = false
                return
            }
            originalText = text
            setEditorText(text)
            canEditFile = true
            setEditorEditable(true)
            isDirty = false
        } catch {
            setEditorText(
                String(
                    format: String(localized: "file_viewer.error.read_failed.message_format"),
                    error.localizedDescription
                )
            )
            canEditFile = false
            setEditorEditable(false)
            isDirty = false
        }
    }

    private func updateSaveButtonState() {
        saveBarButtonItem.isEnabled = canEditFile && isDirty
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
        guard canEditFile else {
            return
        }

        let currentText = currentEditorText()
        guard currentText != originalText else {
            isDirty = false
            return
        }

        do {
            try currentText.write(to: fileURL, atomically: true, encoding: .utf8)
            originalText = currentText
            isDirty = false
            projectStore.touchProjectUpdatedAt(projectID: rootURL.deletingLastPathComponent().lastPathComponent)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "file_viewer.alert.save_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func isSafeFileURL(_ url: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
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
