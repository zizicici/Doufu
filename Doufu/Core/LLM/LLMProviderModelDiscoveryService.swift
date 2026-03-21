//
//  LLMProviderModelDiscoveryService.swift
//  Doufu
//
//  Created by Codex on 2026/03/07.
//

import Foundation

final class LLMProviderModelDiscoveryService {
    private struct OpenAIModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let displayName: String?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }

        let data: [Model]
    }

    private struct OpenAIModelEntry {
        let modelID: String
        let displayName: String?
    }

    private struct AnthropicModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let displayName: String?
            /// Maximum output tokens the model supports (returned by /v1/models).
            let maxTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
                case maxTokens = "max_tokens"
            }
        }

        let data: [Model]
    }

    private struct GeminiModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
            let thinking: Bool?
            /// Token limits reported by the Gemini /models endpoint.
            let inputTokenLimit: Int?
            let outputTokenLimit: Int?
        }

        let models: [Model]
    }

    private let decoder = JSONDecoder()

    func fetchModels(
        for provider: LLMProviderRecord,
        bearerToken: String
    ) async throws -> [LLMProviderModelRecord] {
        switch provider.kind {
        case .openAICompatible, .xiaomiMiMo:
            return try await fetchOpenAICompatibleModels(for: provider, bearerToken: bearerToken)
        case .openRouter:
            return try await fetchOpenRouterModels(for: provider, bearerToken: bearerToken)
        case .anthropic:
            return try await fetchAnthropicModels(for: provider, bearerToken: bearerToken)
        case .googleGemini:
            return try await fetchGeminiModels(for: provider, bearerToken: bearerToken)
        }
    }

    private func fetchOpenAICompatibleModels(
        for provider: LLMProviderRecord,
        bearerToken: String
    ) async throws -> [LLMProviderModelRecord] {
        let url = try buildOpenAIModelsURL(for: provider)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        if isChatGPTCodexBackend(url: URL(string: provider.effectiveBaseURLString)) {
            request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
            if let accountID = provider.chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines), !accountID.isEmpty {
                request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let modelEntries = try parseOpenAIModelEntries(from: data)
        return modelEntries.map { model in
            LLMProviderModelRecord(
                id: officialRecordID(for: model.modelID),
                modelID: model.modelID,
                displayName: model.displayName ?? model.modelID,
                source: .official,
                capabilities: .defaults(for: provider.kind, modelID: model.modelID)
            )
        }
    }

    private func fetchOpenRouterModels(
        for provider: LLMProviderRecord,
        bearerToken: String
    ) async throws -> [LLMProviderModelRecord] {
        let url = try buildURL(baseURLString: provider.effectiveBaseURLString, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try parseOpenRouterModels(from: data)
    }

    private func parseOpenRouterModels(from data: Data) throws -> [LLMProviderModelRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["data"] as? [[String: Any]]
        else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        var seen: Set<String> = []
        var records: [LLMProviderModelRecord] = []
        for model in models {
            guard let id = model["id"] as? String, !id.isEmpty else { continue }
            let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !seen.contains(normalizedID) else { continue }
            seen.insert(normalizedID)

            let displayName = (model["name"] as? String) ?? id
            var capabilities = LLMProviderModelCapabilities.defaults(for: .openRouter, modelID: id)

            if let contextLength = model["context_length"] as? Int, contextLength > 0 {
                capabilities.contextWindowTokensOverride = contextLength
            }
            if let topProvider = model["top_provider"] as? [String: Any],
               let maxCompletionTokens = topProvider["max_completion_tokens"] as? Int,
               maxCompletionTokens > 0 {
                capabilities.maxOutputTokensOverride = maxCompletionTokens
            }

            records.append(LLMProviderModelRecord(
                id: officialRecordID(for: id),
                modelID: id,
                displayName: displayName,
                source: .official,
                capabilities: capabilities
            ))
        }
        guard !records.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }
        return records
    }

    private func buildOpenAIModelsURL(for provider: LLMProviderRecord) throws -> URL {
        var components = try buildURLComponents(baseURLString: provider.effectiveBaseURLString, path: "models")
        if isChatGPTCodexBackend(url: URL(string: provider.effectiveBaseURLString)) {
            var queryItems = components.queryItems ?? []
            if !queryItems.contains(where: { $0.name == "client_version" }) {
                queryItems.append(URLQueryItem(name: "client_version", value: clientVersionString()))
            }
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw LLMProviderSettingsStoreError.invalidBaseURL
        }
        return url
    }

    private func fetchAnthropicModels(
        for provider: LLMProviderRecord,
        bearerToken: String
    ) async throws -> [LLMProviderModelRecord] {
        let url = try buildURL(baseURLString: provider.effectiveBaseURLString, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyAuthorizationHeaders(to: &request, provider: provider, bearerToken: bearerToken)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try decoder.decode(AnthropicModelsResponse.self, from: data)
        return payload.data.map { model in
            var capabilities = LLMProviderModelCapabilities.defaults(for: .anthropic, modelID: model.id)
            // Use API-reported max_tokens when available — more reliable than static registry.
            if let apiMaxTokens = model.maxTokens, apiMaxTokens > 0 {
                capabilities.maxOutputTokensOverride = apiMaxTokens
            }
            return LLMProviderModelRecord(
                id: officialRecordID(for: model.id),
                modelID: model.id,
                displayName: model.displayName ?? model.id,
                source: .official,
                capabilities: capabilities
            )
        }
    }

    private func fetchGeminiModels(
        for provider: LLMProviderRecord,
        bearerToken: String
    ) async throws -> [LLMProviderModelRecord] {
        var components = try buildURLComponents(baseURLString: provider.effectiveBaseURLString, path: "models")
        if provider.authMode == .apiKey {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: bearerToken)]
        }
        guard let url = components.url else {
            throw LLMProviderSettingsStoreError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider.authMode == .oauth {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try decoder.decode(GeminiModelsResponse.self, from: data)
        return payload.models.compactMap { model in
            let generationMethods = model.supportedGenerationMethods ?? []
            guard generationMethods.isEmpty || generationMethods.contains("generateContent") else {
                return nil
            }

            let normalizedID: String
            if model.name.hasPrefix("models/") {
                normalizedID = String(model.name.dropFirst("models/".count))
            } else {
                normalizedID = model.name
            }
            // Use the API's explicit thinking field when available;
            // otherwise fall back to the built-in registry / conservative default.
            let baseCapabilities = LLMProviderModelCapabilities.defaults(for: .googleGemini, modelID: normalizedID)
            let supportsThinking: Bool
            let canDisableThinking: Bool
            if let apiThinking = model.thinking {
                supportsThinking = apiThinking
                // Registry knows which models can disable; fall back to true for unknown.
                let registryEntry = LLMModelRegistry.lookup(providerKind: .googleGemini, modelID: normalizedID)
                canDisableThinking = supportsThinking && (registryEntry?.thinkingCanDisable ?? true)
            } else {
                supportsThinking = baseCapabilities.thinkingSupported
                canDisableThinking = baseCapabilities.thinkingCanDisable
            }
            // Use API-reported token limits when available.
            let maxOutputOverride = (model.outputTokenLimit ?? 0) > 0 ? model.outputTokenLimit : nil
            let contextWindowOverride = (model.inputTokenLimit ?? 0) > 0 ? model.inputTokenLimit : nil
            return LLMProviderModelRecord(
                id: officialRecordID(for: normalizedID),
                modelID: normalizedID,
                displayName: model.displayName ?? normalizedID,
                source: .official,
                capabilities: LLMProviderModelCapabilities(
                    reasoningEfforts: [],
                    thinkingSupported: supportsThinking,
                    thinkingCanDisable: canDisableThinking,
                    structuredOutputSupported: baseCapabilities.structuredOutputSupported,
                    maxOutputTokensOverride: maxOutputOverride,
                    contextWindowTokensOverride: contextWindowOverride
                )
            )
        }
    }

    private func buildURL(baseURLString: String, path: String) throws -> URL {
        let components = try buildURLComponents(baseURLString: baseURLString, path: path)
        guard let url = components.url else {
            throw LLMProviderSettingsStoreError.invalidBaseURL
        }
        return url
    }

    private func buildURLComponents(baseURLString: String, path: String) throws -> URLComponents {
        guard var components = URLComponents(string: baseURLString) else {
            throw LLMProviderSettingsStoreError.invalidBaseURL
        }

        let normalizedBasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedBasePath.isEmpty {
            components.path = "/" + normalizedPath
        } else {
            components.path = "/" + normalizedBasePath + "/" + normalizedPath
        }
        return components
    }

    private func applyAuthorizationHeaders(
        to request: inout URLRequest,
        provider: LLMProviderRecord,
        bearerToken: String
    ) {
        if provider.kind == .anthropic,
           let host = URL(string: provider.effectiveBaseURLString)?.host?.lowercased(),
           (host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")) {
            request.setValue(bearerToken, forHTTPHeaderField: "x-api-key")
            return
        }

        switch provider.authMode {
        case .apiKey:
            request.setValue(bearerToken, forHTTPHeaderField: "x-api-key")
        case .oauth:
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectChatService.ServiceError.networkFailed(
                String(localized: "model_discovery.error.invalid_response")
            )
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ProjectChatService.ServiceError.networkFailed(
                String(format: String(localized: "model_discovery.error.request_failed_format"), detail)
            )
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let error = object["error"] as? String {
            return error
        }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            if let type = error["type"] as? String {
                return type
            }
        }
        if let message = object["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseOpenAIModelEntries(from data: Data) throws -> [OpenAIModelEntry] {
        if
            let payload = try? decoder.decode(OpenAIModelsResponse.self, from: data),
            !payload.data.isEmpty
        {
            let entries = payload.data.map { model in
                OpenAIModelEntry(modelID: model.id, displayName: model.displayName)
            }
            let deduplicated = deduplicateOpenAIModelEntries(entries)
            if !deduplicated.isEmpty {
                return deduplicated
            }
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ProjectChatService.ServiceError.invalidResponse
        }

        var entries: [OpenAIModelEntry] = []
        collectOpenAIModelEntries(from: root, depth: 0, entries: &entries)
        let deduplicated = deduplicateOpenAIModelEntries(entries)
        guard !deduplicated.isEmpty else {
            throw ProjectChatService.ServiceError.invalidResponse
        }
        return deduplicated
    }

    private func collectOpenAIModelEntries(
        from object: Any,
        depth: Int,
        entries: inout [OpenAIModelEntry]
    ) {
        guard depth <= 6 else {
            return
        }

        if let dictionary = object as? [String: Any] {
            if let entry = parseOpenAIModelEntry(from: dictionary) {
                entries.append(entry)
            }

            for key in ["data", "models", "items", "results", "categories", "model"] {
                guard let nested = dictionary[key] else {
                    continue
                }
                collectOpenAIModelEntries(from: nested, depth: depth + 1, entries: &entries)
            }
            return
        }

        if let array = object as? [Any] {
            for item in array {
                collectOpenAIModelEntries(from: item, depth: depth + 1, entries: &entries)
            }
        }
    }

    private func parseOpenAIModelEntry(from dictionary: [String: Any]) -> OpenAIModelEntry? {
        let objectType = (dictionary["object"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let hasModelObjectType = objectType.contains("model")

        let modelIdentifierCandidates: [String?] = [
            dictionary["id"] as? String,
            dictionary["slug"] as? String,
            dictionary["name"] as? String,
            dictionary["model"] as? String,
            (dictionary["model"] as? [String: Any])?["id"] as? String
        ]

        let normalizedModelID = modelIdentifierCandidates
            .compactMap { normalizeOpenAIModelID($0) }
            .first ?? ""
        guard !normalizedModelID.isEmpty else {
            return nil
        }

        let hasStrongModelHintField = dictionary["slug"] != nil || dictionary["model"] != nil
        guard hasModelObjectType || hasStrongModelHintField || looksLikeModelID(normalizedModelID) else {
            return nil
        }

        let displayName = [
            dictionary["display_name"] as? String,
            dictionary["displayName"] as? String,
            dictionary["name"] as? String,
            dictionary["title"] as? String
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                !value.isEmpty && value.caseInsensitiveCompare(normalizedModelID) != .orderedSame
            }

        return OpenAIModelEntry(modelID: normalizedModelID, displayName: displayName)
    }

    private func normalizeOpenAIModelID(_ rawValue: String?) -> String? {
        guard let rawValue else {
            return nil
        }
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        if normalized.hasPrefix("models/") {
            normalized = String(normalized.dropFirst("models/".count))
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeModelID(_ modelID: String) -> Bool {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }
        if normalized.contains("gpt")
            || normalized.contains("claude")
            || normalized.contains("gemini")
            || normalized.contains("codex")
            || normalized.hasPrefix("o1")
            || normalized.hasPrefix("o3")
            || normalized.hasPrefix("o4")
        {
            return true
        }
        return normalized.contains("-")
    }

    private func deduplicateOpenAIModelEntries(_ entries: [OpenAIModelEntry]) -> [OpenAIModelEntry] {
        var seen: Set<String> = []
        var deduplicated: [OpenAIModelEntry] = []
        for entry in entries {
            let normalizedModelID = entry.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedModelID.isEmpty else {
                continue
            }
            guard !seen.contains(normalizedModelID) else {
                continue
            }
            seen.insert(normalizedModelID)
            deduplicated.append(entry)
        }
        return deduplicated
    }

    private func isChatGPTCodexBackend(url: URL?) -> Bool {
        guard let url else {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "chatgpt.com" && path.contains("/backend-api/codex")
    }

    private func clientVersionString() -> String {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return bundleVersion.isEmpty ? "1.0.0" : bundleVersion
    }

    private func officialRecordID(for modelID: String) -> String {
        "official:" + modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
