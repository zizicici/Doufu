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

    private let messageTextView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 15)
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = .link
        return tv
    }()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return label
    }()

    private let expandButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.setImage(UIImage(systemName: "chevron.right.circle", withConfiguration: config), for: .normal)
        button.isHidden = true
        return button
    }()

    var onExpandTapped: (() -> Void)?

    /// Called when the cell's content changes in a way that may affect row height.
    var onNeedsHeightUpdate: (() -> Void)?

    private var currentMessage: ChatMessage?
    private var animationTimer: Timer?

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(bubbleContainer)
        bubbleContainer.addSubview(messageTextView)
        bubbleContainer.addSubview(metaLabel)
        bubbleContainer.addSubview(expandButton)

        expandButton.addTarget(self, action: #selector(expandButtonTapped), for: .touchUpInside)

        leadingConstraint = bubbleContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        trailingConstraint = bubbleContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)

        // Only activate the leading constraint initially — applyStyle
        // toggles between leading (assistant/system) and trailing (user).
        // Activating both simultaneously causes a constraint conflict with
        // the max-width multiplier constraint.
        trailingConstraint.isActive = false

        NSLayoutConstraint.activate([
            bubbleContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            leadingConstraint,
            bubbleContainer.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.92),

            messageTextView.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 10),
            messageTextView.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            messageTextView.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            metaLabel.topAnchor.constraint(equalTo: messageTextView.bottomAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            metaLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -10),

            expandButton.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            expandButton.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            expandButton.leadingAnchor.constraint(greaterThanOrEqualTo: metaLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAnimationTimer()
        currentMessage = nil
        onExpandTapped = nil
        onNeedsHeightUpdate = nil
        expandButton.isHidden = true
        messageTextView.textContainer.maximumNumberOfLines = 0
        messageTextView.textContainer.lineBreakMode = .byWordWrapping
    }

    // MARK: - Full configuration (called once per message or on finalize)

    func configure(message: ChatMessage, now: Date) {
        let wasLive = currentMessage?.finishedAt == nil
        let isLive = message.finishedAt == nil
        currentMessage = message

        applyContent(message: message, now: now)
        let isActiveProgress = message.isProgress && message.finishedAt == nil
        applyStyle(message: message, isActiveProgress: isActiveProgress)

        if isLive {
            startAnimationTimer()
        } else if wasLive {
            stopAnimationTimer()
        }
    }

    /// Lightweight update: only refreshes the text content (for streaming updates).
    /// Avoids re-applying styles, constraints, markdown rendering, etc.
    func updateText(_ text: String) {
        guard var message = currentMessage else { return }
        message.text = text
        currentMessage = message

        let now = Date()
        let animatedText = displayText(for: message, now: now)
        messageTextView.attributedText = nil
        messageTextView.text = animatedText
        messageTextView.font = .systemFont(ofSize: 15)
        metaLabel.text = metadataText(for: message, now: now)
    }

    // MARK: - Internal animation timer (dots + duration)

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tickAnimation()
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func tickAnimation() {
        guard let message = currentMessage, message.finishedAt == nil else {
            stopAnimationTimer()
            return
        }
        let now = Date()
        // Progress cells: animate dots
        if message.isProgress {
            let animatedText = displayText(for: message, now: now)
            messageTextView.attributedText = nil
            messageTextView.text = animatedText
            messageTextView.font = .systemFont(ofSize: 15)
        }
        // All live cells: tick duration
        metaLabel.text = metadataText(for: message, now: now)
    }

    // MARK: - Private helpers

    private func applyContent(message: ChatMessage, now: Date) {
        metaLabel.text = metadataText(for: message, now: now)

        let useMarkdown = message.role == .assistant && (message.finishedAt != nil || !message.isProgress)

        if useMarkdown {
            messageTextView.attributedText = MarkdownRenderer.render(message.text)
        } else {
            let animatedText = displayText(for: message, now: now)
            messageTextView.attributedText = nil
            messageTextView.text = animatedText
            messageTextView.font = .systemFont(ofSize: 15)
        }

        if message.isProgress {
            messageTextView.textContainer.maximumNumberOfLines = 6
            messageTextView.textContainer.lineBreakMode = .byTruncatingTail
            expandButton.isHidden = false
        } else {
            messageTextView.textContainer.maximumNumberOfLines = 0
            messageTextView.textContainer.lineBreakMode = .byWordWrapping
            expandButton.isHidden = true
        }
    }

    private func applyStyle(message: ChatMessage, isActiveProgress: Bool) {
        let isLive = message.finishedAt == nil
        switch message.role {
        case .user:
            trailingConstraint.isActive = true
            leadingConstraint.isActive = false
            bubbleContainer.backgroundColor = tintColor
            messageTextView.textColor = .white
            messageTextView.linkTextAttributes = [.foregroundColor: UIColor.white, .underlineStyle: NSUnderlineStyle.single.rawValue]
            metaLabel.textColor = UIColor.white.withAlphaComponent(0.78)
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        case .assistant:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = .doufuPaper
            let useMarkdown = message.finishedAt != nil || !message.isProgress
            if !useMarkdown {
                messageTextView.textColor = .label
            }
            messageTextView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]
            metaLabel.textColor = .secondaryLabel
            if isLive {
                bubbleContainer.layer.borderColor = tintColor.withAlphaComponent(0.45).cgColor
            } else {
                bubbleContainer.layer.borderColor = UIColor.clear.cgColor
            }
        case .system:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.24)
            messageTextView.textColor = .secondaryLabel
            messageTextView.linkTextAttributes = [.foregroundColor: UIColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]
            metaLabel.textColor = .tertiaryLabel
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        }
    }

    @objc private func expandButtonTapped() {
        onExpandTapped?()
    }

    private func displayText(for message: ChatMessage, now: Date) -> String {
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

    private func metadataText(for message: ChatMessage, now: Date) -> String {
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
