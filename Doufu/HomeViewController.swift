//
//  HomeViewController.swift
//  Doufu
//
//  Created by Salley Garden on 2026/02/14.
//

import UIKit

final class HomeViewController: UIViewController {

    private let scrollView = UIScrollView()
    private let contentStackView = UIStackView()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "我的网页 App"
        label.font = .systemFont(ofSize: 32, weight: .bold)
        label.numberOfLines = 0
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "通过一句需求，快速生成并运行你的本地网页"
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    private lazy var createProjectButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "新建网页"
        configuration.subtitle = "创建一个新的本地网页项目"
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = .systemBlue
        configuration.baseForegroundColor = .white

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(didTapCreateProject), for: .touchUpInside)
        return button
    }()

    private lazy var openProjectButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = "打开已有网页"
        configuration.subtitle = "继续编辑和运行已有项目"
        configuration.cornerStyle = .large

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: #selector(didTapOpenProject), for: .touchUpInside)
        return button
    }()

    private let projectsTitleLabel: UILabel = {
        let label = UILabel()
        label.text = "本地网页项目"
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }()

    private let emptyStateContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 14
        return view
    }()

    private let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.text = "还没有网页项目，先创建第一个吧。"
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigation()
        configureViewHierarchy()
        configureLayout()
    }

    private func configureNavigation() {
        navigationItem.title = "Doufu"
        navigationController?.navigationBar.prefersLargeTitles = true
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .systemBackground

        contentStackView.axis = .vertical
        contentStackView.spacing = 16
        contentStackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentStackView)

        contentStackView.addArrangedSubview(titleLabel)
        contentStackView.addArrangedSubview(subtitleLabel)
        contentStackView.addArrangedSubview(createProjectButton)
        contentStackView.addArrangedSubview(openProjectButton)
        contentStackView.addArrangedSubview(projectsTitleLabel)
        contentStackView.addArrangedSubview(emptyStateContainer)

        emptyStateContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateContainer.addSubview(emptyStateLabel)
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            contentStackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
            contentStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),

            createProjectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
            openProjectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),

            emptyStateLabel.topAnchor.constraint(equalTo: emptyStateContainer.topAnchor, constant: 20),
            emptyStateLabel.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor, constant: 16),
            emptyStateLabel.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor, constant: -16),
            emptyStateLabel.bottomAnchor.constraint(equalTo: emptyStateContainer.bottomAnchor, constant: -20)
        ])
    }

    @objc
    private func didTapCreateProject() {
        showPlaceholderAlert(title: "新建网页", message: "下一步将接入项目命名与需求输入流程。")
    }

    @objc
    private func didTapOpenProject() {
        showPlaceholderAlert(title: "打开已有网页", message: "下一步将接入本地项目列表与打开流程。")
    }

    private func showPlaceholderAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

}
