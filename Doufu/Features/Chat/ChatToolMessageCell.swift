//
//  ChatToolMessageCell.swift
//  Doufu
//

import UIKit

final class ChatToolMessageCell: UITableViewCell {
    static let reuseIdentifier = "ChatToolMessageCell"

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor.doufuText.withAlphaComponent(0.65)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private var animationTimer: Timer?
    private var currentMessage: ChatMessage?

    var onTapped: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 60),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -60),
        ])

        label.isUserInteractionEnabled = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        label.addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopAnimationTimer()
        currentMessage = nil
        onTapped = nil
    }

    func configure(message: ChatMessage) {
        currentMessage = message
        label.text = displayText(for: message, now: Date())

        if message.finishedAt == nil {
            startAnimationTimer()
        } else {
            stopAnimationTimer()
        }
    }

    // MARK: - Private

    @objc private func handleTap() {
        onTapped?()
    }

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, let message = self.currentMessage else { return }
            if message.finishedAt != nil {
                self.stopAnimationTimer()
                return
            }
            self.label.text = self.displayText(for: message, now: Date())
        }
    }

    private func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func displayText(for message: ChatMessage, now: Date) -> String {
        let rawText = message.summary ?? message.content
        guard message.finishedAt == nil else { return rawText }
        let baseText = rawText.replacingOccurrences(
            of: #"[.。…\s]+$"#, with: "", options: .regularExpression
        )
        let phase = Int((now.timeIntervalSinceReferenceDate * 2).rounded(.down)) % 3 + 1
        return baseText + String(repeating: ".", count: phase)
    }
}
