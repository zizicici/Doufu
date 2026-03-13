import Foundation

/// Exports `.doufu` / `.doufull` project archives.
///
/// Archive semantics:
/// - `.doufu`: ZIP containing `App/`
/// - `.doufull`: ZIP containing `App/` + `AppData/`
final class ProjectArchiveExportService {

    static let shared = ProjectArchiveExportService()

    enum ArchiveKind {
        case doufu
        case doufull

        var fileExtension: String {
            switch self {
            case .doufu: return "doufu"
            case .doufull: return "doufull"
            }
        }

        var fileSuffix: String {
            switch self {
            case .doufu: return "code"
            case .doufull: return "project-backup"
            }
        }
    }

    struct ExportResult {
        let archiveURL: URL
        let cleanupURLs: [URL]
    }

    enum ExportError: LocalizedError {
        case missingProjectRoot
        case missingAppDirectory
        case invalidAppDataPath

        var errorDescription: String? {
            switch self {
            case .missingProjectRoot:
                return String(
                    localized: "file_browser.export.error.missing_project_root",
                    defaultValue: "This project backup is only available from a project workspace."
                )
            case .missingAppDirectory:
                return String(
                    localized: "file_browser.export.error.missing_app_directory",
                    defaultValue: "App folder is missing and cannot be exported."
                )
            case .invalidAppDataPath:
                return String(
                    localized: "file_browser.export.error.invalid_app_data_directory",
                    defaultValue: "AppData exists but is not a directory."
                )
            }
        }
    }

    private init() {}

    func exportArchive(
        kind: ArchiveKind,
        projectName: String,
        appURL: URL,
        projectRootURL: URL?
    ) throws -> ExportResult {
        switch kind {
        case .doufu:
            return try exportCodeArchive(projectName: projectName, appURL: appURL)
        case .doufull:
            guard let projectRootURL else {
                throw ExportError.missingProjectRoot
            }
            return try exportFullArchive(projectName: projectName, projectRootURL: projectRootURL)
        }
    }

    private func exportCodeArchive(projectName: String, appURL: URL) throws -> ExportResult {
        let fileManager = FileManager.default
        try ensureDirectoryExists(at: appURL, fileManager: fileManager, missingError: .missingAppDirectory)

        let archiveURL = makeArchiveURL(
            projectName: projectName,
            suffix: ArchiveKind.doufu.fileSuffix,
            fileExtension: ArchiveKind.doufu.fileExtension,
            fileManager: fileManager
        )
        try? fileManager.removeItem(at: archiveURL)
        try zipDirectory(at: appURL, to: archiveURL)
        return ExportResult(archiveURL: archiveURL, cleanupURLs: [archiveURL])
    }

    private func exportFullArchive(projectName: String, projectRootURL: URL) throws -> ExportResult {
        let fileManager = FileManager.default
        let appSourceURL = projectRootURL.appendingPathComponent("App", isDirectory: true)
        let appDataSourceURL = projectRootURL.appendingPathComponent("AppData", isDirectory: true)

        try ensureDirectoryExists(at: appSourceURL, fileManager: fileManager, missingError: .missingAppDirectory)

        let stagingRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("doufu_project_export_\(UUID().uuidString.lowercased())", isDirectory: true)
        let exportFolderURL = stagingRootURL
            .appendingPathComponent("\(safeArchiveBaseName(from: projectName))-project-backup", isDirectory: true)
        let exportAppURL = exportFolderURL.appendingPathComponent("App", isDirectory: true)
        let exportAppDataURL = exportFolderURL.appendingPathComponent("AppData", isDirectory: true)

        try fileManager.createDirectory(at: exportFolderURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: appSourceURL, to: exportAppURL)

        var isAppDataDir: ObjCBool = false
        if fileManager.fileExists(atPath: appDataSourceURL.path, isDirectory: &isAppDataDir) {
            guard isAppDataDir.boolValue else {
                throw ExportError.invalidAppDataPath
            }
            try fileManager.copyItem(at: appDataSourceURL, to: exportAppDataURL)
        } else {
            // `.doufull` must always contain `AppData/` so that it can round-trip.
            try fileManager.createDirectory(at: exportAppDataURL, withIntermediateDirectories: true)
        }

        let archiveURL = makeArchiveURL(
            projectName: projectName,
            suffix: ArchiveKind.doufull.fileSuffix,
            fileExtension: ArchiveKind.doufull.fileExtension,
            fileManager: fileManager
        )
        try? fileManager.removeItem(at: archiveURL)
        try zipDirectory(at: exportFolderURL, to: archiveURL)

        return ExportResult(
            archiveURL: archiveURL,
            cleanupURLs: [archiveURL, stagingRootURL]
        )
    }

    private func ensureDirectoryExists(
        at directoryURL: URL,
        fileManager: FileManager,
        missingError: ExportError
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw missingError
        }
    }

    private func makeArchiveURL(
        projectName: String,
        suffix: String,
        fileExtension: String,
        fileManager: FileManager
    ) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("\(safeArchiveBaseName(from: projectName))-\(suffix).\(fileExtension)")
    }

    private func safeArchiveBaseName(from projectName: String) -> String {
        let rawBaseName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = rawBaseName.isEmpty ? "project" : rawBaseName
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let sanitized = fallback
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sanitized.isEmpty ? "project" : sanitized
    }

    private func zipDirectory(at sourceURL: URL, to destinationURL: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var zipError: Error?

        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: [.forUploading],
            error: &coordinatorError
        ) { tempURL in
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            } catch {
                zipError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let zipError {
            throw zipError
        }
    }
}
