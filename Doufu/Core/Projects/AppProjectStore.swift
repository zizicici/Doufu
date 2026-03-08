//
//  AppProjectStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation

struct AppProjectRecord: Equatable, Hashable {
    let id: String
    let name: String
    let projectURL: URL
    let entryFileURL: URL
    let createdAt: Date
    let updatedAt: Date
}

enum AppProjectStoreError: LocalizedError {
    case unavailableDocumentsDirectory
    case projectCreationFailed
    case invalidProjectLocation
    case projectDeletionFailed
    case invalidProjectName
    case manifestUpdateFailed

    var errorDescription: String? {
        switch self {
        case .unavailableDocumentsDirectory:
            return String(localized: "project_store.error.unavailable_documents_directory")
        case .projectCreationFailed:
            return String(localized: "project_store.error.project_creation_failed")
        case .invalidProjectLocation:
            return String(localized: "project_store.error.invalid_project_location")
        case .projectDeletionFailed:
            return String(localized: "project_store.error.project_deletion_failed")
        case .invalidProjectName:
            return String(localized: "project_store.error.invalid_project_name")
        case .manifestUpdateFailed:
            return String(localized: "project_store.error.manifest_update_failed")
        }
    }
}

final class AppProjectStore {
    static let shared = AppProjectStore()

    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatter = formatter
    }

    @discardableResult
    func createBlankProject(name: String? = nil) throws -> AppProjectRecord {
        let projectsRootURL = try ensureProjectsRootDirectory()

        let projectID = "project-\(UUID().uuidString.lowercased())"
        let projectURL = projectsRootURL.appendingPathComponent(projectID, isDirectory: true)
        let now = Date()
        let projectName = normalizeProjectName(name, createdAt: now)

        do {
            try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
            try writeBlankWebsiteFiles(projectID: projectID, name: projectName, now: now, projectURL: projectURL)
            try ProjectGitService.shared.initializeRepository(at: projectURL)
        } catch {
            try? fileManager.removeItem(at: projectURL)
            throw AppProjectStoreError.projectCreationFailed
        }

        return AppProjectRecord(
            id: projectID,
            name: projectName,
            projectURL: projectURL,
            entryFileURL: projectURL.appendingPathComponent("index.html"),
            createdAt: now,
            updatedAt: now
        )
    }

    func touchProjectUpdatedAt(projectURL: URL) {
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            var manifestObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return
        }

        manifestObject["updatedAt"] = isoFormatter.string(from: Date())
        guard let updatedData = try? JSONSerialization.data(withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? updatedData.write(to: manifestURL, options: .atomic)
    }

    func deleteProject(projectURL: URL) throws {
        let rootURL = try ensureProjectsRootDirectory()
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let targetPath = projectURL.standardizedFileURL.path

        guard targetPath.hasPrefix(rootPrefix) else {
            throw AppProjectStoreError.invalidProjectLocation
        }

        guard fileManager.fileExists(atPath: targetPath) else {
            return
        }

        do {
            try fileManager.removeItem(at: projectURL)
        } catch {
            throw AppProjectStoreError.projectDeletionFailed
        }
    }

    func loadProjectName(projectURL: URL) -> String {
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawName = object["name"] as? String
        else {
            return projectURL.lastPathComponent
        }

        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? projectURL.lastPathComponent : trimmedName
    }

    func updateProjectName(projectURL: URL, name: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppProjectStoreError.invalidProjectName
        }

        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw AppProjectStoreError.manifestUpdateFailed
        }

        object["name"] = normalizedName
        object["updatedAt"] = isoFormatter.string(from: Date())

        do {
            let updatedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: manifestURL, options: .atomic)
        } catch {
            throw AppProjectStoreError.manifestUpdateFailed
        }
    }

    // MARK: - App-Level Tool Permission Mode (Default)

    private static let appToolPermissionModeKey = "appDefaultToolPermissionMode"

    func loadAppToolPermissionMode() -> ToolPermissionMode {
        guard
            let raw = UserDefaults.standard.string(forKey: Self.appToolPermissionModeKey),
            let mode = ToolPermissionMode(rawValue: raw)
        else {
            return .standard
        }
        return mode
    }

    func saveAppToolPermissionMode(_ mode: ToolPermissionMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appToolPermissionModeKey)
    }

    // MARK: - Project-Level Tool Permission Mode

    /// Returns the project-level override, or nil if not explicitly set.
    func loadProjectToolPermissionOverride(projectURL: URL) -> ToolPermissionMode? {
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMode = object["toolPermissionMode"] as? String,
            let mode = ToolPermissionMode(rawValue: rawMode)
        else {
            return nil
        }
        return mode
    }

    /// Returns the effective tool permission mode: project override if set, otherwise app default.
    func loadToolPermissionMode(projectURL: URL) -> ToolPermissionMode {
        loadProjectToolPermissionOverride(projectURL: projectURL) ?? loadAppToolPermissionMode()
    }

    func saveToolPermissionMode(projectURL: URL, mode: ToolPermissionMode?) throws {
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw AppProjectStoreError.manifestUpdateFailed
        }

        if let mode {
            object["toolPermissionMode"] = mode.rawValue
        } else {
            object.removeValue(forKey: "toolPermissionMode")
        }
        object["updatedAt"] = isoFormatter.string(from: Date())

        do {
            let updatedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try updatedData.write(to: manifestURL, options: .atomic)
        } catch {
            throw AppProjectStoreError.manifestUpdateFailed
        }
    }

    private func ensureProjectsRootDirectory() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppProjectStoreError.unavailableDocumentsDirectory
        }

        let projectsRootURL = documentsURL.appendingPathComponent("AppProjects", isDirectory: true)
        if !fileManager.fileExists(atPath: projectsRootURL.path) {
            try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        }
        return projectsRootURL
    }

    private func normalizeProjectName(_ rawName: String?, createdAt: Date) -> String {
        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MMdd-HHmm"
        return String(format: String(localized: "project_store.default_project_name_format"), formatter.string(from: createdAt))
    }

    private func writeBlankWebsiteFiles(
        projectID: String,
        name: String,
        now: Date,
        projectURL: URL
    ) throws {
        let blankPageTag = String(localized: "project_template.blank_page.tag")
        let blankPageHintEmpty = String(localized: "project_template.blank_page.hint.empty")
        let blankPageHintChat = String(localized: "project_template.blank_page.hint.chat")

        let indexHTML = """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover" />
            <title>\(name)</title>
            <link rel="stylesheet" href="./style.css" />
          </head>
          <body>
            <main class="screen">
              <section class="empty-card">
                <p class="tag">\(blankPageTag)</p>
                <h1>\(name)</h1>
                <p class="hint">\(blankPageHintEmpty)</p>
                <p class="hint">\(blankPageHintChat)</p>
              </section>
            </main>
            <script src="./script.js"></script>
          </body>
        </html>
        """

        let styleCSS = """
        :root {
          color-scheme: light;
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          min-height: 100dvh;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
          background: #f8fafc;
          color: #0f172a;
        }

        .screen {
          min-height: 100dvh;
          padding:
            calc(env(safe-area-inset-top) + 20px)
            16px
            calc(env(safe-area-inset-bottom) + 20px);
          display: flex;
          align-items: center;
          justify-content: center;
        }

        .empty-card {
          width: min(520px, 100%);
          background: #ffffff;
          border-radius: 18px;
          border: 1px solid #e2e8f0;
          padding: 20px 18px;
          box-shadow: 0 8px 24px rgba(15, 23, 42, 0.08);
        }

        .tag {
          margin: 0;
          font-size: 12px;
          font-weight: 600;
          color: #64748b;
        }

        h1 {
          margin: 8px 0 14px;
          font-size: 26px;
          line-height: 1.2;
        }

        .hint {
          margin: 0;
          line-height: 1.55;
          color: #334155;
          font-size: 14px;
        }
        """

        let scriptJS = """
        (() => {})();
        """

        let projectAgentsInstructions = """
        # AGENTS.md

        This project targets iPhone-first web UX.

        ## Core principle
        - Treat this as an iPhone app-like experience, not a desktop web page.
        - Prioritize native-like interaction and behavior over visual decoration.

        ## Mobile-first requirements (MUST)
        - Treat iPhone portrait as the default viewport.
        - Respect Safe Area using `env(safe-area-inset-top/right/bottom/left)`.
        - Keep the primary layout single-column unless explicitly requested.
        - Ensure touch targets are at least 44px tall.
        - Avoid desktop-only interaction patterns such as hover-dependent controls.
        - Avoid strong "desktop web" visual style; prefer a clean, native-like iOS feel.

        ## Zoom & viewport policy (MUST)
        - Disable zoom by default (including pinch and double-tap zoom).
        - Ensure viewport uses:
          `width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover`.
        - Do not create horizontal overflow layouts.

        ## Selection policy (MUST)
        - Non-content UI text must be non-selectable:
          nav bars, tabs, buttons, chips, badges, card titles, tool labels.
        - Only content text and form controls (`input`, `textarea`) may allow text selection.
        - Disable long-press callout on non-content UI (`-webkit-touch-callout: none`).

        ## Scroll model (MUST)
        - Use exactly one primary scroll container for page content.
        - `html` and `body` must not be scrollable.
        - If content fits within the viewport, dragging must not move/stretch the whole page.
        - Any secondary scrollable area must scroll only inside its own bounds.
        - Prevent scroll chaining between nested containers.

        ## Layout & containment (MUST)
        - Lock app root to the viewport height (`100dvh`) with safe-area insets.
        - Keep top/bottom bars fixed; only content region scrolls.
        - Prevent horizontal scrolling (`overflow-x: hidden`).
        - Media must stay in bounds (`max-width: 100%`).

        ## Forms & keyboard behavior
        - Use at least `16px` font size for text inputs to avoid iOS auto-zoom.
        - Keyboard appearance should not break layout hierarchy.
        - Keep key actions and input controls easily reachable on small screens.

        ## Interaction polish
        - Use `touch-action: manipulation` on tappable controls where appropriate.
        - Keep motion subtle and meaningful; avoid flashy web-like transitions.

        ## Styling guidance
        - Prioritize readability and spacing on small screens.
        - Prefer system-like typography and restrained visual decoration.
        - Keep contrast and hierarchy clear without heavy borders/shadows.

        ## Editing guidance
        - Change the minimum necessary files for each request.
        - Keep the app fully runnable as static `html/css/js`.
        - Preserve `manifest.json` and `index.html` as entry structure unless requested.
        """

        let projectMemoryDocument = """
        # DOUFU.MD

        ## Project Identity
        - Name: \(name)
        - Project ID: \(projectID)
        - Entry: index.html
        - Created At: \(isoFormatter.string(from: now))

        ## Architecture
        - Runtime: Static web app (html/css/js) rendered in WKWebView.
        - Default device target: iPhone portrait.
        - Key constraints are defined in AGENTS.md.

        ## Core Files
        - index.html: App shell and semantic structure.
        - style.css: Visual system and layout behavior.
        - script.js: Interaction logic and state updates.
        - manifest.json: Project metadata.
        - AGENTS.md: Coding/UX constraints for AI edits.
        - DOUFU.MD: Long-lived project memory and architecture notes.

        ## Product Intent
        - This project should feel like a mobile-native app, not a desktop webpage.
        - Prefer simple, maintainable structure over heavy frameworks.

        ## Important Notes
        - Keep safe-area support and touch ergonomics as first-class requirements.
        - When introducing new features, update this file with architecture changes.
        """

        let manifestObject: [String: Any] = [
            "projectId": projectID,
            "name": name,
            "source": "local",
            "prompt": String(localized: "project_template.prompt.blank_web_project"),
            "description": String(localized: "project_template.description.iterate_by_chat"),
            "createdAt": isoFormatter.string(from: now),
            "updatedAt": isoFormatter.string(from: now),
            "entryFilePath": "index.html"
        ]

        let indexURL = projectURL.appendingPathComponent("index.html")
        let styleURL = projectURL.appendingPathComponent("style.css")
        let scriptURL = projectURL.appendingPathComponent("script.js")
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        let agentsURL = projectURL.appendingPathComponent("AGENTS.md")
        let doufuURL = projectURL.appendingPathComponent("DOUFU.MD")

        try indexHTML.write(to: indexURL, atomically: true, encoding: .utf8)
        try styleCSS.write(to: styleURL, atomically: true, encoding: .utf8)
        try scriptJS.write(to: scriptURL, atomically: true, encoding: .utf8)
        try projectAgentsInstructions.write(to: agentsURL, atomically: true, encoding: .utf8)
        try projectMemoryDocument.write(to: doufuURL, atomically: true, encoding: .utf8)
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)
    }
}
