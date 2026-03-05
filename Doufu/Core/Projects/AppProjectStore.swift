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

enum AppProjectSnapshotKind: String, Codable, CaseIterable {
    case manual
    case auto

    var displayName: String {
        switch self {
        case .manual:
            return "手动快照"
        case .auto:
            return "自动快照"
        }
    }
}

struct AppProjectSnapshotRecord: Equatable, Hashable {
    let id: String
    let kind: AppProjectSnapshotKind
    let createdAt: Date
    let snapshotURL: URL
    let contentURL: URL
}

private struct SnapshotMetadata: Codable {
    let id: String
    let kind: AppProjectSnapshotKind
    let createdAt: Date
}

enum AppProjectStoreError: LocalizedError {
    case unavailableDocumentsDirectory
    case projectCreationFailed
    case invalidProjectLocation
    case projectDeletionFailed
    case invalidProjectName
    case manifestUpdateFailed
    case snapshotCreateFailed
    case snapshotReadFailed
    case snapshotRestoreFailed
    case snapshotNotFound

    var errorDescription: String? {
        switch self {
        case .unavailableDocumentsDirectory:
            return "无法访问本地文档目录。"
        case .projectCreationFailed:
            return "创建项目失败，请稍后重试。"
        case .invalidProjectLocation:
            return "项目路径无效，无法删除。"
        case .projectDeletionFailed:
            return "删除项目失败，请稍后重试。"
        case .invalidProjectName:
            return "项目名称不能为空。"
        case .manifestUpdateFailed:
            return "更新项目设置失败，请稍后重试。"
        case .snapshotCreateFailed:
            return "创建快照失败，请稍后重试。"
        case .snapshotReadFailed:
            return "读取快照失败，请稍后重试。"
        case .snapshotRestoreFailed:
            return "载入快照失败，请稍后重试。"
        case .snapshotNotFound:
            return "快照不存在或已被清理。"
        }
    }
}

final class AppProjectStore {
    static let shared = AppProjectStore()

    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter
    private let snapshotDirectoryName = ".doufu_snapshots"
    private let snapshotMetadataFileName = "snapshot.json"
    private let snapshotContentDirectoryName = "content"
    private let manualSnapshotLimit = 10
    private let autoSnapshotLimit = 10

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

    @discardableResult
    func createSnapshot(projectURL: URL, kind: AppProjectSnapshotKind) throws -> AppProjectSnapshotRecord {
        try validateProjectLocation(projectURL)

        let now = Date()
        let snapshotID = buildSnapshotID(createdAt: now)
        let snapshotURL = snapshotsKindDirectoryURL(projectURL: projectURL, kind: kind).appendingPathComponent(snapshotID, isDirectory: true)
        let contentURL = snapshotURL.appendingPathComponent(snapshotContentDirectoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: contentURL, withIntermediateDirectories: true)
            try copyDirectoryContents(
                from: projectURL,
                to: contentURL,
                skippingSnapshotStorage: true
            )
            let metadata = SnapshotMetadata(id: snapshotID, kind: kind, createdAt: now)
            try writeSnapshotMetadata(metadata, to: snapshotURL)
            try pruneSnapshotsIfNeeded(projectURL: projectURL, kind: kind)
        } catch {
            try? fileManager.removeItem(at: snapshotURL)
            throw AppProjectStoreError.snapshotCreateFailed
        }

        return AppProjectSnapshotRecord(
            id: snapshotID,
            kind: kind,
            createdAt: now,
            snapshotURL: snapshotURL,
            contentURL: contentURL
        )
    }

    func loadSnapshots(projectURL: URL) throws -> [AppProjectSnapshotRecord] {
        try validateProjectLocation(projectURL)

        var records: [AppProjectSnapshotRecord] = []
        for kind in AppProjectSnapshotKind.allCases {
            let kindDirectoryURL = snapshotsKindDirectoryURL(projectURL: projectURL, kind: kind)
            guard fileManager.fileExists(atPath: kindDirectoryURL.path) else {
                continue
            }

            let childURLs = (try? fileManager.contentsOfDirectory(
                at: kindDirectoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for childURL in childURLs {
                let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                guard values?.isDirectory == true else {
                    continue
                }
                if let record = buildSnapshotRecord(snapshotURL: childURL, fallbackKind: kind) {
                    records.append(record)
                }
            }
        }

        return records.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id > rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func restoreSnapshot(projectURL: URL, snapshot: AppProjectSnapshotRecord) throws {
        try validateProjectLocation(projectURL)
        let snapshotsRootURL = snapshotsRootURL(projectURL: projectURL)
        let normalizedSnapshotPath = snapshot.snapshotURL.standardizedFileURL.path
        let normalizedSnapshotsRootPath = snapshotsRootURL.standardizedFileURL.path
        let snapshotsRootPrefix = normalizedSnapshotsRootPath.hasSuffix("/")
            ? normalizedSnapshotsRootPath
            : normalizedSnapshotsRootPath + "/"

        guard normalizedSnapshotPath.hasPrefix(snapshotsRootPrefix) else {
            throw AppProjectStoreError.snapshotNotFound
        }
        guard fileManager.fileExists(atPath: snapshot.contentURL.path) else {
            throw AppProjectStoreError.snapshotNotFound
        }

        do {
            try clearProjectFilesExcludingSnapshotStorage(projectURL: projectURL)
            try copyDirectoryContents(
                from: snapshot.contentURL,
                to: projectURL,
                skippingSnapshotStorage: false
            )
            touchProjectUpdatedAt(projectURL: projectURL)
        } catch {
            throw AppProjectStoreError.snapshotRestoreFailed
        }
    }

    private func validateProjectLocation(_ projectURL: URL) throws {
        let rootURL = try ensureProjectsRootDirectory()
        let rootPath = rootURL.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let targetPath = projectURL.standardizedFileURL.path

        guard targetPath.hasPrefix(rootPrefix) else {
            throw AppProjectStoreError.invalidProjectLocation
        }
    }

    private func snapshotsRootURL(projectURL: URL) -> URL {
        projectURL.appendingPathComponent(snapshotDirectoryName, isDirectory: true)
    }

    private func snapshotsKindDirectoryURL(projectURL: URL, kind: AppProjectSnapshotKind) -> URL {
        snapshotsRootURL(projectURL: projectURL).appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    private func buildSnapshotID(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = formatter.string(from: createdAt)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return "snapshot-\(prefix)-\(suffix)"
    }

    private func writeSnapshotMetadata(_ metadata: SnapshotMetadata, to snapshotURL: URL) throws {
        let metadataURL = snapshotURL.appendingPathComponent(snapshotMetadataFileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func readSnapshotMetadata(from snapshotURL: URL) -> SnapshotMetadata? {
        let metadataURL = snapshotURL.appendingPathComponent(snapshotMetadataFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SnapshotMetadata.self, from: data)
    }

    private func buildSnapshotRecord(snapshotURL: URL, fallbackKind: AppProjectSnapshotKind) -> AppProjectSnapshotRecord? {
        let contentURL = snapshotURL.appendingPathComponent(snapshotContentDirectoryName, isDirectory: true)
        guard fileManager.fileExists(atPath: contentURL.path) else {
            return nil
        }

        if let metadata = readSnapshotMetadata(from: snapshotURL) {
            return AppProjectSnapshotRecord(
                id: metadata.id,
                kind: metadata.kind,
                createdAt: metadata.createdAt,
                snapshotURL: snapshotURL,
                contentURL: contentURL
            )
        }

        let resourceValues = try? snapshotURL.resourceValues(forKeys: [.contentModificationDateKey])
        let fallbackDate = resourceValues?.contentModificationDate ?? Date.distantPast
        return AppProjectSnapshotRecord(
            id: snapshotURL.lastPathComponent,
            kind: fallbackKind,
            createdAt: fallbackDate,
            snapshotURL: snapshotURL,
            contentURL: contentURL
        )
    }

    private func pruneSnapshotsIfNeeded(projectURL: URL, kind: AppProjectSnapshotKind) throws {
        let limit = kind == .manual ? manualSnapshotLimit : autoSnapshotLimit
        let snapshots = try loadSnapshots(projectURL: projectURL)
            .filter { $0.kind == kind }

        guard snapshots.count > limit else {
            return
        }

        let overflow = snapshots.count - limit
        let recordsToDelete = Array(snapshots.suffix(overflow))
        for record in recordsToDelete {
            try? fileManager.removeItem(at: record.snapshotURL)
        }
    }

    private func clearProjectFilesExcludingSnapshotStorage(projectURL: URL) throws {
        let childURLs = try fileManager.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for childURL in childURLs {
            if childURL.lastPathComponent == snapshotDirectoryName {
                continue
            }
            try fileManager.removeItem(at: childURL)
        }
    }

    private func copyDirectoryContents(
        from sourceRootURL: URL,
        to destinationRootURL: URL,
        skippingSnapshotStorage: Bool
    ) throws {
        guard let enumerator = fileManager.enumerator(
            at: sourceRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw AppProjectStoreError.snapshotCreateFailed
        }

        for case let sourceURL as URL in enumerator {
            let resourceValues = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey])
            let relativePath = relativePath(of: sourceURL, rootURL: sourceRootURL)

            if skippingSnapshotStorage {
                if relativePath == snapshotDirectoryName || relativePath.hasPrefix(snapshotDirectoryName + "/") {
                    if resourceValues?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }

            let destinationURL = destinationRootURL.appendingPathComponent(relativePath, isDirectory: resourceValues?.isDirectory == true)
            if resourceValues?.isDirectory == true {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            let parentURL = destinationURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    private func relativePath(of url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if urlPath.hasPrefix(prefix) {
            let index = urlPath.index(urlPath.startIndex, offsetBy: prefix.count)
            return String(urlPath[index...])
        }
        return url.lastPathComponent
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
        return "新项目 \(formatter.string(from: createdAt))"
    }

    private func writeBlankWebsiteFiles(
        projectID: String,
        name: String,
        now: Date,
        projectURL: URL
    ) throws {
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
                <p class="tag">Blank Project</p>
                <h1>\(name)</h1>
                <p class="hint">这是一个空白页面。</p>
                <p class="hint">点击右上角「聊天」，告诉 Codex 你想要的效果。</p>
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

        let manifestObject: [String: Any] = [
            "projectId": projectID,
            "name": name,
            "source": "local",
            "prompt": "空白网页项目",
            "description": "通过聊天持续更新代码。",
            "createdAt": isoFormatter.string(from: now),
            "updatedAt": isoFormatter.string(from: now),
            "entryFilePath": "index.html"
        ]

        let indexURL = projectURL.appendingPathComponent("index.html")
        let styleURL = projectURL.appendingPathComponent("style.css")
        let scriptURL = projectURL.appendingPathComponent("script.js")
        let manifestURL = projectURL.appendingPathComponent("manifest.json")
        let agentsURL = projectURL.appendingPathComponent("AGENTS.md")

        try indexHTML.write(to: indexURL, atomically: true, encoding: .utf8)
        try styleCSS.write(to: styleURL, atomically: true, encoding: .utf8)
        try scriptJS.write(to: scriptURL, atomically: true, encoding: .utf8)
        try projectAgentsInstructions.write(to: agentsURL, atomically: true, encoding: .utf8)
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)
    }
}
