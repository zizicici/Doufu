//
//  SearXNGURLEditorViewController.swift
//  Doufu
//

import UIKit

@MainActor
final class SearXNGURLEditorViewController: UIViewController, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let projectStore = AppProjectStore.shared
    private var isTesting = false

    /// Local draft — committed to global config when leaving the page.
    private var draftURL: String

    init() {
        self.draftURL = AppProjectStore.shared.searxngBaseURL ?? ""
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "settings.project.searxng.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.keyboardDismissMode = .onDrag

        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        tableView.dataSource = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Persist draft to global config when leaving.
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        projectStore.searxngBaseURL = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Test Connection

    private func testConnection() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return }

        guard let url = URL(string: "\(trimmed)/search?q=test&format=json&categories=general") else {
            showAlert(
                title: String(localized: "settings.project.searxng.test_fail"),
                message: "Invalid URL"
            )
            return
        }

        isTesting = true
        tableView.reloadSections(IndexSet(integer: 1), with: .none)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Task {
            defer {
                isTesting = false
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    showAlert(
                        title: String(localized: "settings.project.searxng.test_fail"),
                        message: "HTTP \(code)"
                    )
                    return
                }
                // Use the same model as WebToolProvider to guarantee consistency
                let decoded = try JSONDecoder().decode(SearXNGTestResponse.self, from: data)
                showAlert(
                    title: String(localized: "settings.project.searxng.test_success"),
                    message: "\(decoded.results.count) results"
                )
            } catch {
                showAlert(
                    title: String(localized: "settings.project.searxng.test_fail"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 && !isTesting {
            testConnection()
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return String(localized: "settings.project.searxng.footer")
        }
        return nil
    }
}

// MARK: - UITableViewDataSource

extension SearXNGURLEditorViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsTextInputCell.reuseIdentifier, for: indexPath
            ) as! SettingsTextInputCell
            cell.configure(
                title: nil,
                text: draftURL,
                placeholder: String(localized: "settings.project.searxng.placeholder"),
                keyboardType: .URL
            ) { [weak self] text in
                self?.draftURL = text
            }
            return cell
        } else {
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsCenteredButtonCell.reuseIdentifier, for: indexPath
            ) as! SettingsCenteredButtonCell
            cell.configure(
                title: String(localized: "settings.project.searxng.test"),
                isEnabled: !isTesting
            )
            return cell
        }
    }
}

// MARK: - Test Response Model (matches WebToolProvider.SearXNGResponse)

private struct SearXNGTestResponse: Codable {
    let results: [SearXNGTestResult]
}

private struct SearXNGTestResult: Codable {
    let title: String
    let url: String
    let content: String?
}
