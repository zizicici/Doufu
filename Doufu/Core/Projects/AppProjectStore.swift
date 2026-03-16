//
//  AppProjectStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import Foundation
import UIKit
import GRDB

struct AppProjectRecord: Equatable, Hashable {
    let id: String              // Pure UUID (no "project-" prefix)
    let name: String
    let projectURL: URL         // Projects/{uuid}/
    let createdAt: Date
    let updatedAt: Date

    var appURL: URL { projectURL.appendingPathComponent("App") }
    var dataURL: URL { projectURL.appendingPathComponent("AppData") }
    var entryFileURL: URL { appURL.appendingPathComponent("index.html") }
}

struct AppProjectMetadataSnapshot: Equatable {
    let id: String
    let name: String
    let description: String
    let createdAt: Date
    let updatedAt: Date
    let toolPermissionOverride: ToolPermissionMode?
}

enum AppProjectStoreError: LocalizedError {
    case unavailableDocumentsDirectory
    case projectCreationFailed
    case invalidProjectLocation
    case projectDeletionFailed
    case invalidProjectName

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
        }
    }
}

final class AppProjectStore {
    static let shared = AppProjectStore()

    private let fileManager: FileManager
    private var dbPool: DatabasePool { DatabaseManager.shared.dbPool }

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func createBlankProject(name: String? = nil) async throws -> AppProjectRecord {
        let projectsRootURL = try ensureProjectsRootDirectory()

        let projectID = UUID().uuidString.lowercased()
        let projectURL = projectsRootURL.appendingPathComponent(projectID, isDirectory: true)
        let appURL = projectURL.appendingPathComponent("App", isDirectory: true)
        let dataURL = projectURL.appendingPathComponent("AppData", isDirectory: true)
        let now = Date()
        let baseProjectName = normalizeProjectName(name)
        let description = String(localized: "project_template.description.iterate_by_chat")

        let fm = fileManager
        let record = try await Task.detached(priority: .userInitiated) {
            var projectName = baseProjectName
            var insertedProjectRecord = false
            do {
                projectName = try self.dbPool.write { db in
                    let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM project") ?? 0
                    let uniqueProjectName = try Self.makeUniqueProjectName(baseName: baseProjectName, in: db)
                    let nowNanos = DatabaseTimestamp.toNanos(now)
                    let dbProject = DBProject(
                        id: projectID,
                        createdAt: nowNanos,
                        title: uniqueProjectName,
                        description: description,
                        sortOrder: maxOrder + 1,
                        updatedAt: nowNanos
                    )
                    try dbProject.insert(db)
                    return uniqueProjectName
                }
                insertedProjectRecord = true

                try fm.createDirectory(at: appURL, withIntermediateDirectories: true)
                try fm.createDirectory(at: dataURL, withIntermediateDirectories: true)
                try self.writeBlankWebsiteFiles(projectID: projectID, name: projectName, now: now, projectURL: appURL)
                try ProjectGitService.shared.initializeRepository(at: appURL)
            } catch {
                try? fm.removeItem(at: projectURL)
                if insertedProjectRecord {
                    try? self.dbPool.write { db in
                        try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [projectID])
                    }
                }
                throw AppProjectStoreError.projectCreationFailed
            }

            return AppProjectRecord(
                id: projectID,
                name: projectName,
                projectURL: projectURL,
                createdAt: now,
                updatedAt: now
            )
        }.value

        return record
    }

    func touchProjectUpdatedAt(projectID: String) {
        let nowNanos = DatabaseTimestamp.toNanos(Date())
        try? dbPool.write { db in
            try db.execute(
                sql: "UPDATE project SET updated_at = ? WHERE id = ?",
                arguments: [nowNanos, projectID]
            )
        }
    }

    func deleteProject(projectURL: URL) throws {
        let rootURL = try ensureProjectsRootDirectory()
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let targetPath = projectURL.standardizedFileURL.path

        guard targetPath.hasPrefix(rootPrefix) else {
            throw AppProjectStoreError.invalidProjectLocation
        }

        let projectID = projectURL.lastPathComponent
        let deletionStagingURL = makeDeletionStagingURL(for: projectID)
        let hasProjectDirectory = fileManager.fileExists(atPath: targetPath)

        do {
            if hasProjectDirectory {
                let stagingParentURL = deletionStagingURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: stagingParentURL, withIntermediateDirectories: true)
                try fileManager.moveItem(at: projectURL, to: deletionStagingURL)
            }

            do {
                try dbPool.write { db in
                    try deleteProjectDatabaseState(projectID: projectID, in: db)
                }
            } catch {
                if hasProjectDirectory,
                   !fileManager.fileExists(atPath: targetPath),
                   fileManager.fileExists(atPath: deletionStagingURL.path) {
                    try? fileManager.moveItem(at: deletionStagingURL, to: projectURL)
                }
                throw error
            }
            if fileManager.fileExists(atPath: deletionStagingURL.path) {
                try? fileManager.removeItem(at: deletionStagingURL)
            }
        } catch {
            throw AppProjectStoreError.projectDeletionFailed
        }
    }

    func loadProjectName(projectURL: URL) -> String {
        let projectID = projectURL.lastPathComponent
        guard let title = try? dbPool.read({ db in
            try String.fetchOne(db, sql: "SELECT title FROM project WHERE id = ?", arguments: [projectID])
        }), !title.isEmpty else {
            return projectID
        }
        return title
    }

    func loadProjectDescription(projectURL: URL) -> String {
        loadProjectMetadata(projectURL: projectURL)?.description ?? ""
    }

    func loadProjectMetadata(projectURL: URL) -> AppProjectMetadataSnapshot? {
        let projectID = projectURL.lastPathComponent
        guard let project = try? dbPool.read({ db in
            try DBProject.fetchOne(db, key: projectID)
        }) else {
            return nil
        }

        return AppProjectMetadataSnapshot(
            id: project.id,
            name: project.title.isEmpty ? project.id : project.title,
            description: project.description,
            createdAt: DatabaseTimestamp.fromNanos(project.createdAt),
            updatedAt: DatabaseTimestamp.fromNanos(project.updatedAt),
            toolPermissionOverride: loadProjectToolPermissionOverride(projectURL: projectURL)
        )
    }

    func updateProjectName(projectURL: URL, name: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AppProjectStoreError.invalidProjectName
        }

        let projectID = projectURL.lastPathComponent
        let nowNanos = DatabaseTimestamp.toNanos(Date())
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE project SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [normalizedName, nowNanos, projectID]
            )
        }
    }

    func updateProjectDescription(projectURL: URL, description: String) throws {
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectID = projectURL.lastPathComponent
        let nowNanos = DatabaseTimestamp.toNanos(Date())
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE project SET description = ?, updated_at = ? WHERE id = ?",
                arguments: [normalizedDescription, nowNanos, projectID]
            )
        }
    }

    // MARK: - App-Level Project Settings

    private static let autoCollapsePanelKey = "appAutoCollapsePanel"

    var isAutoCollapsePanelEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoCollapsePanelKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoCollapsePanelKey) }
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
        let projectID = projectURL.lastPathComponent
        guard let row = try? dbPool.read({ db in
            try DBPermission.filter(DBPermission.Columns.projectID == projectID).fetchOne(db)
        }) else {
            return nil
        }
        return DBPermission.modeEnum(from: row.agentToolPermission)
    }

    /// Returns the effective tool permission mode: project override if set, otherwise app default.
    func loadToolPermissionMode(projectURL: URL) -> ToolPermissionMode {
        loadProjectToolPermissionOverride(projectURL: projectURL) ?? loadAppToolPermissionMode()
    }

    func saveToolPermissionMode(projectURL: URL, mode: ToolPermissionMode?) {
        let projectID = projectURL.lastPathComponent
        let nowNanos = DatabaseTimestamp.toNanos(Date())
        try? dbPool.write { db in
            if let mode {
                let modeInt = DBPermission.modeInt(from: mode)
                try db.execute(
                    sql: """
                        INSERT INTO permission (project_id, agent_tool_permission)
                        VALUES (?, ?)
                        ON CONFLICT(project_id) DO UPDATE SET agent_tool_permission = excluded.agent_tool_permission
                        """,
                    arguments: [projectID, modeInt]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM permission WHERE project_id = ?",
                    arguments: [projectID]
                )
            }
            try db.execute(
                sql: "UPDATE project SET updated_at = ? WHERE id = ?",
                arguments: [nowNanos, projectID]
            )
        }
    }

    private func ensureProjectsRootDirectory() throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw AppProjectStoreError.unavailableDocumentsDirectory
        }

        let projectsRootURL = documentsURL.appendingPathComponent("Projects", isDirectory: true)
        if !fileManager.fileExists(atPath: projectsRootURL.path) {
            try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        }
        return projectsRootURL
    }

    private func normalizeProjectName(_ rawName: String?) -> String {
        let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }

        return String(localized: "project_store.default_project_name", defaultValue: "Untitled")
    }

    nonisolated private static func makeUniqueProjectName(baseName: String, in db: Database) throws -> String {
        let existingTitles = Set(try String.fetchAll(db, sql: "SELECT title FROM project"))
        guard existingTitles.contains(baseName) else {
            return baseName
        }

        var suffix = 2
        while true {
            let candidate = "\(baseName) \(suffix)"
            if !existingTitles.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }

    private func makeDeletionStagingURL(for projectID: String) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("doufu_project_delete", isDirectory: true)
            .appendingPathComponent("\(projectID)-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    private func deleteProjectDatabaseState(projectID: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [projectID])
    }


    private func writeBlankWebsiteFiles(
        projectID: String,
        name: String,
        now: Date,
        projectURL: URL
    ) throws {
        let onboardingHint = String(localized: "project_template.onboarding.hint", defaultValue: "点击菜单，通过对话开发你的应用")

        let indexHTML = """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover" />
            <title>\(name)</title>
            <link rel="stylesheet" href="./style.css" />
          </head>
          <body>
            <main class="screen">
              <p class="onboarding-hint">\(onboardingHint)</p>
              <div class="onboarding-arrow">
                <svg width="64" height="72" viewBox="0 0 64 72" fill="none">
                  <path d="M50 4C46 20 38 38 16 52" stroke="#94a3b8" stroke-width="2.5" stroke-linecap="round" fill="none"/>
                  <path d="M14 43L14 54L25 54" stroke="#94a3b8" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" fill="none"/>
                </svg>
              </div>
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
          -webkit-tap-highlight-color: transparent;
        }

        html, body {
          margin: 0;
          padding: 0;
          height: 100dvh;
          overflow: hidden;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
          -webkit-text-size-adjust: 100%;
          background: #f8fafc;
          color: #0f172a;
        }

        .screen {
          height: 100dvh;
          padding:
            env(safe-area-inset-top)
            env(safe-area-inset-right)
            env(safe-area-inset-bottom)
            env(safe-area-inset-left);
          display: flex;
          flex-direction: column;
          justify-content: flex-end;
          align-items: flex-start;
          overflow: hidden;
        }

        .onboarding-hint {
          margin: 0 0 10px 56px;
          font-size: 15px;
          font-weight: 500;
          color: #94a3b8;
          user-select: none;
          -webkit-touch-callout: none;
        }

        .onboarding-arrow {
          margin: 0 0 90px 36px;
          animation: bounce 2s ease-in-out infinite;
          user-select: none;
          -webkit-touch-callout: none;
        }

        @keyframes bounce {
          0%, 100% { transform: translateY(0); }
          50% { transform: translateY(8px); }
        }
        """

        let scriptJS = """
        (() => {})();
        """

        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let projectAgentsInstructions = """
        # AGENTS.md

        \(isIPad
        ? "This project targets iPad web UX — the app window can be resized at any time (full screen, Split View, Slide Over)."
        : "This project targets iPhone-first web UX.")

        ## Core principle
        - This is a mobile app built with web technologies — embrace what web does well (rich visuals, flexible styling, smooth animations).
        - Do NOT try to imitate native iOS controls (e.g. UIKit/SwiftUI look-alikes). Instead, create polished, modern mobile UI with its own visual identity.

        \(isIPad
        ? """
        ## Responsive layout requirements (MUST)
        - Layouts MUST be responsive — adapt from compact width (~320pt) to full iPad width (~1024pt).
        - Use CSS media queries or container queries to switch between layout modes.
        - At narrow widths (compact): use single-column layout, similar to iPhone.
        - At wider widths (regular): optionally use multi-column layouts (side-by-side panels, master-detail, grid).
        - Respect Safe Area using `env(safe-area-inset-top/right/bottom/left)` (insets vary by window configuration).
        - Ensure touch targets are at least 44px tall.
        - Avoid desktop-only interaction patterns such as hover-dependent controls.
        - Design should feel polished and modern — not like a traditional desktop website.
        """
        : """
        ## Mobile-first requirements (MUST)
        - Treat iPhone portrait as the default viewport; however, landscape rotation may occur.
          Layouts must remain usable in both orientations — do not hard-code portrait-only dimensions.
        - Respect Safe Area using `env(safe-area-inset-top/right/bottom/left)` (insets change between orientations).
        - Keep the primary layout single-column unless explicitly requested.
        - Ensure touch targets are at least 44px tall.
        - Avoid desktop-only interaction patterns such as hover-dependent controls.
        - Design should feel polished and modern — not like a traditional desktop website.
        """)

        ## Zoom & viewport policy (MUST)
        - Disable zoom by default (including pinch and double-tap zoom).
        - Ensure viewport uses:
          `width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover`.
        - Do not create horizontal overflow layouts.

        ## Selection policy (MUST)
        - Non-content UI text must be non-selectable:
          nav bars, tabs, buttons, chips, badges, card titles, tool labels.
          Apply `-webkit-user-select: none; user-select: none; -webkit-touch-callout: none` to these elements.
        - Only content text and form controls (`input`, `textarea`) may allow text selection.
        - Recommended pattern: set `-webkit-user-select: none; user-select: none; -webkit-touch-callout: none` on the app root (`body` or top-level container), then opt-in with `-webkit-user-select: text; user-select: text` on content areas that need selection.
        - Always include the `-webkit-` prefix — it is still required in iOS WKWebView.

        ## Scroll model (MUST)
        - Use exactly one primary scroll container for page content.
        - `html` and `body` must not be scrollable (`overflow: hidden; height: 100dvh`).
        - The main content container should use `overflow-y: auto; overscroll-behavior: contain`.
        - If content fits within the viewport, dragging must not move/stretch the whole page.
        - Any secondary scrollable area must scroll only inside its own bounds (`overscroll-behavior: contain`).
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
        - Use smooth transitions and micro-animations to make interactions feel responsive (150–300ms).

        ## Styling guidance
        - Prioritize readability and generous spacing on small screens.
        - Use modern web design: gradients, subtle shadows, rounded corners, color accents — make the app visually appealing.
        - Keep typography clean and hierarchy clear. The `-apple-system` font stack is fine, but don't restrict yourself to mimicking system UI.

        ## Project directory
        All code files live in the current working directory. All file reads/writes must stay within it.

        ## Doufu Runtime
        Pages are served via a local HTTP server. Standard web APIs are transparently enhanced:
        - `fetch()`: Cross-origin requests are automatically proxied. No CORS issues — just use `fetch('https://...')` normally.
        - `localStorage`: Natively persisted by the host app. Use it for any app data.
        - `IndexedDB`: Natively persisted by the host app. Use it for structured or large-volume data. Supports Blob/File, async `onupgradeneeded` handlers, and large-dataset chunked retrieval. Limitations: no transaction isolation between concurrent readwrite transactions; cursors are snapshot-based and won't reflect writes made during iteration.
        - **Native capabilities**: Standard browser APIs for camera, microphone, geolocation, and clipboard are **blocked**. Use the `doufu.*` JavaScript API instead (e.g. `doufu.camera.start()`, `doufu.mic.start()`, `doufu.location.get()`, `doufu.clipboard.read()`). Call the `doufu_api_docs` tool to see full usage documentation before writing code that uses these features.
        No special SDK or import is needed — write standard JavaScript.

        ## Editing guidance
        - Change the minimum necessary files for each request.
        - Keep the app fully runnable as static `html/css/js`.
        - Preserve `index.html` as entry structure unless requested.
        """

        let projectMemoryDocument = """
        # DOUFU.MD

        ## Project Identity
        - Entry: index.html
        - Created At: \(isoFormatter.string(from: now))

        ## Architecture
        - Runtime: Static web app (html/css/js) served via localhost HTTP server in WKWebView.
        - Directory layout: `App/` (code + git) | `AppData/` (user data) | `preview.jpg`
        - All code lives in `App/`. This file and all editable files are inside `App/`.
        - Default device target: \(isIPad ? "iPad (responsive, compact to full width)." : "iPhone portrait.")
        - Key constraints are defined in AGENTS.md.
        - fetch() is CORS-free (proxied through host app).
        - localStorage and IndexedDB are natively persisted. IndexedDB: no transaction isolation, snapshot cursors.

        ## Core Files
        - index.html: App shell and semantic structure.
        - style.css: Visual system and layout behavior.
        - script.js: Interaction logic and state updates.
        - AGENTS.md: Coding/UX constraints for AI edits.
        - DOUFU.MD: Long-lived project memory and architecture notes.

        ## Product Intent
        - This project should feel like a polished mobile app — not a desktop webpage, and not a crude imitation of native iOS controls.
        - Prefer simple, maintainable structure over heavy frameworks.

        ## Important Notes
        - Keep safe-area support and touch ergonomics as first-class requirements.
        - When introducing new features, update this file with architecture changes.
        """

        let indexURL = projectURL.appendingPathComponent("index.html")
        let styleURL = projectURL.appendingPathComponent("style.css")
        let scriptURL = projectURL.appendingPathComponent("script.js")
        let agentsURL = projectURL.appendingPathComponent("AGENTS.md")
        let doufuURL = projectURL.appendingPathComponent("DOUFU.MD")

        try indexHTML.write(to: indexURL, atomically: true, encoding: .utf8)
        try styleCSS.write(to: styleURL, atomically: true, encoding: .utf8)
        try scriptJS.write(to: scriptURL, atomically: true, encoding: .utf8)
        try projectAgentsInstructions.write(to: agentsURL, atomically: true, encoding: .utf8)
        try projectMemoryDocument.write(to: doufuURL, atomically: true, encoding: .utf8)
    }
}
