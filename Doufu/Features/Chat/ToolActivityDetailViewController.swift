//
//  ToolActivityDetailViewController.swift
//  Doufu
//
//  Structured card-based detail view for tool activity entries.
//

import UIKit

final class ToolActivityDetailViewController: UIViewController {

    private let toolSummary: String
    private var entries: [ToolActivityEntry] = []

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.dataSource = self
        tv.delegate = self
        tv.register(ToolActivityCardCell.self, forCellReuseIdentifier: ToolActivityCardCell.reuseIdentifier)
        tv.backgroundColor = .systemGroupedBackground
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 80
        return tv
    }()

    private lazy var plainTextView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        tv.backgroundColor = .systemBackground
        tv.isHidden = true
        return tv
    }()

    init(toolSummary: String) {
        self.toolSummary = toolSummary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "tool_activity.title")
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )

        view.addSubview(tableView)
        view.addSubview(plainTextView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            plainTextView.topAnchor.constraint(equalTo: view.topAnchor),
            plainTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            plainTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            plainTextView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if let parsed = ToolActivityEntry.parse(from: toolSummary) {
            entries = parsed
            tableView.isHidden = false
            plainTextView.isHidden = true
        } else {
            tableView.isHidden = true
            plainTextView.isHidden = false
            plainTextView.attributedText = MarkdownRenderer.render(toolSummary)
        }
    }
}

// MARK: - UITableViewDataSource

extension ToolActivityDetailViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ToolActivityCardCell.reuseIdentifier,
            for: indexPath
        ) as? ToolActivityCardCell else {
            return UITableViewCell()
        }
        cell.configure(with: entries[indexPath.row])
        return cell
    }
}

// MARK: - UITableViewDelegate

extension ToolActivityDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let cell = tableView.cellForRow(at: indexPath) as? ToolActivityCardCell else { return }
        cell.toggleExpanded()
        tableView.performBatchUpdates(nil)
    }
}

// MARK: - Card Cell

private final class ToolActivityCardCell: UITableViewCell {
    static let reuseIdentifier = "ToolActivityCardCell"

    private let iconLabel = UILabel()
    private let toolNameLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let statusBadge = UILabel()
    private let detailLabel = UILabel()
    private let outputLabel = UILabel()

    private var isExpanded = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground

        let headerStack = UIStackView(arrangedSubviews: [iconLabel, toolNameLabel, UIView(), statusBadge])
        headerStack.axis = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .center

        iconLabel.font = .systemFont(ofSize: 16)
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        toolNameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        toolNameLabel.textColor = .label
        toolNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusBadge.font = .systemFont(ofSize: 11, weight: .medium)
        statusBadge.textAlignment = .center
        statusBadge.layer.cornerRadius = 4
        statusBadge.layer.cornerCurve = .continuous
        statusBadge.clipsToBounds = true
        statusBadge.setContentHuggingPriority(.required, for: .horizontal)

        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 2

        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .tertiaryLabel
        detailLabel.numberOfLines = 1

        outputLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        outputLabel.textColor = .secondaryLabel
        outputLabel.numberOfLines = 0
        outputLabel.isHidden = true

        let stack = UIStackView(arrangedSubviews: [headerStack, descriptionLabel, detailLabel, outputLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isExpanded = false
        outputLabel.isHidden = true
        outputLabel.numberOfLines = 0
    }

    func configure(with entry: ToolActivityEntry) {
        iconLabel.text = Self.icon(for: entry.toolName)
        toolNameLabel.text = Self.displayName(for: entry.toolName)
        descriptionLabel.text = entry.description

        if entry.isError {
            statusBadge.text = " \(String(localized: "tool_activity.status.error")) "
            statusBadge.textColor = .white
            statusBadge.backgroundColor = .systemRed
        } else {
            statusBadge.text = " \(String(localized: "tool_activity.status.ok")) "
            statusBadge.textColor = .white
            statusBadge.backgroundColor = .systemGreen
        }

        detailLabel.text = Self.buildDetailText(for: entry)
        detailLabel.isHidden = detailLabel.text?.isEmpty ?? true

        let trimmedOutput = entry.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOutput.isEmpty {
            outputLabel.text = nil
        } else {
            outputLabel.text = trimmedOutput
        }
    }

    func toggleExpanded() {
        isExpanded.toggle()
        let hasOutput = !(outputLabel.text?.isEmpty ?? true)
        outputLabel.isHidden = !isExpanded || !hasOutput
    }

    // MARK: - Static helpers

    private static func icon(for toolName: String) -> String {
        switch toolName {
        case "read_file": return "📄"
        case "write_file": return "✏️"
        case "edit_file": return "🔧"
        case "delete_file": return "🗑️"
        case "move_file": return "📦"
        case "revert_file": return "⏪"
        case "list_directory": return "📂"
        case "search_files": return "🔍"
        case "grep_files": return "🔎"
        case "glob_files": return "📋"
        case "diff_file": return "📊"
        case "changed_files": return "📝"
        case "web_search": return "🌐"
        case "web_fetch": return "🌍"
        case "validate_code": return "✅"
        default: return "⚙️"
        }
    }

    private static func displayName(for toolName: String) -> String {
        switch toolName {
        case "read_file": return String(localized: "tool_activity.tool.read_file")
        case "write_file": return String(localized: "tool_activity.tool.write_file")
        case "edit_file": return String(localized: "tool_activity.tool.edit_file")
        case "delete_file": return String(localized: "tool_activity.tool.delete_file")
        case "move_file": return String(localized: "tool_activity.tool.move_file")
        case "revert_file": return String(localized: "tool_activity.tool.revert_file")
        case "list_directory": return String(localized: "tool_activity.tool.list_directory")
        case "search_files": return String(localized: "tool_activity.tool.search_files")
        case "grep_files": return String(localized: "tool_activity.tool.grep_files")
        case "glob_files": return String(localized: "tool_activity.tool.glob_files")
        case "diff_file": return String(localized: "tool_activity.tool.diff_file")
        case "changed_files": return String(localized: "tool_activity.tool.changed_files")
        case "web_search": return String(localized: "tool_activity.tool.web_search")
        case "web_fetch": return String(localized: "tool_activity.tool.web_fetch")
        case "validate_code": return String(localized: "tool_activity.tool.validate_code")
        default: return toolName
        }
    }

    private static func buildDetailText(for entry: ToolActivityEntry) -> String? {
        switch entry.toolName {
        case "read_file":
            if let lineCount = entry.lineCount, let size = entry.sizeBytes {
                return String(format: String(localized: "tool_activity.detail.read_file_format"), lineCount, Self.formatBytes(size))
            } else if let path = entry.path {
                return path
            }
        case "write_file":
            var parts: [String] = []
            if let isNew = entry.isNew {
                parts.append(isNew
                    ? String(localized: "tool_activity.detail.created")
                    : String(localized: "tool_activity.detail.overwrote"))
            }
            if let size = entry.sizeBytes {
                parts.append(Self.formatBytes(size))
            }
            if let path = entry.path { parts.append(path) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "edit_file":
            var parts: [String] = []
            if let editCount = entry.editCount {
                parts.append(String(format: String(localized: "tool_activity.detail.edits_applied_format"), editCount))
            }
            if let path = entry.path { parts.append(path) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "delete_file":
            if let path = entry.path { return path }
        case "move_file":
            if let src = entry.source, let dst = entry.destination {
                return "\(src) → \(dst)"
            }
        case "search_files", "grep_files", "glob_files":
            if let matchCount = entry.matchCount {
                if let files = entry.matchedFiles {
                    return String(format: String(localized: "tool_activity.detail.matches_in_files_format"), matchCount, files.count)
                }
                return String(format: String(localized: "tool_activity.detail.matches_format"), matchCount)
            }
        case "web_search", "web_fetch":
            var parts: [String] = []
            if let url = entry.url { parts.append(url) }
            if let code = entry.statusCode { parts.append("HTTP \(code)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "validate_code":
            if let passed = entry.passed {
                let status = passed
                    ? String(localized: "tool_activity.detail.passed")
                    : String(localized: "tool_activity.detail.failed")
                if let errorCount = entry.errorCount, errorCount > 0 {
                    return "\(status) · \(String(format: String(localized: "tool_activity.detail.errors_format"), errorCount))"
                }
                return status
            }
        default:
            return entry.path
        }
        return nil
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return String(format: String(localized: "tool_activity.size.bytes_format"), bytes)
        }
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: String(localized: "tool_activity.size.kb_format"), kb)
        }
        let mb = kb / 1024
        return String(format: String(localized: "tool_activity.size.mb_format"), mb)
    }
}
