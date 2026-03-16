//
//  ImportScanFindingCell.swift
//  Doufu
//

import UIKit

final class ImportScanFindingCell: UITableViewCell {

    static let reuseIdentifier = "ImportScanFindingCell"

    private let severityDot = UIView()
    private let descriptionLabel = UILabel()
    private let locationLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        severityDot.translatesAutoresizingMaskIntoConstraints = false
        severityDot.layer.cornerRadius = 5
        severityDot.layer.masksToBounds = true

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.textColor = .doufuText
        descriptionLabel.numberOfLines = 0

        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        locationLabel.font = {
            let desc = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .caption1)
            if let mono = desc.withDesign(.monospaced) {
                return UIFont(descriptor: mono, size: 0)
            }
            return .preferredFont(forTextStyle: .caption1)
        }()
        locationLabel.adjustsFontForContentSizeCategory = true
        locationLabel.textColor = .secondaryLabel
        locationLabel.numberOfLines = 1

        contentView.addSubview(severityDot)
        contentView.addSubview(descriptionLabel)
        contentView.addSubview(locationLabel)

        NSLayoutConstraint.activate([
            severityDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            severityDot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            severityDot.widthAnchor.constraint(equalToConstant: 10),
            severityDot.heightAnchor.constraint(equalToConstant: 10),

            descriptionLabel.leadingAnchor.constraint(equalTo: severityDot.trailingAnchor, constant: 10),
            descriptionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            descriptionLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            locationLabel.leadingAnchor.constraint(equalTo: descriptionLabel.leadingAnchor),
            locationLabel.trailingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor),
            locationLabel.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 4),
            locationLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
    }

    func configure(description: String, location: String?, severity: FindingSeverity) {
        descriptionLabel.text = description
        locationLabel.text = location
        locationLabel.isHidden = location == nil

        switch severity {
        case .high:
            severityDot.backgroundColor = .systemRed
        case .medium:
            severityDot.backgroundColor = .systemOrange
        case .low:
            severityDot.backgroundColor = .systemYellow
        case .info:
            severityDot.backgroundColor = .systemBlue
        }
    }
}
