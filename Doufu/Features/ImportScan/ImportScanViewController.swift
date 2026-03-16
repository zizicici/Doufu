//
//  ImportScanViewController.swift
//  Doufu
//

import UIKit

@MainActor
final class ImportScanViewController: UIViewController {

    // MARK: - Flow Phases

    private enum Phase {
        case staticScan          // Phase 1: showing info + static results + action buttons
        case llmRunning          // Phase 2: LLM review in progress
        case llmDone             // Phase 2 complete: show LLM results
        case blocked             // LLM found malicious — import not allowed
    }

    private enum BottomBarState {
        case hidden
        case llmOnly
        case llmOrSkip
        case confirmOrCancel
        case closeOnly
    }

    // MARK: - Public

    var onConfirmImport: ((ProjectArchiveImportService.PreviewResult) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Properties

    private let preview: ProjectArchiveImportService.PreviewResult?
    private let reviewAppURL: URL?
    private let reviewProjectURL: URL?
    private let reviewProjectName: String?
    private var isReviewOnly: Bool { preview == nil }
    private var effectiveAppURL: URL { preview?.appURL ?? reviewAppURL! }
    private var reviewFileCount: Int?
    private var reviewProjectSize: Int64?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: UITableViewDiffableDataSource<ImportScanSectionID, ImportScanItemID>!

    private var phase: Phase = .staticScan
    private var staticResult: StaticCodeScanner.ScanResult?
    private var llmResult: LLMCodeScanner.ScanResult?
    private var hasLLMCredential = false
    private var scanTask: Task<Void, Never>?

    // Bottom bar
    private let bottomBarContainer = UIView()
    private let primaryButton = UIButton(type: .system)
    private let secondaryButton = UIButton(type: .system)
    private let buttonSeparator = UIView()
    private var tableBottomToBar: NSLayoutConstraint!
    private var tableBottomToView: NSLayoutConstraint!
    private var bottomBarState: BottomBarState = .hidden

    // MARK: - Init

    /// Import mode: scan an archive before importing.
    init(preview: ProjectArchiveImportService.PreviewResult) {
        self.preview = preview
        self.reviewAppURL = nil
        self.reviewProjectURL = nil
        self.reviewProjectName = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Review mode: scan an existing project (no import actions).
    init(appURL: URL, projectURL: URL, projectName: String) {
        self.preview = nil
        self.reviewAppURL = appURL
        self.reviewProjectURL = projectURL
        self.reviewProjectName = projectName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        title = isReviewOnly
            ? String(localized: "scan.title.review", defaultValue: "Code Review")
            : String(localized: "scan.title", defaultValue: "Import Review")

        setupTableView()
        setupBottomBar()
        setupDataSource()

        presentationController?.delegate = self
        hasLLMCredential = LLMCodeScanner.resolveCredential() != nil

        if isReviewOnly, let projectURL = reviewProjectURL {
            let url = projectURL
            Task { [weak self] in
                let (count, size) = await Task.detached(priority: .userInitiated) {
                    let count = Self.countFiles(at: url)
                    let size = Self.directorySize(at: url)
                    return (count, size)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.reviewFileCount = count
                self.reviewProjectSize = size
                self.applySnapshot()
            }
        }

        applySnapshot()
        runStaticScan()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scanTask?.cancel()
    }

    // MARK: - Setup

    private func setupTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .doufuBackground
        tableView.separatorStyle = .none
        tableView.register(ImportScanFindingCell.self, forCellReuseIdentifier: ImportScanFindingCell.reuseIdentifier)
        tableView.delegate = self
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Two mutually exclusive bottom constraints
        tableBottomToView = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        tableBottomToView.isActive = true
    }

    private func setupBottomBar() {
        bottomBarContainer.translatesAutoresizingMaskIntoConstraints = false
        bottomBarContainer.backgroundColor = .doufuPaper
        bottomBarContainer.isHidden = true
        view.addSubview(bottomBarContainer)

        // Top separator
        let topSep = UIView()
        topSep.translatesAutoresizingMaskIntoConstraints = false
        topSep.backgroundColor = .separator
        bottomBarContainer.addSubview(topSep)

        // Button stack
        let stack = UIStackView(arrangedSubviews: [primaryButton, buttonSeparator, secondaryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        bottomBarContainer.addSubview(stack)

        primaryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        primaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        primaryButton.addTarget(self, action: #selector(primaryButtonTapped), for: .touchUpInside)

        buttonSeparator.backgroundColor = .separator

        secondaryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        secondaryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        secondaryButton.addTarget(self, action: #selector(secondaryButtonTapped), for: .touchUpInside)

        let hairline = 1.0 / UIScreen.main.scale

        NSLayoutConstraint.activate([
            bottomBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBarContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topSep.topAnchor.constraint(equalTo: bottomBarContainer.topAnchor),
            topSep.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            topSep.heightAnchor.constraint(equalToConstant: hairline),

            stack.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bottomBarContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bottomBarContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            primaryButton.heightAnchor.constraint(equalToConstant: 50),
            buttonSeparator.heightAnchor.constraint(equalToConstant: hairline),
            secondaryButton.heightAnchor.constraint(equalToConstant: 50),
        ])

        tableBottomToBar = tableView.bottomAnchor.constraint(equalTo: bottomBarContainer.topAnchor)
    }

    private func setupDataSource() {
        dataSource = ImportScanDataSource(tableView: tableView) { [weak self] tableView, indexPath, itemID in
            self?.cell(for: tableView, at: indexPath, itemID: itemID) ?? UITableViewCell()
        }
    }

    // MARK: - Static Scan

    private func runStaticScan() {
        let appURL = effectiveAppURL
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                StaticCodeScanner.scan(appURL: appURL)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.staticResult = result
            self.phase = .staticScan
            self.applySnapshot()
        }
    }

    // MARK: - LLM Scan

    private func startLLMReview() {
        guard let resolved = LLMCodeScanner.resolveCredential() else { return }

        phase = .llmRunning
        applySnapshot()

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await LLMCodeScanner.scan(
                    appURL: self.effectiveAppURL,
                    credential: resolved.credential,
                    modelID: resolved.modelID,
                    onProgress: nil
                )

                guard !Task.isCancelled else { return }
                self.llmResult = result

                if result.riskLevel >= .critical {
                    self.phase = .blocked
                } else {
                    self.phase = .llmDone
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("[Doufu ImportScan] LLM scan failed: \(error.localizedDescription)")
                self.phase = .llmDone
                self.llmResult = nil
            }
            self.applySnapshot()
        }
    }

    // MARK: - Cell Configuration

    private func cell(for tableView: UITableView, at indexPath: IndexPath, itemID: ImportScanItemID) -> UITableViewCell {
        switch itemID {

        // -- Archive Info --
        case .archiveName(let name):
            return infoCell(icon: "doc.zipper", title: String(localized: "scan.info.name", defaultValue: "Name"), value: name)

        case .archiveSize(let size):
            return infoCell(icon: "internaldrive", title: String(localized: "scan.info.size", defaultValue: "Size"), value: size)

        case .archiveFiles(let count):
            let cell = infoCell(
                icon: "doc.on.doc",
                title: String(localized: "scan.info.files", defaultValue: "Files"),
                value: "\(count)"
            )
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell

        case .appDataWarning:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .systemOrange.withAlphaComponent(0.1)
            var config = cell.defaultContentConfiguration()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.imageProperties.tintColor = .systemOrange
            config.text = String(
                localized: "scan.appdata_warning",
                defaultValue: "This archive includes pre-populated app data (AppData/) that has not been scanned."
            )
            config.textProperties.font = .preferredFont(forTextStyle: .footnote)
            config.textProperties.color = .systemOrange
            config.textProperties.numberOfLines = 0
            cell.contentConfiguration = config
            return cell

        // -- Scanning --
        case .staticScanning:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .doufuPaper
            var config = cell.defaultContentConfiguration()
            config.image = UIImage(systemName: "magnifyingglass")
            config.imageProperties.tintColor = .systemBlue
            config.text = String(localized: "scan.static.scanning", defaultValue: "Scanning files...")
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            return cell

        // -- Findings --
        case .finding(let id, _, _):
            if let finding = staticResult?.findings.first(where: { $0.id == id }) {
                let cell = tableView.dequeueReusableCell(withIdentifier: ImportScanFindingCell.reuseIdentifier, for: indexPath) as! ImportScanFindingCell
                let locationText: String?
                if finding.locations.isEmpty {
                    locationText = nil
                } else if finding.locations.count == 1 {
                    let loc = finding.locations[0]
                    locationText = loc.lineNumber > 0 ? "\(loc.filePath):\(loc.lineNumber)" : loc.filePath
                } else {
                    let fileCount = Set(finding.locations.map(\.filePath)).count
                    locationText = String(
                        format: String(localized: "scan.finding.multiple_locations", defaultValue: "%d occurrences in %d files"),
                        finding.locations.count, fileCount
                    )
                }
                cell.configure(description: finding.description, location: locationText, severity: finding.severity)
                return cell
            }
            return UITableViewCell()

        case .noFindings:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .doufuPaper
            var config = cell.defaultContentConfiguration()
            config.text = String(localized: "scan.no_findings", defaultValue: "No issues detected by static analysis")
            config.textProperties.color = .secondaryLabel
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            cell.contentConfiguration = config
            return cell

        // -- LLM Status --
        case .llmStatus(let llmPhase):
            return llmStatusCell(phase: llmPhase)

        case .llmFinding(let id, _):
            if let finding = llmResult?.findings.first(where: { $0.id == id }) {
                let cell = tableView.dequeueReusableCell(withIdentifier: ImportScanFindingCell.reuseIdentifier, for: indexPath) as! ImportScanFindingCell
                cell.configure(description: finding.description, location: finding.filePath, severity: finding.severity)
                return cell
            }
            return UITableViewCell()

        case .llmSummary(let text):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .doufuPaper
            var config = cell.defaultContentConfiguration()
            config.text = text
            config.textProperties.font = .preferredFont(forTextStyle: .footnote)
            config.textProperties.color = .secondaryLabel
            config.textProperties.numberOfLines = 0
            cell.contentConfiguration = config
            return cell

        case .blocked:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.backgroundColor = .systemRed.withAlphaComponent(0.1)
            var config = cell.defaultContentConfiguration()
            config.image = UIImage(systemName: "nosign")
            config.imageProperties.tintColor = .systemRed
            config.text = String(
                localized: "scan.blocked.message",
                defaultValue: "Import not allowed — AI analysis detected potentially malicious code."
            )
            config.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            config.textProperties.color = .systemRed
            config.textProperties.numberOfLines = 0
            cell.contentConfiguration = config
            return cell
        }
    }

    private func infoCell(icon: String, title: String, value: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .doufuPaper
        var config = cell.defaultContentConfiguration()
        config.image = UIImage(systemName: icon)
        config.imageProperties.tintColor = .doufuText
        config.text = title
        config.textProperties.font = .preferredFont(forTextStyle: .body)
        config.textProperties.color = .doufuText
        config.secondaryText = value
        config.secondaryTextProperties.font = .preferredFont(forTextStyle: .body)
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        return cell
    }

    private func llmStatusCell(phase: ImportScanItemID.LLMPhase) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .doufuPaper
        var config = cell.defaultContentConfiguration()
        config.text = String(localized: "scan.llm.title", defaultValue: "LLM Review")
        config.textProperties.font = .preferredFont(forTextStyle: .body)

        switch phase {
        case .running:
            config.secondaryText = String(localized: "scan.llm.running", defaultValue: "Analyzing...")
            config.secondaryTextProperties.color = .systemBlue
        case .done:
            config.secondaryText = String(localized: "scan.llm.done", defaultValue: "Complete")
            config.secondaryTextProperties.color = .secondaryLabel
        case .failed:
            config.secondaryText = String(localized: "scan.llm.failed", defaultValue: "Failed")
            config.secondaryTextProperties.color = .systemOrange
        case .malicious:
            config.secondaryText = String(localized: "scan.llm.malicious", defaultValue: "Malicious Detected")
            config.secondaryTextProperties.color = .systemRed
        }

        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<ImportScanSectionID, ImportScanItemID>()

        // Project / Archive Info
        if let preview {
            snapshot.appendSections([.archiveInfo])
            var archiveInfoItems: [ImportScanItemID] = [
                .archiveName(preview.archiveName),
                .archiveSize(formattedSize(preview.archiveSize)),
                .archiveFiles(preview.fileCount),
            ]
            if preview.hasAppData {
                archiveInfoItems.append(.appDataWarning)
            }
            snapshot.appendItems(archiveInfoItems, toSection: .archiveInfo)
        } else if let reviewProjectName {
            snapshot.appendSections([.projectInfo])
            let items: [ImportScanItemID] = [
                .archiveName(reviewProjectName),
                .archiveSize(formattedSize(reviewProjectSize ?? 0)),
                .archiveFiles(reviewFileCount ?? 0),
            ]
            snapshot.appendItems(items, toSection: .projectInfo)
        }

        // Static Scan: show scanning indicator or findings
        if staticResult == nil {
            snapshot.appendSections([.scanProgress])
            snapshot.appendItems([.staticScanning], toSection: .scanProgress)
        }

        if let result = staticResult {
            let grouped = Dictionary(grouping: result.findings) { $0.category }
            var hasAnyFindings = false

            for category in FindingCategory.allCases {
                guard let findings = grouped[category], !findings.isEmpty else { continue }
                hasAnyFindings = true
                let section = ImportScanSectionID.findings(category)
                snapshot.appendSections([section])
                snapshot.appendItems(
                    findings.map { .finding(id: $0.id, severity: $0.severity.rawValue, category: $0.category.rawValue) },
                    toSection: section
                )
            }

            if !hasAnyFindings {
                snapshot.appendSections([.scanProgress])
                snapshot.appendItems([.noFindings], toSection: .scanProgress)
            }
        }

        // Phase-specific LLM content
        switch phase {
        case .staticScan:
            break

        case .llmRunning:
            snapshot.appendSections([.llmStatus])
            snapshot.appendItems([.llmStatus(.running)], toSection: .llmStatus)

        case .llmDone:
            snapshot.appendSections([.llmStatus])
            let llmPhase: ImportScanItemID.LLMPhase = llmResult != nil ? .done : .failed
            snapshot.appendItems([.llmStatus(llmPhase)], toSection: .llmStatus)

            if let llmResult, !llmResult.findings.isEmpty {
                snapshot.appendItems(
                    llmResult.findings.map { .llmFinding(id: $0.id, severity: $0.severity.rawValue) },
                    toSection: .llmStatus
                )
            }
            if let summary = llmResult?.summary, !summary.isEmpty {
                snapshot.appendItems([.llmSummary(summary)], toSection: .llmStatus)
            }

        case .blocked:
            snapshot.appendSections([.llmStatus])
            snapshot.appendItems([.llmStatus(.malicious)], toSection: .llmStatus)

            if let llmResult, !llmResult.findings.isEmpty {
                snapshot.appendItems(
                    llmResult.findings.map { .llmFinding(id: $0.id, severity: $0.severity.rawValue) },
                    toSection: .llmStatus
                )
            }
            if let summary = llmResult?.summary, !summary.isEmpty {
                snapshot.appendItems([.llmSummary(summary)], toSection: .llmStatus)
            }
            snapshot.appendItems([.blocked], toSection: .llmStatus)
        }

        dataSource.apply(snapshot, animatingDifferences: true)
        updateBottomBar()
    }

    // MARK: - Bottom Bar

    private func updateBottomBar() {
        let newState: BottomBarState
        if isReviewOnly {
            // Review mode: only offer LLM scan, no import actions
            switch phase {
            case .staticScan:
                newState = (staticResult != nil && hasLLMCredential) ? .llmOnly : .hidden
            case .llmRunning, .llmDone, .blocked:
                newState = .hidden
            }
        } else {
            switch phase {
            case .staticScan:
                if staticResult != nil {
                    newState = hasLLMCredential ? .llmOrSkip : .confirmOrCancel
                } else {
                    newState = .hidden
                }
            case .llmRunning:
                newState = .hidden
            case .llmDone:
                newState = .confirmOrCancel
            case .blocked:
                newState = .closeOnly
            }
        }

        bottomBarState = newState

        switch newState {
        case .hidden:
            bottomBarContainer.isHidden = true
            tableBottomToBar.isActive = false
            tableBottomToView.isActive = true

        case .llmOnly:
            primaryButton.setTitle(
                String(localized: "scan.action.start_llm", defaultValue: "Start LLM Review"),
                for: .normal
            )
            primaryButton.setTitleColor(.systemBlue, for: .normal)
            secondaryButton.isHidden = true
            buttonSeparator.isHidden = true
            showBottomBar()

        case .llmOrSkip:
            primaryButton.setTitle(
                String(localized: "scan.action.start_llm", defaultValue: "Start LLM Review"),
                for: .normal
            )
            primaryButton.setTitleColor(.systemBlue, for: .normal)
            secondaryButton.setTitle(
                String(localized: "scan.action.skip", defaultValue: "Skip"),
                for: .normal
            )
            secondaryButton.setTitleColor(.secondaryLabel, for: .normal)
            secondaryButton.isHidden = false
            buttonSeparator.isHidden = false
            showBottomBar()

        case .confirmOrCancel:
            primaryButton.setTitle(
                String(localized: "scan.action.confirm_import", defaultValue: "Confirm Import"),
                for: .normal
            )
            primaryButton.setTitleColor(.systemBlue, for: .normal)
            secondaryButton.setTitle(
                String(localized: "scan.action.cancel_import", defaultValue: "Cancel Import"),
                for: .normal
            )
            secondaryButton.setTitleColor(.systemRed, for: .normal)
            secondaryButton.isHidden = false
            buttonSeparator.isHidden = false
            showBottomBar()

        case .closeOnly:
            primaryButton.setTitle(
                String(localized: "scan.action.close", defaultValue: "Close"),
                for: .normal
            )
            primaryButton.setTitleColor(.systemRed, for: .normal)
            secondaryButton.isHidden = true
            buttonSeparator.isHidden = true
            showBottomBar()
        }
    }

    private func showBottomBar() {
        tableBottomToView.isActive = false
        tableBottomToBar.isActive = true
        bottomBarContainer.isHidden = false
    }

    @objc private func primaryButtonTapped() {
        switch bottomBarState {
        case .llmOnly, .llmOrSkip: startLLMReview()
        case .confirmOrCancel: handleConfirmImport()
        case .closeOnly: handleClose()
        case .hidden: break
        }
    }

    @objc private func secondaryButtonTapped() {
        switch bottomBarState {
        case .llmOrSkip: handleSkip()
        case .confirmOrCancel: handleCancel()
        case .llmOnly, .closeOnly, .hidden: break
        }
    }

    // MARK: - Actions

    private func handleConfirmImport() {
        let riskLevel = computeOverallRisk()
        let riskDetail: String
        switch riskLevel {
        case .low:
            riskDetail = String(
                localized: "scan.confirm.low_risk",
                defaultValue: "Automated scans found no significant issues, but this does not guarantee safety."
            )
        case .medium:
            riskDetail = String(
                localized: "scan.confirm.medium_risk",
                defaultValue: "Automated scans found patterns that may warrant attention. Review the findings above carefully."
            )
        case .high, .critical:
            riskDetail = String(
                localized: "scan.confirm.high_risk",
                defaultValue: "Automated scans found potentially risky code patterns. Import only if you fully trust the source."
            )
        }

        let alert = UIAlertController(
            title: String(localized: "scan.confirm.title", defaultValue: "Confirm Import"),
            message: String(
                format: String(
                    localized: "scan.confirm.message_format",
                    defaultValue: "%@\n\nThis project was created by a third party and its code will run on your device. By importing it, you accept all risks."
                ),
                riskDetail
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "scan.action.cancel_import", defaultValue: "Cancel Import"),
            style: .cancel
        ))
        alert.addAction(UIAlertAction(
            title: String(localized: "scan.action.confirm_import", defaultValue: "Confirm Import"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            self.onCancel = nil // Suppress dismiss-as-cancel cleanup; confirm path owns the preview lifecycle
            if let preview = self.preview {
                self.onConfirmImport?(preview)
            }
        })
        present(alert, animated: true)
    }

    private func handleCancel() {
        onCancel?()
    }

    private func handleClose() {
        onCancel?()
    }

    private func handleSkip() {
        handleConfirmImport()
    }

    // MARK: - Helpers

    private func computeOverallRisk() -> ImportRiskLevel {
        let staticRisk = staticResult?.riskLevel ?? .low
        let llmRisk = llmResult?.riskLevel ?? .low
        return max(staticRisk, llmRisk)
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private nonisolated static func countFiles(at url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - UITableViewDelegate

extension ImportScanViewController: UITableViewDelegate {

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let itemID = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .archiveFiles = itemID {
            let rootURL: URL
            let name: String
            if let preview {
                rootURL = preview.payloadRoot
                name = preview.archiveName
            } else if let reviewProjectURL, let reviewProjectName {
                rootURL = reviewProjectURL
                name = reviewProjectName
            } else {
                return
            }
            let browser = ProjectFileBrowserViewController(
                projectName: name,
                rootURL: rootURL,
                showHiddenFiles: true,
                readOnly: isReviewOnly
            )
            let nav = UINavigationController(rootViewController: browser)
            nav.modalPresentationStyle = .pageSheet
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
            }
            present(nav, animated: true)
        }
    }

}

// MARK: - UIAdaptivePresentationControllerDelegate

extension ImportScanViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        scanTask?.cancel()
        onCancel?()
    }
}

// MARK: - DataSource Subclass (for section headers)

private final class ImportScanDataSource: UITableViewDiffableDataSource<ImportScanSectionID, ImportScanItemID> {

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }

        switch sectionID {
        case .archiveInfo:
            return String(localized: "scan.section.archive_info", defaultValue: "Archive Information")
        case .projectInfo:
            return String(localized: "scan.section.project_info", defaultValue: "Project Information")
        case .scanProgress:
            return String(localized: "scan.section.static", defaultValue: "Static Analysis")
        case .findings(let category):
            return category.displayName
        case .llmStatus:
            return String(localized: "scan.section.llm", defaultValue: "LLM Review")
        }
    }
}
