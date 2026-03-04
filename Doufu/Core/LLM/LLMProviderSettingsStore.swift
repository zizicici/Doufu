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

        var displayName: String {
            switch self {
            case .openAICompatible:
                return "OpenAI / Compatible API"
            }
        }
    }

    enum AuthMode: String, Codable {
        case apiKey = "api_key"
        case oauth

        var displayName: String {
            switch self {
            case .apiKey:
                return "API Key"
            case .oauth:
                return "OAuth"
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
            return "请输入 Provider 名称。"
        case .emptyAPIKey:
            return "请输入 API Key。"
        case .invalidBaseURL:
            return "自定义地址格式无效，请输入 http(s) 地址。"
        case .encodeFailed:
            return "Provider 保存失败，请稍后重试。"
        case .keychainFailed:
            return "密钥保存失败，请稍后重试。"
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

    @discardableResult
    func addOpenAICompatibleProviderUsingAPIKey(
        label: String,
        apiKey: String,
        baseURLString: String?,
        autoAppendV1: Bool
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAPIKey.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyAPIKey
        }

        let normalizedBaseURL = try normalizeBaseURL(baseURLString)
        let now = Date()
        let provider = LLMProviderRecord(
            id: UUID().uuidString,
            kind: .openAICompatible,
            authMode: .apiKey,
            createdAt: now,
            updatedAt: now,
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1
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
        bearerToken: String?
    ) throws -> LLMProviderRecord {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyLabel
        }

        let normalizedBaseURL = try normalizeBaseURL(baseURLString)
        let now = Date()
        let provider = LLMProviderRecord(
            id: UUID().uuidString,
            kind: .openAICompatible,
            authMode: .oauth,
            createdAt: now,
            updatedAt: now,
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1
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

    func deleteProvider(id: String) throws {
        var providers = loadProviders()
        providers.removeAll { $0.id == id }
        try saveProviders(providers)
        try deleteAPIKey(providerID: id)
        try deleteOAuthBearerToken(providerID: id)
    }

    private func normalizeBaseURL(_ rawValue: String?) throws -> String {
        let fallback = "https://api.openai.com"
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
