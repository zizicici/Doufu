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

        ## Mobile-first requirements
        - Treat iPhone portrait as the default viewport.
        - Respect Safe Area using `env(safe-area-inset-top/right/bottom/left)`.
        - Keep the primary layout single-column unless explicitly requested.
        - Ensure touch targets are at least 44px tall.
        - Avoid desktop-only interaction patterns such as hover-dependent controls.
        - Avoid strong "desktop web" visual style; prefer a clean, native-like iOS feel.

        ## Styling guidance
        - Prioritize readability and spacing on small screens.
        - Keep motion subtle and meaningful.
        - Prefer system-like typography and restrained visual decoration.

        ## Editing guidance
        - Change the minimum necessary files for each request.
        - Keep the app fully runnable as static html/css/js.
        - Preserve `manifest.json` and `index.html` as the project entry structure unless requested.
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
