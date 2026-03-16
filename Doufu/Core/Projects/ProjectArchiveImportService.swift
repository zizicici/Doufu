import Foundation
import zlib

/// Imports `.doufu` / `.doufull` project archives.
///
/// Archive semantics:
/// - `.doufu`: ZIP containing `App/`
/// - `.doufull`: ZIP containing `App/` + `AppData/`
nonisolated final class ProjectArchiveImportService {

    static let shared = ProjectArchiveImportService()

    enum ArchiveKind: String {
        case doufu
        case doufull

        var requiresAppData: Bool {
            switch self {
            case .doufu: return false
            case .doufull: return true
            }
        }
    }

    struct ImportResult {
        let project: AppProjectRecord
        let kind: ArchiveKind
    }

    /// Result of extracting an archive for preview/scanning before actual import.
    struct PreviewResult: Sendable {
        let archiveName: String
        let archiveSize: Int64
        let kind: ArchiveKind
        let payloadRoot: URL
        let appURL: URL
        let fileCount: Int
        let hasAppData: Bool
        let workingRoot: URL
        let sourceURL: URL
    }

    enum ImportError: LocalizedError {
        case unsupportedExtension(String)
        case accessDenied
        case copyFailed
        case invalidZip(String)
        case invalidStructure
        case unsupportedZipFeature(String)
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unsupportedExtension(ext):
                return String(
                    format: String(localized: "import.error.unsupported_extension", defaultValue: "Unsupported file extension: .%@."),
                    ext
                )
            case .accessDenied:
                return String(localized: "import.error.access_denied", defaultValue: "Cannot access the selected file.")
            case .copyFailed:
                return String(localized: "import.error.copy_failed", defaultValue: "Failed to read the selected archive.")
            case let .invalidZip(reason):
                return String(
                    format: String(localized: "import.error.invalid_zip", defaultValue: "Invalid archive: %@"),
                    reason
                )
            case .invalidStructure:
                return String(localized: "import.error.invalid_structure", defaultValue: "Archive structure is invalid.")
            case let .unsupportedZipFeature(feature):
                return String(
                    format: String(localized: "import.error.unsupported_zip_feature", defaultValue: "Unsupported ZIP feature: %@"),
                    feature
                )
            case let .installationFailed(message):
                return message
            }
        }
    }

    private enum Limits {
        static let maxArchiveBytes: UInt64 = 256 * 1024 * 1024
        static let maxCentralDirectoryBytes: UInt64 = 16 * 1024 * 1024
        static let maxEntryCount: Int = 8_000
        static let maxEntryCompressedBytes: UInt64 = 64 * 1024 * 1024
        static let maxEntryUncompressedBytes: UInt64 = 128 * 1024 * 1024
        static let maxTotalUncompressedBytes: UInt64 = 512 * 1024 * 1024
    }

    private init() {}

    // MARK: - Two-Phase Import (Extract → Preview/Scan → Confirm)

    /// Phase 1: Extract archive to a temporary directory for preview and scanning.
    /// The caller is responsible for calling `cleanupPreview(_:)` when done.
    func extractForPreview(from sourceURL: URL) async throws -> PreviewResult {
        try Task.checkCancellation()

        let ext = sourceURL.pathExtension.lowercased()
        guard let kind = ArchiveKind(rawValue: ext) else {
            throw ImportError.unsupportedExtension(ext)
        }

        let fileManager = FileManager.default

        // Get archive size
        let archiveSize: Int64 = {
            let attrs = try? fileManager.attributesOfItem(atPath: sourceURL.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }()

        let workingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("doufu_archive_preview_\(UUID().uuidString.lowercased())", isDirectory: true)
        let localArchiveURL = workingRoot.appendingPathComponent("archive.\(kind.rawValue)")
        let extractionRoot = workingRoot.appendingPathComponent("extracted", isDirectory: true)

        try fileManager.createDirectory(at: extractionRoot, withIntermediateDirectories: true)

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try await Self.runDetachedCancellable(priority: .userInitiated) {
                try Self.copyCoordinatedFile(from: sourceURL, to: localArchiveURL)
            }
        } catch is CancellationError {
            try? fileManager.removeItem(at: workingRoot)
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: workingRoot)
            throw Self.mapCopyError(error)
        }

        do { try Task.checkCancellation() } catch {
            try? fileManager.removeItem(at: workingRoot)
            throw error
        }

        do {
            try await Self.runDetachedCancellable(priority: .userInitiated) {
                try ZIPArchiveExtractor.extract(
                    archiveURL: localArchiveURL,
                    to: extractionRoot,
                    limits: .init(
                        maxArchiveBytes: Limits.maxArchiveBytes,
                        maxCentralDirectoryBytes: Limits.maxCentralDirectoryBytes,
                        maxEntryCount: Limits.maxEntryCount,
                        maxEntryCompressedBytes: Limits.maxEntryCompressedBytes,
                        maxEntryUncompressedBytes: Limits.maxEntryUncompressedBytes,
                        maxTotalUncompressedBytes: Limits.maxTotalUncompressedBytes
                    )
                )
            }
        } catch is CancellationError {
            try? fileManager.removeItem(at: workingRoot)
            throw CancellationError()
        } catch let error as ImportError {
            try? fileManager.removeItem(at: workingRoot)
            throw error
        } catch {
            try? fileManager.removeItem(at: workingRoot)
            throw ImportError.invalidZip(error.localizedDescription)
        }

        do { try Task.checkCancellation() } catch {
            try? fileManager.removeItem(at: workingRoot)
            throw error
        }

        let payloadRoot: URL
        do {
            payloadRoot = try Self.resolvePayloadRoot(in: extractionRoot, kind: kind)
        } catch {
            try? fileManager.removeItem(at: workingRoot)
            throw (error as? ImportError) ?? ImportError.invalidStructure
        }

        let appURL = payloadRoot.appendingPathComponent("App", isDirectory: true)

        // Count files (include hidden files; skip .git/)
        let fileCount: Int = {
            guard let enumerator = fileManager.enumerator(
                at: appURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { return 0 }
            var count = 0
            for case let url as URL in enumerator {
                let rel = url.path.replacingOccurrences(of: appURL.path + "/", with: "")
                if rel.hasPrefix(".git/") { continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    count += 1
                }
            }
            return count
        }()

        let appDataURL = payloadRoot.appendingPathComponent("AppData", isDirectory: true)
        let hasAppData: Bool = {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: appDataURL.path, isDirectory: &isDir) && isDir.boolValue
        }()

        return PreviewResult(
            archiveName: sourceURL.deletingPathExtension().lastPathComponent,
            archiveSize: archiveSize,
            kind: kind,
            payloadRoot: payloadRoot,
            appURL: appURL,
            fileCount: fileCount,
            hasAppData: hasAppData,
            workingRoot: workingRoot,
            sourceURL: sourceURL
        )
    }

    /// Phase 2: Confirm import — create project and install the previously extracted payload.
    func completeImport(preview: PreviewResult) async throws -> ImportResult {
        try Task.checkCancellation()

        let suggestedName = Self.suggestedProjectName(from: preview.sourceURL)
        var createdProject: AppProjectRecord?

        do {
            let project = try await ProjectLifecycleCoordinator.shared.createProject(name: suggestedName)
            createdProject = project

            try Task.checkCancellation()

            let requiresAppData = preview.kind.requiresAppData
            let projectID = project.id
            let projectURL = project.projectURL
            let appDestinationURL = projectURL.appendingPathComponent("App", isDirectory: true)
            let appDataDestinationURL = projectURL.appendingPathComponent("AppData", isDirectory: true)
            try await Self.runDetachedCancellable(priority: .userInitiated) {
                try Self.installPayload(
                    payloadRoot: preview.payloadRoot,
                    requiresAppData: requiresAppData,
                    appDestinationURL: appDestinationURL,
                    appDataDestinationURL: appDataDestinationURL
                )
            }

            try Task.checkCancellation()

            try ProjectGitService.shared.ensureRepository(at: appDestinationURL)
            _ = try? ProjectGitService.shared.createCheckpoint(
                repositoryURL: appDestinationURL,
                userMessage: Self.checkpointMessage(for: preview.kind, sourceURL: preview.sourceURL)
            )
            await MainActor.run {
                ProjectChangeCenter.shared.notifyFilesChanged(projectID: projectID)
            }
            return ImportResult(project: project, kind: preview.kind)
        } catch is CancellationError {
            if let createdProject {
                try? await ProjectLifecycleCoordinator.shared.deleteProject(
                    projectID: createdProject.id,
                    projectURL: createdProject.projectURL
                )
            }
            throw CancellationError()
        } catch {
            if let createdProject {
                try? await ProjectLifecycleCoordinator.shared.deleteProject(
                    projectID: createdProject.id,
                    projectURL: createdProject.projectURL
                )
            }
            throw (error as? ImportError) ?? ImportError.installationFailed(error.localizedDescription)
        }
    }

    /// Clean up the temporary directory created by `extractForPreview`.
    func cleanupPreview(_ preview: PreviewResult) {
        try? FileManager.default.removeItem(at: preview.workingRoot)
    }

    private static func runDetachedCancellable<T: Sendable>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: priority) {
            try operation()
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func mapCopyError(_ error: Error) -> ImportError {
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return .accessDenied
        }

        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == EACCES {
            return .accessDenied
        }

        return .copyFailed
    }

    private static func copyCoordinatedFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destinationURL)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var copyError: Error?

        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        if let copyError {
            throw copyError
        }
    }

    private static func suggestedProjectName(from sourceURL: URL) -> String? {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return baseName.isEmpty ? nil : baseName
    }

    private static func checkpointMessage(for kind: ArchiveKind, sourceURL: URL) -> String {
        let fileName = sourceURL.lastPathComponent
        switch kind {
        case .doufu:
            return "Import .doufu archive \(fileName)"
        case .doufull:
            return "Import .doufull archive \(fileName)"
        }
    }

    private static func resolvePayloadRoot(in extractionRoot: URL, kind: ArchiveKind) throws -> URL {
        let fileManager = FileManager.default

        if isValidPayloadRoot(extractionRoot, kind: kind) {
            return extractionRoot
        }

        let firstLevel = try fileManager.contentsOfDirectory(
            at: extractionRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let dirCandidates = firstLevel.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if dirCandidates.count == 1,
           isValidPayloadRoot(dirCandidates[0], kind: kind) {
            return dirCandidates[0]
        }

        let matches = dirCandidates.filter { isValidPayloadRoot($0, kind: kind) }
        if matches.count == 1 {
            return matches[0]
        }

        throw ImportError.invalidStructure
    }

    private static func isValidPayloadRoot(_ root: URL, kind: ArchiveKind) -> Bool {
        let fileManager = FileManager.default
        let appURL = root.appendingPathComponent("App", isDirectory: true)

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        if kind.requiresAppData {
            let appDataURL = root.appendingPathComponent("AppData", isDirectory: true)
            var isAppDataDir: ObjCBool = false
            return fileManager.fileExists(atPath: appDataURL.path, isDirectory: &isAppDataDir)
                && isAppDataDir.boolValue
        }

        return true
    }

    private static func installPayload(
        payloadRoot: URL,
        requiresAppData: Bool,
        appDestinationURL: URL,
        appDataDestinationURL: URL
    ) throws {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let appSourceURL = payloadRoot.appendingPathComponent("App", isDirectory: true)
        let appDataSourceURL = payloadRoot.appendingPathComponent("AppData", isDirectory: true)

        try replaceDirectory(at: appDestinationURL, with: appSourceURL, fileManager: fileManager)

        if requiresAppData {
            try Task.checkCancellation()
            try replaceDirectory(at: appDataDestinationURL, with: appDataSourceURL, fileManager: fileManager)
        }
    }

    private static func replaceDirectory(at destinationURL: URL, with sourceURL: URL, fileManager: FileManager) throws {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.invalidStructure
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }
}

// MARK: - ZIP Extractor (streaming with limits + CRC)

private nonisolated enum ZIPArchiveExtractor {

    struct Limits {
        let maxArchiveBytes: UInt64
        let maxCentralDirectoryBytes: UInt64
        let maxEntryCount: Int
        let maxEntryCompressedBytes: UInt64
        let maxEntryUncompressedBytes: UInt64
        let maxTotalUncompressedBytes: UInt64
    }

    private struct EndOfCentralDirectory {
        let diskNumber: UInt16
        let centralDirectoryDisk: UInt16
        let entriesOnDisk: UInt16
        let totalEntries: UInt16
        let centralDirectorySize: UInt32
        let centralDirectoryOffset: UInt32
    }

    private struct Entry {
        let path: String
        let localHeaderOffset: UInt64
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let flags: UInt16
        let crc32: UInt32
        let externalAttributes: UInt32
        let isDirectory: Bool
    }

    private static let localFileHeaderSignature: UInt32 = 0x04034b50
    private static let centralDirectoryHeaderSignature: UInt32 = 0x02014b50
    private static let endOfCentralDirectorySignature: UInt32 = 0x06054b50

    static func extract(archiveURL: URL, to destinationRoot: URL, limits: Limits) throws {
        let fileManager = FileManager.default

        let fileSize = try archiveSize(of: archiveURL, fileManager: fileManager)
        guard fileSize > 0 else {
            throw ProjectArchiveImportService.ImportError.invalidZip("empty archive")
        }
        guard fileSize <= limits.maxArchiveBytes else {
            throw ProjectArchiveImportService.ImportError.invalidZip("archive exceeds size limit")
        }

        let archiveHandle = try FileHandle(forReadingFrom: archiveURL)
        defer {
            try? archiveHandle.close()
        }

        let eocd = try locateEndOfCentralDirectory(
            using: archiveHandle,
            fileSize: fileSize
        )

        guard eocd.diskNumber == 0,
              eocd.centralDirectoryDisk == 0,
              eocd.entriesOnDisk == eocd.totalEntries else {
            throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("multi-disk archive")
        }

        if eocd.centralDirectoryOffset == UInt32.max || eocd.centralDirectorySize == UInt32.max {
            throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("ZIP64 archive")
        }

        guard Int(eocd.totalEntries) <= limits.maxEntryCount else {
            throw ProjectArchiveImportService.ImportError.invalidZip("too many entries")
        }

        let centralDirectoryOffset = UInt64(eocd.centralDirectoryOffset)
        let centralDirectorySize = UInt64(eocd.centralDirectorySize)
        guard centralDirectorySize <= limits.maxCentralDirectoryBytes else {
            throw ProjectArchiveImportService.ImportError.invalidZip("central directory exceeds size limit")
        }
        guard centralDirectoryOffset + centralDirectorySize <= fileSize else {
            throw ProjectArchiveImportService.ImportError.invalidZip("central directory out of bounds")
        }

        let centralDirectoryData = try readData(
            from: archiveHandle,
            offset: centralDirectoryOffset,
            count: Int(centralDirectorySize)
        )

        let entries = try parseCentralDirectory(
            from: centralDirectoryData,
            expectedCount: Int(eocd.totalEntries),
            limits: limits
        )

        let rootResolved = destinationRoot.standardizedFileURL.resolvingSymlinksInPath()

        for entry in entries {
            try Task.checkCancellation()
            try validatePath(entry.path)

            let destinationURL = rootResolved
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard isSubpath(destinationURL, of: rootResolved) else {
                throw ProjectArchiveImportService.ImportError.invalidZip("Path escapes extraction root: \(entry.path)")
            }

            if isSymlink(entry.externalAttributes) {
                throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("symlink entry: \(entry.path)")
            }

            if entry.isDirectory {
                try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            do {
                try extractFileEntry(
                    entry,
                    from: archiveHandle,
                    archiveSize: fileSize,
                    to: destinationURL,
                    fileManager: fileManager
                )
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    private static func archiveSize(of archiveURL: URL, fileManager: FileManager) throws -> UInt64 {
        let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
        guard let sizeNumber = attributes[.size] as? NSNumber else {
            throw ProjectArchiveImportService.ImportError.invalidZip("cannot read archive size")
        }
        return sizeNumber.uint64Value
    }

    private static func locateEndOfCentralDirectory(using handle: FileHandle, fileSize: UInt64) throws -> EndOfCentralDirectory {
        let minimumEOCDSize = 22
        let maxCommentLength = 65_535
        let maxSearchWindow = minimumEOCDSize + maxCommentLength

        guard fileSize >= UInt64(minimumEOCDSize) else {
            throw ProjectArchiveImportService.ImportError.invalidZip("missing end of central directory")
        }

        let searchWindow = Int(min(fileSize, UInt64(maxSearchWindow)))
        let searchStart = fileSize - UInt64(searchWindow)
        let tailData = try readData(from: handle, offset: searchStart, count: searchWindow)

        var offset = tailData.count - minimumEOCDSize
        while offset >= 0 {
            if (try? tailData.uint32LE(at: offset)) == endOfCentralDirectorySignature {
                return try EndOfCentralDirectory(
                    diskNumber: tailData.uint16LE(at: offset + 4),
                    centralDirectoryDisk: tailData.uint16LE(at: offset + 6),
                    entriesOnDisk: tailData.uint16LE(at: offset + 8),
                    totalEntries: tailData.uint16LE(at: offset + 10),
                    centralDirectorySize: tailData.uint32LE(at: offset + 12),
                    centralDirectoryOffset: tailData.uint32LE(at: offset + 16)
                )
            }
            offset -= 1
        }

        throw ProjectArchiveImportService.ImportError.invalidZip("missing end of central directory")
    }

    private static func parseCentralDirectory(
        from data: Data,
        expectedCount: Int,
        limits: Limits
    ) throws -> [Entry] {
        if expectedCount == 0 {
            return []
        }

        var entries: [Entry] = []
        entries.reserveCapacity(expectedCount)

        var totalUncompressed: UInt64 = 0
        var seenPaths = Set<String>()
        var cursor = 0

        while cursor < data.count, entries.count < expectedCount {
            let signature = try data.uint32LE(at: cursor)
            guard signature == centralDirectoryHeaderSignature else {
                throw ProjectArchiveImportService.ImportError.invalidZip("invalid central directory header")
            }

            let flags = try data.uint16LE(at: cursor + 8)
            let compressionMethod = try data.uint16LE(at: cursor + 10)
            let crc32Value = try data.uint32LE(at: cursor + 16)
            let compressedSizeRaw = try data.uint32LE(at: cursor + 20)
            let uncompressedSizeRaw = try data.uint32LE(at: cursor + 24)
            let fileNameLength = Int(try data.uint16LE(at: cursor + 28))
            let extraLength = Int(try data.uint16LE(at: cursor + 30))
            let commentLength = Int(try data.uint16LE(at: cursor + 32))
            let diskStart = try data.uint16LE(at: cursor + 34)
            let externalAttributes = try data.uint32LE(at: cursor + 38)
            let localHeaderOffsetRaw = try data.uint32LE(at: cursor + 42)

            if compressedSizeRaw == UInt32.max || uncompressedSizeRaw == UInt32.max || localHeaderOffsetRaw == UInt32.max {
                throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("ZIP64 entry")
            }

            if diskStart != 0 {
                throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("multi-disk entry")
            }

            if (flags & 0x0001) != 0 {
                throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("encrypted entry")
            }

            if compressionMethod != 0 && compressionMethod != 8 {
                throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("compression method \(compressionMethod)")
            }

            let compressedSize = UInt64(compressedSizeRaw)
            let uncompressedSize = UInt64(uncompressedSizeRaw)
            let localHeaderOffset = UInt64(localHeaderOffsetRaw)

            if compressedSize > limits.maxEntryCompressedBytes {
                throw ProjectArchiveImportService.ImportError.invalidZip("entry exceeds compressed size limit")
            }
            if uncompressedSize > limits.maxEntryUncompressedBytes {
                throw ProjectArchiveImportService.ImportError.invalidZip("entry exceeds uncompressed size limit")
            }

            let fileNameStart = cursor + 46
            let fileNameEnd = fileNameStart + fileNameLength
            guard fileNameEnd <= data.count else {
                throw ProjectArchiveImportService.ImportError.invalidZip("file name out of bounds")
            }

            let pathData = data.subdata(in: fileNameStart..<fileNameEnd)
            let decodedPath = decodePath(from: pathData, flags: flags)
            let isDirectory = decodedPath.hasSuffix("/")
            let normalizedPath = isDirectory ? String(decodedPath.dropLast()) : decodedPath
            if seenPaths.contains(normalizedPath) {
                throw ProjectArchiveImportService.ImportError.invalidZip("duplicate entry path: \(normalizedPath)")
            }
            seenPaths.insert(normalizedPath)

            let nextCursor = fileNameEnd + extraLength + commentLength
            guard nextCursor <= data.count else {
                throw ProjectArchiveImportService.ImportError.invalidZip("entry metadata out of bounds")
            }
            cursor = nextCursor

            entries.append(Entry(
                path: normalizedPath,
                localHeaderOffset: localHeaderOffset,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                flags: flags,
                crc32: crc32Value,
                externalAttributes: externalAttributes,
                isDirectory: isDirectory
            ))

            if !isDirectory {
                if UInt64.max - totalUncompressed < uncompressedSize {
                    throw ProjectArchiveImportService.ImportError.invalidZip("total size overflow")
                }
                totalUncompressed += uncompressedSize
                if totalUncompressed > limits.maxTotalUncompressedBytes {
                    throw ProjectArchiveImportService.ImportError.invalidZip("archive exceeds uncompressed size limit")
                }
            }
        }

        guard entries.count == expectedCount else {
            throw ProjectArchiveImportService.ImportError.invalidZip("central directory entry count mismatch")
        }

        return entries
    }

    private static func extractFileEntry(
        _ entry: Entry,
        from archiveHandle: FileHandle,
        archiveSize: UInt64,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        guard entry.path.isEmpty == false else {
            throw ProjectArchiveImportService.ImportError.invalidZip("empty file path")
        }

        let localOffset = entry.localHeaderOffset
        let localHeader = try readData(from: archiveHandle, offset: localOffset, count: 30)

        guard try localHeader.uint32LE(at: 0) == localFileHeaderSignature else {
            throw ProjectArchiveImportService.ImportError.invalidZip("invalid local header signature")
        }

        let localFileNameLength = UInt64(try localHeader.uint16LE(at: 26))
        let localExtraLength = UInt64(try localHeader.uint16LE(at: 28))
        let dataOffset = localOffset + 30 + localFileNameLength + localExtraLength

        guard dataOffset + entry.compressedSize <= archiveSize else {
            throw ProjectArchiveImportService.ImportError.invalidZip("entry data range out of bounds")
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw ProjectArchiveImportService.ImportError.invalidZip("cannot create extracted file")
        }

        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? outputHandle.close()
        }

        let extractionResult: (written: UInt64, crc32: UInt32)
        switch entry.compressionMethod {
        case 0:
            extractionResult = try copyStoredEntry(
                from: archiveHandle,
                offset: dataOffset,
                compressedSize: entry.compressedSize,
                outputHandle: outputHandle
            )
        case 8:
            extractionResult = try inflateDeflateEntry(
                from: archiveHandle,
                offset: dataOffset,
                compressedSize: entry.compressedSize,
                outputHandle: outputHandle
            )
        default:
            throw ProjectArchiveImportService.ImportError.unsupportedZipFeature("compression method \(entry.compressionMethod)")
        }

        if extractionResult.written != entry.uncompressedSize {
            throw ProjectArchiveImportService.ImportError.invalidZip("uncompressed size mismatch for \(entry.path)")
        }
        if extractionResult.crc32 != entry.crc32 {
            throw ProjectArchiveImportService.ImportError.invalidZip("CRC mismatch for \(entry.path)")
        }
    }

    private static func copyStoredEntry(
        from archiveHandle: FileHandle,
        offset: UInt64,
        compressedSize: UInt64,
        outputHandle: FileHandle
    ) throws -> (written: UInt64, crc32: UInt32) {
        let chunkSize: UInt64 = 64 * 1024
        var remaining = compressedSize
        var cursor = offset
        var written: UInt64 = 0
        var crc: UInt32 = 0

        while remaining > 0 {
            try Task.checkCancellation()
            let readSize = Int(min(remaining, chunkSize))
            let chunk = try readData(from: archiveHandle, offset: cursor, count: readSize)
            try outputHandle.write(contentsOf: chunk)

            crc = updateCRC32(crc, with: chunk)
            written += UInt64(chunk.count)
            remaining -= UInt64(chunk.count)
            cursor += UInt64(chunk.count)
        }

        return (written: written, crc32: crc)
    }

    private static func inflateDeflateEntry(
        from archiveHandle: FileHandle,
        offset: UInt64,
        compressedSize: UInt64,
        outputHandle: FileHandle
    ) throws -> (written: UInt64, crc32: UInt32) {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw ProjectArchiveImportService.ImportError.invalidZip("zlib initialization failed (\(initStatus))")
        }
        defer {
            inflateEnd(&stream)
        }

        let inputChunkSize: UInt64 = 64 * 1024
        var outputBuffer = [UInt8](repeating: 0, count: 64 * 1024)

        var remaining = compressedSize
        var cursor = offset
        var written: UInt64 = 0
        var crc: UInt32 = 0
        var reachedStreamEnd = false

        while remaining > 0 {
            try Task.checkCancellation()

            let readSize = Int(min(remaining, inputChunkSize))
            let inputChunk = try readData(from: archiveHandle, offset: cursor, count: readSize)
            cursor += UInt64(inputChunk.count)
            remaining -= UInt64(inputChunk.count)

            try inputChunk.withUnsafeBytes { inputRawBuffer in
                guard let inputBase = inputRawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                    throw ProjectArchiveImportService.ImportError.invalidZip("invalid deflate input")
                }

                stream.next_in = UnsafeMutablePointer(mutating: inputBase)
                stream.avail_in = uInt(inputRawBuffer.count)

                while stream.avail_in > 0 {
                    let (status, produced) = try inflateIntoOutput(
                        stream: &stream,
                        outputBuffer: &outputBuffer,
                        outputHandle: outputHandle,
                        written: &written,
                        crc: &crc
                    )

                    if status == Z_STREAM_END {
                        reachedStreamEnd = true
                        if stream.avail_in > 0 || remaining > 0 {
                            throw ProjectArchiveImportService.ImportError.invalidZip("unexpected trailing deflate data")
                        }
                        break
                    }

                    if produced == 0 && status == Z_OK {
                        throw ProjectArchiveImportService.ImportError.invalidZip("deflate decode stalled")
                    }
                }
            }

            if reachedStreamEnd {
                break
            }
        }

        guard reachedStreamEnd else {
            throw ProjectArchiveImportService.ImportError.invalidZip("deflate stream truncated")
        }

        return (written: written, crc32: crc)
    }

    private static func inflateIntoOutput(
        stream: inout z_stream,
        outputBuffer: inout [UInt8],
        outputHandle: FileHandle,
        written: inout UInt64,
        crc: inout UInt32
    ) throws -> (status: Int32, produced: Int) {
        let status: Int32
        let produced: Int

        status = outputBuffer.withUnsafeMutableBytes { outputRawBuffer in
            stream.next_out = outputRawBuffer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(outputRawBuffer.count)
            return inflate(&stream, Z_NO_FLUSH)
        }

        produced = outputBuffer.count - Int(stream.avail_out)

        if produced > 0 {
            let chunk = Data(outputBuffer[0..<produced])
            try outputHandle.write(contentsOf: chunk)
            written += UInt64(produced)
            crc = updateCRC32(crc, with: chunk)
        }

        if status != Z_OK && status != Z_STREAM_END {
            throw ProjectArchiveImportService.ImportError.invalidZip("deflate decode failed (\(status))")
        }

        return (status: status, produced: produced)
    }

    private static func updateCRC32(_ current: UInt32, with data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return current
            }
            let next = crc32(uLong(current), base, uInt(rawBuffer.count))
            return UInt32(truncatingIfNeeded: next)
        }
    }

    private static func readData(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        if count < 0 {
            throw ProjectArchiveImportService.ImportError.invalidZip("invalid read length")
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw ProjectArchiveImportService.ImportError.invalidZip("unexpected end of file")
        }
        return data
    }

    private static func decodePath(from data: Data, flags: UInt16) -> String {
        if (flags & 0x0800) != 0,
           let utf8 = String(data: data, encoding: .utf8) {
            return utf8.replacingOccurrences(of: "\\", with: "/")
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.replacingOccurrences(of: "\\", with: "/")
        }
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty else { return }
        guard !path.hasPrefix("/") else {
            throw ProjectArchiveImportService.ImportError.invalidZip("absolute path entry")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                throw ProjectArchiveImportService.ImportError.invalidZip("invalid path component in \(path)")
            }
        }
    }

    private static func isSubpath(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path
        let candidatePath = candidate.path
        if candidatePath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func isSymlink(_ externalAttributes: UInt32) -> Bool {
        let fileMode = UInt16((externalAttributes >> 16) & 0xF000)
        return fileMode == 0xA000
    }
}

private extension Data {
    nonisolated func uint16LE(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw ProjectArchiveImportService.ImportError.invalidZip("unexpected end of file")
        }
        let b0 = UInt16(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
        return b0 | b1
    }

    nonisolated func uint32LE(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw ProjectArchiveImportService.ImportError.invalidZip("unexpected end of file")
        }
        let b0 = UInt32(self[index(startIndex, offsetBy: offset)])
        let b1 = UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
        let b2 = UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
        let b3 = UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
        return b0 | b1 | b2 | b3
    }
}
