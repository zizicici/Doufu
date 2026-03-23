//
//  LLMCodeScanner.swift
//  Doufu
//

import Foundation

nonisolated final class LLMCodeScanner {

    struct ScanResult: Sendable {
        let findings: [LLMFinding]
        let summary: String
        let riskLevel: ImportRiskLevel
    }

    private static let scannableExtensions: Set<String> = ["html", "htm", "js", "mjs", "css", "svg", "json"]
    private static let maxContentCharacters = 100_000
    private static let priorityExtensions: [String] = ["js", "mjs", "html", "htm"]

    // MARK: - Public API

    /// Returns nil if no credentials are available (caller should show "skipped" UI).
    @MainActor
    static func resolveCredential() -> (credential: ProjectChatService.ProviderCredential, modelID: String)? {
        let providerStore = LLMProviderSettingsStore.shared
        let credentials = ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
        guard !credentials.isEmpty else { return nil }

        // Try the app default selection first
        let modelSelectionStore = ModelSelectionStateStore.shared
        if let appDefault = modelSelectionStore.loadAppDefaultSelection() {
            let resolution = ModelSelectionResolver.resolve(
                appDefault: appDefault,
                projectDefault: nil,
                threadSelection: nil,
                availableCredentials: credentials,
                providerStore: providerStore
            )
            if let cred = resolution.credential, let modelRecordID = resolution.modelRecordID {
                // Load the model record to get the actual model ID
                if let provider = providerStore.loadProvider(id: cred.providerID) {
                    let modelRecord = provider.models.first { $0.id == modelRecordID }
                    if let modelID = modelRecord?.modelID {
                        let updatedCred = ProjectChatService.ProviderCredential(
                            providerID: cred.providerID,
                            providerLabel: cred.providerLabel,
                            providerKind: cred.providerKind,
                            authMode: cred.authMode,
                            modelID: modelID,
                            baseURL: cred.baseURL,
                            bearerToken: cred.bearerToken,
                            chatGPTAccountID: cred.chatGPTAccountID,
                            profile: LLMModelRegistry.resolve(
                                providerKind: cred.providerKind,
                                modelID: modelID,
                                modelRecord: modelRecord
                            )
                        )
                        return (updatedCred, modelID)
                    }
                }
            }
        }

        // Fallback: use first credential with a default model
        if let firstCred = credentials.first,
           let provider = providerStore.loadProvider(id: firstCred.providerID),
           let firstModel = provider.models.first {
            let updatedCred = ProjectChatService.ProviderCredential(
                providerID: firstCred.providerID,
                providerLabel: firstCred.providerLabel,
                providerKind: firstCred.providerKind,
                authMode: firstCred.authMode,
                modelID: firstModel.modelID,
                baseURL: firstCred.baseURL,
                bearerToken: firstCred.bearerToken,
                chatGPTAccountID: firstCred.chatGPTAccountID,
                profile: LLMModelRegistry.resolve(
                    providerKind: firstCred.providerKind,
                    modelID: firstModel.modelID,
                    modelRecord: firstModel
                )
            )
            return (updatedCred, firstModel.modelID)
        }

        return nil
    }

    @MainActor
    static func scan(
        appURL: URL,
        credential: ProjectChatService.ProviderCredential,
        modelID: String,
        onProgress: (@MainActor (String) -> Void)?
    ) async throws -> ScanResult {
        try Task.checkCancellation()

        // Collect project source code (off main thread)
        let sourceContent = await Task.detached(priority: .userInitiated) {
            collectSourceCode(appURL: appURL)
        }.value
        guard !sourceContent.isEmpty else {
            return ScanResult(
                findings: [],
                summary: String(localized: "scan.llm.no_source_files", defaultValue: "No source files found."),
                riskLevel: .low
            )
        }

        let deviceLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        let systemPrompt = buildSecurityReviewPrompt(language: deviceLanguage)
        let userMessage = """
        Analyze the following web project source code for security risks. The code is from a mobile app project that runs in a sandboxed WebView.

        Focus on:
        1. Malicious patterns (crypto mining, phishing, data exfiltration)
        2. External network requests to suspicious domains
        3. Dynamic code execution (eval, Function constructor)
        4. Obfuscated or encoded payloads
        5. Attempts to escape the sandbox or access native APIs in unintended ways

        IMPORTANT: All "description", "recommendation", and "summary" fields MUST be written in \(deviceLanguage).

        Respond with ONLY a JSON object in this exact format (no markdown, no code fences):
        {
          "findings": [
            {
              "severity": "high|medium|low|info",
              "description": "(in \(deviceLanguage)) What the issue is",
              "filePath": "relative/path/to/file.js",
              "recommendation": "(in \(deviceLanguage)) What to do about it"
            }
          ],
          "summary": "(in \(deviceLanguage)) One paragraph overall assessment",
          "riskLevel": "low|medium|high|critical"
        }

        If no issues are found, return empty findings array with "low" riskLevel.

        --- PROJECT SOURCE CODE ---
        \(sourceContent)
        """

        let configuration = ProjectChatConfiguration()
        let client = LLMStreamingClient(configuration: configuration)

        let inputMessages = [
            ResponseInputMessage(role: "user", text: userMessage)
        ]

        let response = try await client.requestModelResponseStreaming(
            requestLabel: "security-scan",
            model: modelID,
            developerInstruction: systemPrompt,
            inputItems: inputMessages,
            credential: credential,
            projectUsageIdentifier: nil,
            initialReasoningEffort: .low,
            executionOptions: ProjectChatService.ModelExecutionOptions(
                reasoningEffort: .low,
                anthropicThinkingEnabled: false,
                geminiThinkingEnabled: false,
                mimoThinkingEnabled: false,
                chatCompletionsThinkingEnabled: false
            ),
            responseFormat: nil,
            onStreamedText: onProgress,
            onUsage: nil
        )

        return parseResponse(response)
    }

    // MARK: - Private

    private static func collectSourceCode(appURL: URL) -> String {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return "" }

        struct FileEntry {
            let url: URL
            let relativePath: String
            let priority: Int
        }

        var entries: [FileEntry] = []
        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard scannableExtensions.contains(ext) else { continue }
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: appURL.path + "/", with: "")

            // Skip AGENTS.md, DOUFU.MD, and .git directory contents
            if relativePath.hasPrefix(".git/") || relativePath == "AGENTS.md" || relativePath == "DOUFU.MD" {
                continue
            }

            let priority = priorityExtensions.firstIndex(of: ext) ?? priorityExtensions.count
            entries.append(FileEntry(url: fileURL, relativePath: relativePath, priority: priority))
        }

        // Sort by priority (JS/HTML first)
        entries.sort { $0.priority < $1.priority }

        var result = ""
        var totalChars = 0

        for entry in entries {
            guard let content = try? String(contentsOf: entry.url, encoding: .utf8) else { continue }

            let header = "\n--- FILE: \(entry.relativePath) ---\n"
            let remaining = maxContentCharacters - totalChars - header.count
            guard remaining > 0 else { break }

            let truncatedContent = remaining >= content.count ? content : String(content.prefix(remaining)) + "\n[TRUNCATED]"
            result += header + truncatedContent
            totalChars += header.count + truncatedContent.count
        }

        return result
    }

    private static func buildSecurityReviewPrompt(language: String) -> String {
        """
        You are a security code reviewer specializing in web application security. \
        You are reviewing code from a project that will run in a sandboxed WKWebView on iOS. \
        The app provides shims for localStorage, IndexedDB, and fetch (CORS-free proxy). \
        Native capabilities (camera, microphone, geolocation, clipboard) require explicit user permission.

        Your job is to identify:
        - Malicious code patterns (crypto miners, keyloggers, phishing forms, data theft)
        - Suspicious network activity (beacons to tracking servers, data exfiltration endpoints)
        - Code obfuscation that may hide malicious intent
        - Unsafe dynamic code execution
        - Any attempt to exploit the bridge or sandbox

        Be precise and avoid false positives. Common patterns like fetch() for legitimate API calls, \
        localStorage for app state, or standard DOM manipulation are NOT security issues. \
        Focus on genuinely suspicious or dangerous patterns.

        IMPORTANT: Your review is a best-effort heuristic, not a guarantee of safety. \
        Use hedged language like "may", "appears to", "could potentially" rather than absolute statements. \
        Never claim the code is "safe", "secure", or "free of issues" — instead say "no obvious issues were found" or similar. \
        Even if no findings are reported, the summary must note that this review has inherent limitations.

        CRITICAL: You MUST write all human-readable text (description, recommendation, summary) in the language identified by the code "\(language)". \
        For example, if the language is "zh", write in Chinese; if "ja", write in Japanese; if "en", write in English.

        Return your analysis as a JSON object. Do not wrap in code fences.
        """
    }

    private static func parseResponse(_ response: String) -> ScanResult {
        // Strip potential markdown code fences
        var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```json") {
            cleaned = String(cleaned.dropFirst(7))
        } else if cleaned.hasPrefix("```") {
            cleaned = String(cleaned.dropFirst(3))
        }
        if cleaned.hasSuffix("```") {
            cleaned = String(cleaned.dropLast(3))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else {
            return ScanResult(
                findings: [],
                summary: String(localized: "scan.llm.parse_failed", defaultValue: "Failed to parse AI response."),
                riskLevel: .high
            )
        }

        struct LLMResponse: Codable {
            let findings: [LLMResponseFinding]?
            let summary: String?
            let riskLevel: String?

            struct LLMResponseFinding: Codable {
                let severity: String?
                let description: String?
                let filePath: String?
                let recommendation: String?
            }
        }

        guard let parsed = try? JSONDecoder().decode(LLMResponse.self, from: data) else {
            return ScanResult(
                findings: [],
                summary: String(localized: "scan.llm.parse_failed", defaultValue: "Failed to parse AI response."),
                riskLevel: .high
            )
        }

        var findings: [LLMFinding] = []
        var counter = 0
        for f in parsed.findings ?? [] {
            counter += 1
            let severity = FindingSeverity(rawValue: f.severity ?? "info") ?? .info
            findings.append(LLMFinding(
                id: "llm-\(counter)",
                severity: severity,
                description: f.description ?? "",
                filePath: f.filePath,
                recommendation: f.recommendation
            ))
        }

        let riskLevel: ImportRiskLevel
        switch parsed.riskLevel?.lowercased() {
        case "critical": riskLevel = .critical
        case "high": riskLevel = .high
        case "medium": riskLevel = .medium
        default: riskLevel = .low
        }

        return ScanResult(
            findings: findings,
            summary: parsed.summary ?? "",
            riskLevel: riskLevel
        )
    }
}
