//
//  StaticCodeScanner.swift
//  Doufu
//

import Foundation

nonisolated struct StaticCodeScanner {

    struct ScanResult: Sendable {
        let findings: [StaticFinding]
        let riskLevel: ImportRiskLevel
    }

    // MARK: - Scan Rules

    private struct ScanRule {
        let pattern: NSRegularExpression
        let category: FindingCategory
        let severity: FindingSeverity
        let description: String
        let applicableExtensions: Set<String> // empty = all
    }

    private static let textExtensions: Set<String> = [
        "html", "htm", "js", "mjs", "css", "svg", "json", "xml", "txt", "md",
        "ts", "jsx", "tsx", "vue", "yaml", "yml", "toml", "ini", "cfg",
        "sh", "bat", "py", "rb", "php", "java", "c", "h", "cpp", "swift",
    ]
    private static let knownAssetExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "tiff",
        "mp3", "wav", "ogg", "mp4", "webm", "mov",
        "ttf", "otf", "woff", "woff2", "eot",
    ]
    private static let scannableExtensions: Set<String> = ["html", "htm", "js", "mjs", "css", "svg", "json"]
    private static let codeExtensions: Set<String> = ["html", "htm", "js", "mjs", "svg"]

    private static let rules: [ScanRule] = {
        var rules: [ScanRule] = []

        func add(_ pattern: String, _ category: FindingCategory, _ severity: FindingSeverity, _ description: String, extensions: Set<String> = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            rules.append(ScanRule(pattern: regex, category: category, severity: severity, description: description, applicableExtensions: extensions))
        }

        // -- External References (in HTML) --
        add(#"<script[^>]+src\s*=\s*[\"']https?://"#, .externalReferences, .high,
            String(localized: "scan.finding.external_script", defaultValue: "Loads external script"), extensions: ["html", "htm", "svg"])
        add(#"<link[^>]+href\s*=\s*[\"']https?://"#, .externalReferences, .medium,
            String(localized: "scan.finding.external_link", defaultValue: "Links external stylesheet/resource"), extensions: ["html", "htm", "svg"])
        add(#"<iframe[^>]+src\s*=\s*[\"']https?://"#, .externalReferences, .high,
            String(localized: "scan.finding.external_iframe", defaultValue: "Embeds external iframe"), extensions: ["html", "htm", "svg"])
        add(#"<img[^>]+src\s*=\s*[\"']https?://"#, .externalReferences, .low,
            String(localized: "scan.finding.external_image", defaultValue: "Loads external image"), extensions: ["html", "htm", "svg"])

        // -- Doufu API --
        add(#"doufu\.camera"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_camera", defaultValue: "Uses doufu.camera (Camera access)"), extensions: codeExtensions)
        add(#"doufu\.mic"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_mic", defaultValue: "Uses doufu.mic (Microphone access)"), extensions: codeExtensions)
        add(#"doufu\.location"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_location", defaultValue: "Uses doufu.location (Location access)"), extensions: codeExtensions)
        add(#"doufu\.clipboard"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_clipboard", defaultValue: "Uses doufu.clipboard (Clipboard access)"), extensions: codeExtensions)
        add(#"doufu\.photos"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_photos", defaultValue: "Uses doufu.photos (Photos access)"), extensions: codeExtensions)
        add(#"doufu\.db"#, .doufuAPI, .info,
            String(localized: "scan.finding.doufu_db", defaultValue: "Uses doufu.db (Database access)"), extensions: codeExtensions)
        add(#"navigator\.geolocation"#, .doufuAPI, .info,
            String(localized: "scan.finding.geolocation", defaultValue: "Uses Geolocation API"), extensions: codeExtensions)
        add(#"getUserMedia"#, .doufuAPI, .info,
            String(localized: "scan.finding.getusermedia", defaultValue: "Requests camera or microphone"), extensions: codeExtensions)
        add(#"navigator\.clipboard"#, .doufuAPI, .info,
            String(localized: "scan.finding.clipboard", defaultValue: "Uses Clipboard API"), extensions: codeExtensions)

        // -- Network --
        add(#"fetch\s*\([^)]*https?://"#, .network, .high,
            String(localized: "scan.finding.fetch_external", defaultValue: "Fetches data from an external URL"), extensions: codeExtensions)
        add(#"fetch\s*\([^)]*\/\/"#, .network, .medium,
            String(localized: "scan.finding.fetch_protocol_relative", defaultValue: "Fetches data from a protocol-relative URL"), extensions: codeExtensions)
        add(#"new\s+XMLHttpRequest"#, .network, .medium,
            String(localized: "scan.finding.xhr", defaultValue: "Creates XMLHttpRequest"), extensions: codeExtensions)
        add(#"new\s+WebSocket\s*\("#, .network, .high,
            String(localized: "scan.finding.websocket", defaultValue: "Opens a WebSocket connection"), extensions: codeExtensions)
        add(#"navigator\.sendBeacon"#, .network, .high,
            String(localized: "scan.finding.beacon", defaultValue: "Sends data via navigator.sendBeacon"), extensions: codeExtensions)
        add(#"new\s+EventSource\s*\("#, .network, .medium,
            String(localized: "scan.finding.eventsource", defaultValue: "Opens a Server-Sent Events connection"), extensions: codeExtensions)

        // -- Data Exfiltration --
        add(#"document\.cookie"#, .dataExfiltration, .high,
            String(localized: "scan.finding.cookie", defaultValue: "Accesses document.cookie"), extensions: codeExtensions)
        add(#"sessionStorage\."#, .dataExfiltration, .medium,
            String(localized: "scan.finding.session_storage", defaultValue: "Accesses sessionStorage"), extensions: codeExtensions)
        add(#"document\.forms"#, .dataExfiltration, .medium,
            String(localized: "scan.finding.forms", defaultValue: "Accesses document.forms"), extensions: codeExtensions)

        // -- Execution --
        add(#"\beval\s*\("#, .execution, .high,
            String(localized: "scan.finding.eval", defaultValue: "Uses eval() for dynamic code execution"), extensions: codeExtensions)
        add(#"new\s+Function\s*\("#, .execution, .high,
            String(localized: "scan.finding.new_function", defaultValue: "Creates Function via constructor"), extensions: codeExtensions)
        add(#"setTimeout\s*\(\s*[\"']"#, .execution, .medium,
            String(localized: "scan.finding.settimeout_string", defaultValue: "setTimeout with string argument (implicit eval)"), extensions: codeExtensions)
        add(#"setInterval\s*\(\s*[\"']"#, .execution, .medium,
            String(localized: "scan.finding.setinterval_string", defaultValue: "setInterval with string argument (implicit eval)"), extensions: codeExtensions)
        add(#"document\.write\s*\("#, .execution, .medium,
            String(localized: "scan.finding.document_write", defaultValue: "Uses document.write"), extensions: codeExtensions)

        // -- Obfuscation --
        add(#"\batob\s*\("#, .obfuscation, .medium,
            String(localized: "scan.finding.atob", defaultValue: "Decodes base64 data (atob)"), extensions: codeExtensions)
        add(#"String\.fromCharCode\s*\([^)]{20,}"#, .obfuscation, .medium,
            String(localized: "scan.finding.fromcharcode", defaultValue: "String.fromCharCode with many arguments"), extensions: codeExtensions)
        add(#"(\\x[0-9a-fA-F]{2}){10,}"#, .obfuscation, .medium,
            String(localized: "scan.finding.hex_encoded", defaultValue: "Hex-encoded string sequence"), extensions: codeExtensions)
        add(#"(\\u[0-9a-fA-F]{4}){10,}"#, .obfuscation, .medium,
            String(localized: "scan.finding.unicode_encoded", defaultValue: "Unicode-encoded string sequence"), extensions: codeExtensions)

        return rules
    }()

    // MARK: - Public API

    static func scan(appURL: URL) -> ScanResult {
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return ScanResult(findings: [], riskLevel: .low)
        }

        // Collect raw hits first, then merge same-type findings.
        struct RawHit {
            let category: FindingCategory
            let severity: FindingSeverity
            let description: String
            let filePath: String
            let lineNumber: Int
        }

        var rawHits: [RawHit] = []

        for case let fileURL as URL in enumerator {
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular else { continue }

            let ext = fileURL.pathExtension.lowercased()
            let relativePath = fileURL.path.replacingOccurrences(of: appURL.path + "/", with: "")

            // Skip .git directory contents (not user-authored code)
            if relativePath.hasPrefix(".git/") { continue }

            // Detect binary files (non-text, non-known-asset)
            if !textExtensions.contains(ext) && !knownAssetExtensions.contains(ext) && !ext.isEmpty {
                rawHits.append(RawHit(
                    category: .binaryFiles, severity: .medium,
                    description: String(
                        format: String(localized: "scan.finding.binary_file", defaultValue: "Binary file cannot be audited (.%@)"),
                        ext
                    ),
                    filePath: relativePath, lineNumber: 0
                ))
                continue
            }

            // Only scan code/text files with known extensions
            guard scannableExtensions.contains(ext) else { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            let lines = content.components(separatedBy: .newlines)

            for (lineIndex, line) in lines.enumerated() {
                let nsLine = line as NSString
                let lineRange = NSRange(location: 0, length: nsLine.length)

                for rule in rules {
                    if !rule.applicableExtensions.isEmpty && !rule.applicableExtensions.contains(ext) {
                        continue
                    }
                    if rule.pattern.firstMatch(in: line, range: lineRange) != nil {
                        rawHits.append(RawHit(
                            category: rule.category, severity: rule.severity,
                            description: rule.description,
                            filePath: relativePath, lineNumber: lineIndex + 1
                        ))
                    }
                }
            }
        }

        // Deduplicate: same file + line + description → keep one
        var seenLines = Set<String>()
        rawHits = rawHits.filter { hit in
            let key = "\(hit.filePath):\(hit.lineNumber):\(hit.description)"
            return seenLines.insert(key).inserted
        }

        // Merge by (category, description) → one finding per unique issue type
        struct GroupKey: Hashable { let category: FindingCategory; let description: String }
        let grouped = Dictionary(grouping: rawHits) { GroupKey(category: $0.category, description: $0.description) }

        var mergedFindings: [StaticFinding] = []
        var counter = 0
        for (key, group) in grouped {
            guard let first = group.first else { continue }
            counter += 1
            let locations: [StaticFinding.Location] = group
                .map { StaticFinding.Location(filePath: $0.filePath, lineNumber: $0.lineNumber) }
                .sorted { lhs, rhs in lhs.filePath == rhs.filePath ? lhs.lineNumber < rhs.lineNumber : lhs.filePath < rhs.filePath }
            mergedFindings.append(StaticFinding(
                id: "static-\(counter)",
                category: key.category,
                severity: first.severity,
                description: key.description,
                locations: locations
            ))
        }

        // Sort by severity (high first), then description
        mergedFindings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            return lhs.description < rhs.description
        }

        let riskLevel = computeRiskLevel(findings: mergedFindings)

        return ScanResult(
            findings: mergedFindings,
            riskLevel: riskLevel
        )
    }

    // MARK: - Risk Level

    private static func computeRiskLevel(findings: [StaticFinding]) -> ImportRiskLevel {
        let hasHighExecution = findings.contains { $0.category == .execution && $0.severity >= .high }
        let hasHighNetwork = findings.contains { $0.category == .network && $0.severity >= .high }
        let hasHighExfiltration = findings.contains { $0.category == .dataExfiltration && $0.severity >= .high }
        let hasHighExternal = findings.contains { $0.category == .externalReferences && $0.severity >= .high }

        if hasHighExecution && (hasHighNetwork || hasHighExfiltration) {
            return .critical
        }
        if hasHighExecution && hasHighExternal {
            return .critical
        }
        if findings.contains(where: { $0.severity >= .high }) {
            return .high
        }
        if findings.contains(where: { $0.severity >= .medium }) {
            return .medium
        }
        return .low
    }
}
