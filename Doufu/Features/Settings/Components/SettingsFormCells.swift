//
//  SettingsFormCells.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class SettingsTextInputCell: UITableViewCell {
    static let reuseIdentifier = "SettingsTextInputCell"

    private let stackView = UIStackView()
    private let titleLabel = UILabel()
    let textField = UITextField()

    private var onTextChanged: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViewHierarchy()
        configureStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTextChanged = nil
        titleLabel.text = nil
        titleLabel.isHidden = true
        textField.text = nil
        textField.placeholder = nil
        textField.keyboardType = .default
        textField.autocapitalizationType = .none
    }

    func configure(
        title: String?,
        text: String?,
        placeholder: String,
        keyboardType: UIKeyboardType = .default,
        autocapitalizationType: UITextAutocapitalizationType = .none,
        onTextChanged: @escaping (String) -> Void
    ) {
        self.onTextChanged = onTextChanged

        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleLabel.isHidden = trimmedTitle.isEmpty
        titleLabel.text = trimmedTitle

        textField.text = text
        textField.placeholder = placeholder
        textField.keyboardType = keyboardType
        textField.autocapitalizationType = autocapitalizationType
        textField.textAlignment = trimmedTitle.isEmpty ? .natural : .right
    }

    private func configureViewHierarchy() {
        selectionStyle = .none

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 12
        contentView.addSubview(stackView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
        titleLabel.textColor = .label
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.font = .systemFont(ofSize: 17, weight: .regular)
        textField.addTarget(self, action: #selector(handleTextChange), for: .editingChanged)

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(textField)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    private func configureStyle() {
        var margins = contentView.directionalLayoutMargins
        margins.top = 12
        margins.bottom = 12
        contentView.directionalLayoutMargins = margins
    }

    @objc
    private func handleTextChange() {
        onTextChanged?(textField.text ?? "")
    }
}

final class SettingsSecureInputCell: UITableViewCell {
    static let reuseIdentifier = "SettingsSecureInputCell"

    let textField = UITextField()
    private let visibilityButton = UIButton(type: .system)
    private var onTextChanged: ((String) -> Void)?
    private var isTextVisible = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViewHierarchy()
        configureStyle()
        setTextVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTextChanged = nil
        textField.text = nil
        textField.placeholder = nil
        setTextVisible(false)
    }

    func configure(
        text: String?,
        placeholder: String,
        onTextChanged: @escaping (String) -> Void
    ) {
        self.onTextChanged = onTextChanged
        textField.text = text
        textField.placeholder = placeholder
    }

    private func configureViewHierarchy() {
        selectionStyle = .none

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.font = .systemFont(ofSize: 17, weight: .regular)
        textField.addTarget(self, action: #selector(handleTextChange), for: .editingChanged)
        contentView.addSubview(textField)

        visibilityButton.setImage(UIImage(systemName: "eye"), for: .normal)
        visibilityButton.tintColor = .secondaryLabel
        visibilityButton.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        visibilityButton.addTarget(self, action: #selector(toggleVisibility), for: .touchUpInside)

        textField.rightView = visibilityButton
        textField.rightViewMode = .always

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textField.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            textField.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    private func configureStyle() {
        var margins = contentView.directionalLayoutMargins
        margins.top = 12
        margins.bottom = 12
        contentView.directionalLayoutMargins = margins
    }

    private func setTextVisible(_ isVisible: Bool) {
        isTextVisible = isVisible
        let originalText = textField.text
        textField.isSecureTextEntry = !isVisible
        textField.text = nil
        textField.text = originalText

        let symbol = isVisible ? "eye.slash" : "eye"
        visibilityButton.setImage(UIImage(systemName: symbol), for: .normal)
    }

    @objc
    private func handleTextChange() {
        onTextChanged?(textField.text ?? "")
    }

    @objc
    private func toggleVisibility() {
        setTextVisible(!isTextVisible)
    }
}

final class SettingsToggleCell: UITableViewCell {
    static let reuseIdentifier = "SettingsToggleCell"

    private let toggle = UISwitch()
    private var onValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(handleToggleValueChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onValueChanged = nil
    }

    func configure(
        title: String,
        isOn: Bool,
        onValueChanged: @escaping (Bool) -> Void
    ) {
        self.onValueChanged = onValueChanged
        toggle.isOn = isOn

        var configuration = defaultContentConfiguration()
        configuration.text = title
        contentConfiguration = configuration
    }

    @objc
    private func handleToggleValueChanged() {
        onValueChanged?(toggle.isOn)
    }
}

final class SettingsCenteredButtonCell: UITableViewCell {
    static let reuseIdentifier = "SettingsCenteredButtonCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isUserInteractionEnabled = true
        selectionStyle = .default
    }

    func configure(
        title: String,
        tintColor: UIColor = .systemBlue,
        isEnabled: Bool = true
    ) {
        var configuration = UIListContentConfiguration.cell()
        configuration.text = title
        configuration.textProperties.alignment = .center
        configuration.textProperties.color = isEnabled ? tintColor : .tertiaryLabel
        configuration.textProperties.font = .systemFont(ofSize: 17, weight: .semibold)
        contentConfiguration = configuration

        isUserInteractionEnabled = isEnabled
        selectionStyle = isEnabled ? .default : .none
    }
}
