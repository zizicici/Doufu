//
//  CapabilityToastView.swift
//  Doufu
//

import UIKit

final class CapabilityToastView: UIView {

    private let iconView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .white
        view.contentMode = .scaleAspectFit
        return view
    }()

    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .subheadline, weight: .semibold)
        label.textColor = .white
        return label
    }()

    init(capabilityType: CapabilityType) {
        super.init(frame: .zero)

        backgroundColor = Self.color(for: capabilityType)
        layer.cornerCurve = .continuous

        iconView.image = Self.icon(for: capabilityType)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        label.text = capabilityType.displayName

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Appearance

    private static func color(for type: CapabilityType) -> UIColor {
        switch type {
        case .camera: return .systemRed
        case .microphone: return .systemOrange
        case .location: return .systemBlue
        case .clipboardRead, .clipboardWrite: return .systemPurple
        case .photoSave: return .systemGreen
        }
    }

    private static func icon(for type: CapabilityType) -> UIImage? {
        switch type {
        case .camera: return UIImage(systemName: "camera.fill")
        case .microphone: return UIImage(systemName: "mic.fill")
        case .location: return UIImage(systemName: "location.fill")
        case .clipboardRead: return UIImage(systemName: "doc.on.clipboard")
        case .clipboardWrite: return UIImage(systemName: "doc.on.clipboard")
        case .photoSave: return UIImage(systemName: "photo")
        }
    }
}
