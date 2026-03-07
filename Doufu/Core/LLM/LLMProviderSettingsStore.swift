//
//  LLMProviderSettingsStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import Foundation
import Security

struct LLMProviderRecord: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case openAICompatible = "openai_compatible"
        case anthropic
        case googleGemini = "google_gemini"

        var displayName: String {
            switch self {
            case .openAICompatible:
                return String(localized: "providers.kind.openai_compatible.title")
            case .anthropic:
                return "Anthropic"
            case .googleGemini:
                return "Google Gemini"
            }
        }

        var subtitle: String {
            switch self {
            case .openAICompatible:
                return String(localized: "providers.kind.openai_compatible.subtitle")
            case .anthropic:
                return "Claude API / Claude OAuth token"
            case .googleGemini:
                return "Gemini API / Google Cloud Code Assist OAuth"
            }
        }

        var iconSystemName: String {
            switch self {
            case .openAICompatible:
                return "sparkles.rectangle.stack"
            case .anthropic:
                return "text.quote"
            case .googleGemini:
                return "diamond"
            }
        }

        var defaultBaseURLString: String {
            switch self {
            case .openAICompatible:
                return "https://api.openai.com"
            case .anthropic:
                return "https://api.anthropic.com/v1"
            case .googleGemini:
                return "https://generativelanguage.googleapis.com/v1beta"
            }
        }

        var defaultAutoAppendV1: Bool {
            switch self {
            case .openAICompatible:
                return true
            case .anthropic, .googleGemini:
                return false
            }
        }

        var builtInModels: [String] {
            switch self {
            case .openAICompatible:
                return ["gpt-5.3-codex", "gpt-5.4", "gpt-5.4-pro", "gpt-5-mini"]
            case .anthropic:
                return ["claude-opus-4-6", "claude-sonnet-4-5", "claude-haiku-4-5"]
            case .googleGemini:
                return ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
            }
        }

        var defaultModelID: String {
            let firstBuiltIn = builtInModels.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !firstBuiltIn.isEmpty {
                return firstBuiltIn
            }
            switch self {
            case .openAICompatible:
                return "gpt-5.3-codex"
            case .anthropic:
                return "claude-sonnet-4-5"
            case .googleGemini:
                return "gemini-2.5-pro"
            }
        }
    }

    enum AuthMode: String, Codable {
        case apiKey = "api_key"
        case oauth

        var displayName: String {
            switch self {
            case .apiKey:
                return String(localized: "providers.auth_mode.api_key")
            case .oauth:
                return String(localized: "providers.auth_mode.oauth")
            }
        }
    }

    let id: String
    let kind: Kind
    let authMode: AuthMode
    let createdAt: Date
    let updatedAt: Date
    let label: String
    let baseURLString: String
    let autoAppendV1: Bool
    let chatGPTAccountID: String?
    let modelID: String?

    var effectiveBaseURLString: String {
        guard autoAppendV1 else {
            return baseURLString
        }

        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix("/v1") {
            return trimmed
        }
        return trimmed + "/v1"
    }

    var effectiveModelID: String {
        let normalized = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? kind.defaultModelID : normalized
    }
}

enum LLMProviderSettingsStoreError: LocalizedError {
    case emptyLabel
    case emptyAPIKey
    case invalidBaseURL
    case encodeFailed
    case keychainFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return String(localized: "provider_store.error.empty_label")
        case .emptyAPIKey:
            return String(localized: "provider_store.error.empty_api_key")
        case .invalidBaseURL:
            return String(localized: "provider_store.error.invalid_base_url")
        case .encodeFailed:
            return String(localized: "provider_store.error.encode_failed")
        case .keychainFailed:
            return String(localized: "provider_store.error.keychain_failed")
        }
    }
}

final class LLMProviderSettingsStore {
    static let shared = LLMProviderSettingsStore()

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let providersKey = "llm.providers.records.v1"
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.zizicici.doufu"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProviders() -> [LLMProviderRecord] {
        guard
            let data = defaults.data(forKey: providersKey),
            let records = try? decoder.decode([LLMProviderRecord].self, from: data)
        else {
            return []
        }

        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadProvider(id: String) -> LLMProviderRecord? {
        loadProviders().first { $0.id == id }
    }

    @discardableResult
    func addOpenAICompatibleProviderUsingAPIKey(
        label: String,
        apiKey: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        modelID: String?
    ) throws -> LLMProviderRecord {
        try addProviderUsingAPIKey(
            kind: .openAICompatible,
            label: label,
            apiKey: apiKey,
            baseURLString: baseURLString,
            autoAppendV1: autoAppendV1,
            modelID: modelID
        )
    }

    @discardableResult
    func addProviderUsingAPIKey(
        kind: LLMProviderRecord.Kind,
        label: String,
        apiKey: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        modelID: String?
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyAPIKey
        }

        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: kind)
        let normalizedModelID = normalizeModelID(modelID, kind: kind)
        let now = Date()
        let provider = LLMProviderRecord(
            id: UUID().uuidString,
            kind: kind,
            authMode: .apiKey,
            createdAt: now,
            updatedAt: now,
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: nil,
            modelID: normalizedModelID
        )

        var allProviders = loadProviders()
        allProviders.append(provider)
        try saveProviders(allProviders)
        try saveAPIKey(normalizedAPIKey, providerID: provider.id)
        return provider
    }

    @discardableResult
    func addOpenAICompatibleProviderUsingOAuth(
        label: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        bearerToken: String?,
        chatGPTAccountID: String?,
        modelID: String?
    ) throws -> LLMProviderRecord {
        try addProviderUsingOAuth(
            kind: .openAICompatible,
            label: label,
            baseURLString: baseURLString,
            autoAppendV1: autoAppendV1,
            bearerToken: bearerToken,
            chatGPTAccountID: chatGPTAccountID,
            modelID: modelID
        )
    }

    @discardableResult
    func addProviderUsingOAuth(
        kind: LLMProviderRecord.Kind,
        label: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        bearerToken: String?,
        chatGPTAccountID: String?,
        modelID: String?
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: kind)
        let normalizedModelID = normalizeModelID(modelID, kind: kind)
        let now = Date()
        let provider = LLMProviderRecord(
            id: UUID().uuidString,
            kind: kind,
            authMode: .oauth,
            createdAt: now,
            updatedAt: now,
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: normalizedModelID
        )

        var allProviders = loadProviders()
        allProviders.append(provider)
        try saveProviders(allProviders)

        let normalizedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedToken.isEmpty {
            try saveOAuthBearerToken(normalizedToken, providerID: provider.id)
        }
        return provider
    }

    @discardableResult
    func updateOpenAICompatibleProviderUsingAPIKey(
        providerID: String,
        label: String,
        apiKey: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        modelID: String?
    ) throws -> LLMProviderRecord {
        try updateProviderUsingAPIKey(
            providerID: providerID,
            label: label,
            apiKey: apiKey,
            baseURLString: baseURLString,
            autoAppendV1: autoAppendV1,
            modelID: modelID
        )
    }

    @discardableResult
    func updateProviderUsingAPIKey(
        providerID: String,
        label: String,
        apiKey: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        modelID: String?
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyAPIKey
        }

        var providers = loadProviders()
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw LLMProviderSettingsStoreError.encodeFailed
        }
        let existingProvider = providers[index]
        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: existingProvider.kind)
        let normalizedModelID = normalizeModelID(modelID, kind: existingProvider.kind)
        let updatedProvider = LLMProviderRecord(
            id: existingProvider.id,
            kind: existingProvider.kind,
            authMode: .apiKey,
            createdAt: existingProvider.createdAt,
            updatedAt: Date(),
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: nil,
            modelID: normalizedModelID
        )
        providers[index] = updatedProvider
        try saveProviders(providers)
        try saveAPIKey(normalizedAPIKey, providerID: providerID)
        if existingProvider.authMode == .oauth {
            try deleteOAuthBearerToken(providerID: providerID)
        }
        return updatedProvider
    }

    @discardableResult
    func updateOpenAICompatibleProviderUsingOAuth(
        providerID: String,
        label: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        bearerToken: String,
        chatGPTAccountID: String?,
        modelID: String?
    ) throws -> LLMProviderRecord {
        try updateProviderUsingOAuth(
            providerID: providerID,
            label: label,
            baseURLString: baseURLString,
            autoAppendV1: autoAppendV1,
            bearerToken: bearerToken,
            chatGPTAccountID: chatGPTAccountID,
            modelID: modelID
        )
    }

    @discardableResult
    func updateProviderUsingOAuth(
        providerID: String,
        label: String,
        baseURLString: String?,
        autoAppendV1: Bool,
        bearerToken: String,
        chatGPTAccountID: String?,
        modelID: String?
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyAPIKey
        }

        var providers = loadProviders()
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else {
            throw LLMProviderSettingsStoreError.encodeFailed
        }
        let existingProvider = providers[index]
        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: existingProvider.kind)
        let normalizedModelID = normalizeModelID(modelID, kind: existingProvider.kind)
        let updatedProvider = LLMProviderRecord(
            id: existingProvider.id,
            kind: existingProvider.kind,
            authMode: .oauth,
            createdAt: existingProvider.createdAt,
            updatedAt: Date(),
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
            modelID: normalizedModelID
        )
        providers[index] = updatedProvider
        try saveProviders(providers)
        try saveOAuthBearerToken(normalizedToken, providerID: providerID)
        if existingProvider.authMode == .apiKey {
            try deleteAPIKey(providerID: providerID)
        }
        return updatedProvider
    }

    func hasAPIKey(for providerID: String) -> Bool {
        (try? loadAPIKey(for: providerID))?.isEmpty == false
    }

    func loadAPIKey(for providerID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: apiKeyAccount(providerID: providerID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let key = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw LLMProviderSettingsStoreError.keychainFailed(status: status)
        }
    }

    func loadOAuthBearerToken(for providerID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: oauthBearerTokenAccount(providerID: providerID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard
                let data = item as? Data,
                let token = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw LLMProviderSettingsStoreError.keychainFailed(status: status)
        }
    }

    func loadBearerToken(for provider: LLMProviderRecord) throws -> String? {
        switch provider.authMode {
        case .apiKey:
            return try loadAPIKey(for: provider.id)
        case .oauth:
            return try loadOAuthBearerToken(for: provider.id)
        }
    }

    func deleteProvider(id: String) throws {
        var providers = loadProviders()
        providers.removeAll { $0.id == id }
        try saveProviders(providers)
        try deleteAPIKey(providerID: id)
        try deleteOAuthBearerToken(providerID: id)
    }

    private func normalizeBaseURL(_ rawValue: String?, kind: LLMProviderRecord.Kind) throws -> String {
        let fallback = kind.defaultBaseURLString
        let candidate = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = candidate.isEmpty ? fallback : candidate

        guard
            let components = URLComponents(string: normalized),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            components.host?.isEmpty == false
        else {
            throw LLMProviderSettingsStoreError.invalidBaseURL
        }

        return normalized
    }

    private func normalizeModelID(_ rawValue: String?, kind: LLMProviderRecord.Kind) -> String {
        let candidate = (rawValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? kind.defaultModelID : candidate
    }

    private func saveProviders(_ providers: [LLMProviderRecord]) throws {
        guard let data = try? encoder.encode(providers) else {
            throw LLMProviderSettingsStoreError.encodeFailed
        }
        defaults.set(data, forKey: providersKey)
    }

    private func apiKeyAccount(providerID: String) -> String {
        "llm.provider.\(providerID).api_key"
    }

    private func oauthBearerTokenAccount(providerID: String) -> String {
        "llm.provider.\(providerID).oauth_bearer_token"
    }

    private func saveAPIKey(_ key: String, providerID: String) throws {
        let valueData = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: apiKeyAccount(providerID: providerID)
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw LLMProviderSettingsStoreError.keychainFailed(status: updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = valueData
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw LLMProviderSettingsStoreError.keychainFailed(status: createStatus)
        }
    }

    private func saveOAuthBearerToken(_ token: String, providerID: String) throws {
        let valueData = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: oauthBearerTokenAccount(providerID: providerID)
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: valueData
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw LLMProviderSettingsStoreError.keychainFailed(status: updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = valueData
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw LLMProviderSettingsStoreError.keychainFailed(status: createStatus)
        }
    }

    private func deleteAPIKey(providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: apiKeyAccount(providerID: providerID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LLMProviderSettingsStoreError.keychainFailed(status: status)
        }
    }

    private func deleteOAuthBearerToken(providerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: oauthBearerTokenAccount(providerID: providerID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LLMProviderSettingsStoreError.keychainFailed(status: status)
        }
    }
}
