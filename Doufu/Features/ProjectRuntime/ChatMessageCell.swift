//
//  ChatMessageCell.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

final class ChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "ChatMessageCell"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let bubbleContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.clear.cgColor
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        return label
    }()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return label
    }()

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(bubbleContainer)
        bubbleContainer.addSubview(messageLabel)
        bubbleContainer.addSubview(metaLabel)

        leadingConstraint = bubbleContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        trailingConstraint = bubbleContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)

        NSLayoutConstraint.activate([
            bubbleContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            leadingConstraint,
            trailingConstraint,
            bubbleContainer.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.92),

            messageLabel.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            metaLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            metaLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: ProjectChatViewController.Message, now: Date) {
        metaLabel.text = metadataText(for: message, now: now)

        let useMarkdown = message.role == .assistant && (message.finishedAt != nil || !message.isProgress)

        if useMarkdown {
            messageLabel.attributedText = MarkdownRenderer.render(message.text)
        } else {
            let animatedText = displayText(for: message, now: now)
            messageLabel.attributedText = nil
            messageLabel.text = animatedText
        }

        switch message.role {
        case .user:
            trailingConstraint.isActive = true
            leadingConstraint.isActive = false
            bubbleContainer.backgroundColor = tintColor
            if !useMarkdown {
                messageLabel.textColor = .white
            }
            metaLabel.textColor = UIColor.white.withAlphaComponent(0.78)
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        case .assistant:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = .secondarySystemGroupedBackground
            if !useMarkdown {
                messageLabel.textColor = .label
            }
            metaLabel.textColor = .secondaryLabel
            if message.isProgress && message.finishedAt == nil {
                bubbleContainer.layer.borderColor = tintColor.withAlphaComponent(0.45).cgColor
            } else {
                bubbleContainer.layer.borderColor = UIColor.clear.cgColor
            }
        case .system:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.24)
            messageLabel.textColor = .secondaryLabel
            metaLabel.textColor = .tertiaryLabel
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        }
    }

    private func displayText(for message: ProjectChatViewController.Message, now: Date) -> String {
        guard message.isProgress, message.finishedAt == nil else {
            return message.text
        }
        let baseText = message.text.replacingOccurrences(
            of: #"[.。…\s]+$"#,
            with: "",
            options: .regularExpression
        )
        let phase = Int((now.timeIntervalSinceReferenceDate * 2).rounded(.down)) % 3 + 1
        let dots = String(repeating: ".", count: phase)
        return baseText + dots
    }

    private func metadataText(for message: ProjectChatViewController.Message, now: Date) -> String {
        let timestamp = Self.timestampFormatter.string(from: message.createdAt)
        var parts: [String] = [timestamp]
        if message.role != .user {
            let endAt = message.finishedAt ?? now
            let duration = max(0, endAt.timeIntervalSince(message.startedAt))
            let durationString = formatDuration(duration)
            if message.isProgress {
                parts.append(message.finishedAt == nil
                    ? String(localized: "chat.meta.in_progress")
                    : String(localized: "chat.meta.completed"))
            }
            parts.append(durationString)
        }
        if let usageText = tokenUsageText(for: message.requestTokenUsage), message.finishedAt != nil {
            parts.append(usageText)
        }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            let milliseconds = Int((duration * 1000).rounded())
            return String(format: String(localized: "chat.duration.ms_format"), milliseconds)
        }
        if duration < 60 {
            return String(format: String(localized: "chat.duration.seconds_format"), duration)
        }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        return String(format: String(localized: "chat.duration.minutes_seconds_format"), minutes, seconds)
    }

    private func tokenUsageText(for usage: ProjectChatService.RequestTokenUsage?) -> String? {
        guard let usage else {
            return nil
        }
        let inputText = formatTokenCountInK(usage.inputTokens)
        let outputText = formatTokenCountInK(usage.outputTokens)
        return "↑\(inputText) ↓\(outputText)"
    }

    private func formatTokenCountInK(_ value: Int64) -> String {
        let kiloValue = Double(max(0, value)) / 1000
        if kiloValue >= 100 {
            return String(format: "%.0fK", kiloValue)
        }
        if kiloValue >= 10 {
            return String(format: "%.1fK", kiloValue)
        }
        return String(format: "%.2fK", kiloValue)
    }
}
