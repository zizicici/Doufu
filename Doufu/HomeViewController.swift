//
//  HomeViewController.swift
//  Doufu
//
//  Created by Salley Garden on 2026/02/14.
//

import UIKit

private struct HomeProjectItem: Hashable {
    enum Source: Hashable {
        case local
        case imported

        var badgeText: String {
            switch self {
            case .local:
                return "本地"
            case .imported:
                return "导入"
            }
        }
    }

    let id: String
    let name: String
    let summary: String
    let updatedAt: Date
    let source: Source
    let previewImagePath: String?
}

final class HomeViewController: UIViewController {

    private enum LayoutMetric {
        static let columns: CGFloat = 3
        static let horizontalPadding: CGFloat = 16
        static let topPadding: CGFloat = 12
        static let bottomPadding: CGFloat = 20
        static let itemSpacing: CGFloat = 10
    }

    private var allProjects: [HomeProjectItem] = []
    private var filteredProjects: [HomeProjectItem] = []

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = LayoutMetric.itemSpacing
        layout.minimumInteritemSpacing = LayoutMetric.itemSpacing
        layout.sectionInset = UIEdgeInsets(
            top: LayoutMetric.topPadding,
            left: LayoutMetric.horizontalPadding,
            bottom: LayoutMetric.bottomPadding,
            right: LayoutMetric.horizontalPadding
        )

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.keyboardDismissMode = .onDrag
        view.dataSource = self
        view.delegate = self
        view.register(ProjectCardCell.self, forCellWithReuseIdentifier: ProjectCardCell.reuseIdentifier)
        return view
    }()

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = "搜索项目"
        controller.searchResultsUpdater = self
        return controller
    }()

    private lazy var emptyStateContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private lazy var emptyStateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.text = "还没有网页项目，点击右上角 + 创建第一个吧。"
        return label
    }()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigation()
        configureViewHierarchy()
        reloadProjects()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProjects()
    }

    private func configureNavigation() {
        title = "豆腐"
        navigationController?.navigationBar.prefersLargeTitles = false

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(didTapSettingsButton)
        )

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(didTapAddButton)
        )
        definesPresentationContext = true
    }

    private func configureViewHierarchy() {
        view.backgroundColor = .systemBackground
        view.addSubview(collectionView)
        view.addSubview(emptyStateContainer)
        emptyStateContainer.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyStateContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyStateContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyStateContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            emptyStateLabel.leadingAnchor.constraint(equalTo: emptyStateContainer.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(equalTo: emptyStateContainer.trailingAnchor, constant: -24),
            emptyStateLabel.centerYAnchor.constraint(equalTo: emptyStateContainer.centerYAnchor)
        ])
    }

    @objc
    private func didTapAddButton() {
        showPlaceholderAlert(title: "新建项目", message: "下一步将进入项目创建页面。")
    }

    @objc
    private func didTapSettingsButton() {
        let controller = SettingsViewController()
        navigationController?.pushViewController(controller, animated: true)
    }

    private func reloadProjects() {
        allProjects = loadProjectsFromDisk()
        updateSearchBarVisibility()
        applyFilter(using: searchController.searchBar.text)
    }

    private func updateSearchBarVisibility() {
        let hasProjects = !allProjects.isEmpty

        if hasProjects {
            if navigationItem.searchController == nil {
                navigationItem.searchController = searchController
            }
            navigationItem.hidesSearchBarWhenScrolling = false
            return
        }

        if searchController.isActive {
            searchController.isActive = false
        }
        if !(searchController.searchBar.text?.isEmpty ?? true) {
            searchController.searchBar.text = nil
        }
        navigationItem.searchController = nil
    }

    private func loadProjectsFromDisk() -> [HomeProjectItem] {
        let fileManager = FileManager.default
        guard let documentURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }

        let projectsRootURL = documentURL.appendingPathComponent("AppProjects", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var projects: [HomeProjectItem] = []
        for projectURL in urls {
            let values = try? projectURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else {
                continue
            }

            let manifestURL = projectURL.appendingPathComponent("manifest.json")
            let manifest = loadManifest(from: manifestURL)
            let projectId = (manifest["projectId"] as? String) ?? projectURL.lastPathComponent
            let name = (manifest["name"] as? String) ?? projectURL.lastPathComponent
            let summary = (manifest["prompt"] as? String) ?? (manifest["description"] as? String) ?? "暂无描述"
            let source = parseSource(from: manifest["source"] as? String)
            let updatedAt = parseUpdatedAt(from: manifest) ?? values?.contentModificationDate ?? Date()
            let previewImagePath = findPreviewImagePath(in: projectURL)

            projects.append(
                HomeProjectItem(
                    id: projectId,
                    name: name,
                    summary: summary,
                    updatedAt: updatedAt,
                    source: source,
                    previewImagePath: previewImagePath
                )
            )
        }

        return projects.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    private func loadManifest(from url: URL) -> [String: Any] {
        guard
            let data = try? Data(contentsOf: url),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let json = rawObject as? [String: Any]
        else {
            return [:]
        }
        return json
    }

    private func parseUpdatedAt(from manifest: [String: Any]) -> Date? {
        guard let rawValue = manifest["updatedAt"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        return formatter.date(from: rawValue)
    }

    private func parseSource(from rawValue: String?) -> HomeProjectItem.Source {
        guard let rawValue else {
            return .local
        }
        return rawValue.lowercased() == "imported" ? .imported : .local
    }

    private func findPreviewImagePath(in projectURL: URL) -> String? {
        let fileManager = FileManager.default
        let candidates = ["preview.png", "thumbnail.png", "snapshot.png"]

        for fileName in candidates {
            let imageURL = projectURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: imageURL.path) {
                return imageURL.path
            }
        }

        return nil
    }

    private func applyFilter(using query: String?) {
        let keyword = (query ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if keyword.isEmpty {
            filteredProjects = allProjects
        } else {
            filteredProjects = allProjects.filter { project in
                project.name.lowercased().contains(keyword) || project.summary.lowercased().contains(keyword)
            }
        }

        collectionView.reloadData()
        updateEmptyState(for: keyword)
    }

    private func updateEmptyState(for keyword: String) {
        emptyStateLabel.text = keyword.isEmpty
            ? "还没有网页项目，点击右上角 + 创建第一个吧。"
            : "没有匹配的项目，换个关键词试试。"
        emptyStateContainer.isHidden = !filteredProjects.isEmpty
    }

    private func openProject(_ project: HomeProjectItem) {
        showPlaceholderAlert(title: project.name, message: "下一步将打开该项目的运行页面。")
    }

    private func showPlaceholderAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

}

extension HomeViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        applyFilter(using: searchController.searchBar.text)
    }
}

extension HomeViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredProjects.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ProjectCardCell.reuseIdentifier,
                for: indexPath
            ) as? ProjectCardCell
        else {
            return UICollectionViewCell()
        }

        let project = filteredProjects[indexPath.item]
        let dateText = dateFormatter.string(from: project.updatedAt)
        cell.configure(project: project, dateText: dateText)
        return cell
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let project = filteredProjects[indexPath.item]
        openProject(project)
    }
}

extension HomeViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let totalSpacing = LayoutMetric.itemSpacing * (LayoutMetric.columns - 1)
        let availableWidth = collectionView.bounds.width
            - LayoutMetric.horizontalPadding * 2
            - totalSpacing
        let itemWidth = floor(availableWidth / LayoutMetric.columns)
        return CGSize(width: itemWidth, height: itemWidth * 1.22)
    }
}

private final class ProjectCardCell: UICollectionViewCell {

    static let reuseIdentifier = "ProjectCardCell"

    private let previewContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemGray6
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private let previewImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }()

    private let placeholderIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "doc.richtext"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .tertiaryLabel
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let sourceBadgeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.layer.cornerRadius = 6
        label.layer.masksToBounds = true
        label.textAlignment = .center
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 2
        return label
    }()

    private let dateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViewHierarchy()
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewImageView.image = nil
        placeholderIconView.isHidden = false
    }

    func configure(project: HomeProjectItem, dateText: String) {
        titleLabel.text = project.name
        dateLabel.text = dateText
        sourceBadgeLabel.text = "  \(project.source.badgeText)  "

        if let previewImagePath = project.previewImagePath, let image = UIImage(contentsOfFile: previewImagePath) {
            previewImageView.image = image
            placeholderIconView.isHidden = true
        } else {
            previewImageView.image = nil
            placeholderIconView.isHidden = false
        }
    }

    private func configureViewHierarchy() {
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = UIColor.separator.withAlphaComponent(0.22).cgColor
        contentView.clipsToBounds = true

        contentView.addSubview(previewContainer)
        previewContainer.addSubview(previewImageView)
        previewContainer.addSubview(placeholderIconView)
        previewContainer.addSubview(sourceBadgeLabel)
        contentView.addSubview(titleLabel)
        contentView.addSubview(dateLabel)
    }

    private func configureLayout() {
        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            previewContainer.heightAnchor.constraint(equalTo: contentView.heightAnchor, multiplier: 0.63),

            previewImageView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImageView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            previewImageView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            previewImageView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),

            placeholderIconView.centerXAnchor.constraint(equalTo: previewContainer.centerXAnchor),
            placeholderIconView.centerYAnchor.constraint(equalTo: previewContainer.centerYAnchor),
            placeholderIconView.widthAnchor.constraint(equalToConstant: 24),
            placeholderIconView.heightAnchor.constraint(equalToConstant: 24),

            sourceBadgeLabel.topAnchor.constraint(equalTo: previewContainer.topAnchor, constant: 8),
            sourceBadgeLabel.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 8),

            titleLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),

            dateLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            dateLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            dateLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8)
        ])
    }
}
