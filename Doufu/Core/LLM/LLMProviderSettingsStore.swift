//
//  LLMProviderSettingsStore.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import Foundation
import Security
import GRDB

struct LLMProviderModelCapabilities: Codable, Equatable, Hashable {
    var reasoningEfforts: [ProjectChatService.ReasoningEffort]
    var thinkingSupported: Bool
    var thinkingCanDisable: Bool
    var structuredOutputSupported: Bool
    /// User-specified max output tokens override.  When set, takes priority
    /// over the built-in lookup table in `ProjectChatConfiguration`.
    var maxOutputTokensOverride: Int?
    /// User-specified context window override (in tokens).
    var contextWindowTokensOverride: Int?

    /// Conservative defaults for unknown models.  No string-based guessing —
    /// precise capabilities come from `LLMModelRegistry` instead.
    static func defaults(
        for providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> LLMProviderModelCapabilities {
        let entry = LLMModelRegistry.lookup(providerKind: providerKind, modelID: modelID)
            ?? LLMModelRegistry.conservativeFallback(providerKind: providerKind)
        return LLMProviderModelCapabilities(
            reasoningEfforts: entry.reasoningEfforts,
            thinkingSupported: entry.thinkingSupported,
            thinkingCanDisable: entry.thinkingCanDisable,
            structuredOutputSupported: entry.structuredOutputSupported
        )
    }
}

struct LLMProviderModelRecord: Codable, Equatable, Hashable {
    enum Source: String, Codable {
        case official
        case custom
    }

    let id: String
    let modelID: String
    let displayName: String
    let source: Source
    let capabilities: LLMProviderModelCapabilities

    var effectiveDisplayName: String {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? modelID : normalized
    }

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

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
                return String(localized: "providers.kind.anthropic.title")
            case .googleGemini:
                return "Google Gemini"
            }
        }

        var subtitle: String {
            switch self {
            case .openAICompatible:
                return String(localized: "providers.kind.openai_compatible.subtitle")
            case .anthropic:
                return String(localized: "providers.kind.anthropic.subtitle")
            case .googleGemini:
                return "Gemini API / Google OAuth"
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
            builtInModels.first ?? ""
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
    let models: [LLMProviderModelRecord]

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

    var availableModels: [LLMProviderModelRecord] {
        let orderedModels = models

        var seenModelIDs: Set<String> = []
        var deduplicated: [LLMProviderModelRecord] = []
        for model in orderedModels {
            let normalizedID = model.normalizedID
            guard !normalizedID.isEmpty else {
                continue
            }
            guard !seenModelIDs.contains(normalizedID) else {
                continue
            }
            seenModelIDs.insert(normalizedID)
            deduplicated.append(model)
        }
        return deduplicated
    }

    func modelRecord(for recordID: String) -> LLMProviderModelRecord? {
        let normalized = recordID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return availableModels.first { $0.normalizedID == normalized }
    }

    func copying(
        authMode: AuthMode? = nil,
        updatedAt: Date? = nil,
        label: String? = nil,
        baseURLString: String? = nil,
        autoAppendV1: Bool? = nil,
        chatGPTAccountID: String?? = nil,
        modelID: String?? = nil,
        models: [LLMProviderModelRecord]? = nil
    ) -> LLMProviderRecord {
        LLMProviderRecord(
            id: self.id,
            kind: self.kind,
            authMode: authMode ?? self.authMode,
            createdAt: self.createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            label: label ?? self.label,
            baseURLString: baseURLString ?? self.baseURLString,
            autoAppendV1: autoAppendV1 ?? self.autoAppendV1,
            chatGPTAccountID: chatGPTAccountID ?? self.chatGPTAccountID,
            modelID: modelID ?? self.modelID,
            models: models ?? self.models
        )
    }
}

enum LLMProviderSettingsStoreError: LocalizedError {
    case emptyLabel
    case emptyAPIKey
    case invalidBaseURL
    case emptyModelID
    case encodeFailed
    case providerNotFound
    case keychainFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return String(localized: "provider_store.error.empty_label")
        case .emptyAPIKey:
            return String(localized: "provider_store.error.empty_api_key")
        case .invalidBaseURL:
            return String(localized: "provider_store.error.invalid_base_url")
        case .emptyModelID:
            return String(localized: "provider_store.error.empty_model_id")
        case .encodeFailed:
            return String(localized: "provider_store.error.encode_failed")
        case .providerNotFound:
            return String(localized: "provider_store.error.provider_not_found")
        case .keychainFailed:
            return String(localized: "provider_store.error.keychain_failed")
        }
    }
}

final class LLMProviderSettingsStore {
    static let shared = LLMProviderSettingsStore()

    private let keychainService = Bundle.main.bundleIdentifier ?? "com.zizicici.doufu"

    private var dbPool: DatabasePool {
        DatabaseManager.shared.dbPool
    }

    init() {}

    // MARK: - App-level Default Model

    func loadDefaultModelSelection() -> ModelSelection? {
        guard let row = try? dbPool.read({ db in
            try DBAppModelSelection.fetchOne(db, key: "default")
        }) else {
            return nil
        }
        return ModelSelection.from(row)
    }

    func saveDefaultModelSelection(_ selection: ModelSelection) {
        let row = DBAppModelSelection(
            id: "default",
            providerID: selection.providerID,
            modelRecordID: selection.modelRecordID,
            extra: DBModelSelectionExtra.jsonString(from: selection),
            updatedAt: DatabaseTimestamp.toNanos(Date())
        )
        try? dbPool.write { db in
            try row.save(db)
        }
    }

    func clearDefaultModelSelection() {
        _ = try? dbPool.write { db in
            try DBAppModelSelection.deleteOne(db, key: "default")
        }
    }

    // MARK: - Provider CRUD

    func loadProviders() -> [LLMProviderRecord] {
        guard let result = try? dbPool.read({ db -> [LLMProviderRecord] in
            let dbProviders = try DBProvider.order(Column("updated_at").desc).fetchAll(db)
            return try dbProviders.map { dbProvider in
                let dbModels = try DBProviderModel
                    .filter(Column("provider_id") == dbProvider.id)
                    .order(Column("sort_order").asc)
                    .fetchAll(db)
                let kind = DBProvider.kindEnum(from: dbProvider.kind)
                let models = dbModels.map { $0.toLLMProviderModelRecord(providerKind: kind) }
                return dbProvider.toLLMProviderRecord(models: models)
            }
        }) else {
            return []
        }
        return result
    }

    func loadProvider(id: String) -> LLMProviderRecord? {
        try? dbPool.read { db in
            guard let dbProvider = try DBProvider.fetchOne(db, key: id) else { return nil }
            let dbModels = try DBProviderModel
                .filter(Column("provider_id") == id)
                .order(Column("sort_order").asc)
                .fetchAll(db)
            let kind = DBProvider.kindEnum(from: dbProvider.kind)
            let models = dbModels.map { $0.toLLMProviderModelRecord(providerKind: kind) }
            return dbProvider.toLLMProviderRecord(models: models)
        }
    }

    func availableModels(forProviderID providerID: String) -> [LLMProviderModelRecord] {
        loadProvider(id: providerID)?.availableModels ?? []
    }

    func modelRecord(providerID: String, modelID: String) -> LLMProviderModelRecord? {
        loadProvider(id: providerID)?.modelRecord(for: modelID)
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
            modelID: normalizedModelID,
            models: []
        )

        // Save credential first so a Keychain failure does not leave a
        // credential-less provider row in the database.
        try saveAPIKey(normalizedAPIKey, providerID: provider.id)
        try saveProviderToDB(provider)
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
            modelID: normalizedModelID,
            models: []
        )

        // Save credential first so a Keychain failure does not leave a
        // credential-less provider row in the database.
        let normalizedToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedToken.isEmpty {
            try saveOAuthBearerToken(normalizedToken, providerID: provider.id)
        }
        try saveProviderToDB(provider)
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

        guard let existingProvider = loadProvider(id: providerID) else {
            throw LLMProviderSettingsStoreError.providerNotFound
        }
        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: existingProvider.kind)
        let normalizedModelID = normalizeModelID(modelID, kind: existingProvider.kind)
        let updatedProvider = existingProvider.copying(
            authMode: .apiKey,
            updatedAt: Date(),
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: .some(nil),
            modelID: .some(normalizedModelID)
        )
        // Save new credential before updating the DB so a Keychain failure
        // does not leave the provider in an inconsistent authMode state.
        try saveAPIKey(normalizedAPIKey, providerID: providerID)
        try saveProviderToDB(updatedProvider)
        // Best-effort cleanup of the old credential slot.
        if existingProvider.authMode == .oauth {
            try? deleteOAuthBearerToken(providerID: providerID)
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

        guard let existingProvider = loadProvider(id: providerID) else {
            throw LLMProviderSettingsStoreError.providerNotFound
        }
        let normalizedBaseURL = try normalizeBaseURL(baseURLString, kind: existingProvider.kind)
        let normalizedModelID = normalizeModelID(modelID, kind: existingProvider.kind)
        let updatedProvider = existingProvider.copying(
            authMode: .oauth,
            updatedAt: Date(),
            label: normalizedLabel,
            baseURLString: normalizedBaseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: .some(chatGPTAccountID?.trimmingCharacters(in: .whitespacesAndNewlines)),
            modelID: .some(normalizedModelID)
        )
        // Save new credential before updating the DB so a Keychain failure
        // does not leave the provider in an inconsistent authMode state.
        try saveOAuthBearerToken(normalizedToken, providerID: providerID)
        try saveProviderToDB(updatedProvider)
        // Best-effort cleanup of the old credential slot.
        if existingProvider.authMode == .apiKey {
            try? deleteAPIKey(providerID: providerID)
        }
        return updatedProvider
    }

    @discardableResult
    func replaceOfficialModels(
        providerID: String,
        models: [LLMProviderModelRecord]
    ) throws -> LLMProviderRecord {
        guard let existingProvider = loadProvider(id: providerID) else {
            throw LLMProviderSettingsStoreError.providerNotFound
        }

        let customModels = existingProvider.models.filter { $0.source == .custom }
        let officialModels = models.map {
            LLMProviderModelRecord(
                id: $0.id,
                modelID: $0.modelID,
                displayName: $0.displayName,
                source: .official,
                capabilities: $0.capabilities
            )
        }
        let merged = mergeModels(customModels + officialModels)
        let updatedProvider = existingProvider.copying(
            updatedAt: Date(),
            models: merged
        )
        try saveProviderToDB(updatedProvider)
        return updatedProvider
    }

    @discardableResult
    func saveCustomModel(
        providerID: String,
        modelID: String,
        displayName: String?,
        capabilities: LLMProviderModelCapabilities,
        existingRecordID: String? = nil
    ) throws -> LLMProviderRecord {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else {
            throw LLMProviderSettingsStoreError.emptyModelID
        }

        guard let existingProvider = loadProvider(id: providerID) else {
            throw LLMProviderSettingsStoreError.providerNotFound
        }

        let normalizedRecordID = existingRecordID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let recordID = normalizedRecordID.isEmpty ? UUID().uuidString : normalizedRecordID
        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let autoDisplayName: String = {
            guard trimmedDisplayName.isEmpty else {
                return trimmedDisplayName
            }
            let duplicateCount = existingProvider.models.filter { model in
                guard model.source == .custom else {
                    return false
                }
                if !normalizedRecordID.isEmpty, model.normalizedID == normalizedRecordID.lowercased() {
                    return false
                }
                return model.normalizedModelID == normalizedModelID.lowercased()
            }.count
            guard duplicateCount > 0 else {
                return normalizedModelID
            }
            return normalizedModelID + " #\(duplicateCount + 1)"
        }()
        let customModel = LLMProviderModelRecord(
            id: recordID,
            modelID: normalizedModelID,
            displayName: autoDisplayName,
            source: .custom,
            capabilities: capabilities
        )
        let remainingModels = existingProvider.models.filter { model in
            guard !normalizedRecordID.isEmpty else {
                return true
            }
            return model.normalizedID != normalizedRecordID.lowercased()
        }
        let updatedProvider = existingProvider.copying(
            updatedAt: Date(),
            models: mergeModels(remainingModels + [customModel])
        )
        try saveProviderToDB(updatedProvider)
        return updatedProvider
    }

    func deleteProvider(id: String) throws {
        // FK cascade deletes llm_provider_model rows automatically
        try dbPool.write { db in
            try DBProvider.deleteOne(db, key: id)
        }
        // Best-effort cleanup of both Keychain slots.  A failure in one
        // should not prevent the other from being attempted.
        try? deleteAPIKey(providerID: id)
        try? deleteOAuthBearerToken(providerID: id)
    }

    // MARK: - Project-level Model Selection

    func loadProjectModelSelection(projectID: String) -> ModelSelection? {
        guard let row = try? dbPool.read({ db in
            try DBProjectModelSelection.fetchOne(db, key: projectID)
        }) else {
            return nil
        }
        return ModelSelection.from(row)
    }

    func saveProjectModelSelection(_ selection: ModelSelection?, projectID: String) {
        try? dbPool.write { db in
            if let selection {
                guard try projectExists(projectID: projectID, in: db) else {
                    assertionFailure("Attempted to save a project model selection for a missing project: \(projectID)")
                    return
                }

                let row = DBProjectModelSelection(
                    projectID: projectID,
                    providerID: selection.providerID,
                    modelRecordID: selection.modelRecordID,
                    extra: DBModelSelectionExtra.jsonString(from: selection),
                    updatedAt: DatabaseTimestamp.toNanos(Date())
                )
                try row.save(db)
            } else {
                try DBProjectModelSelection.deleteOne(db, key: projectID)
            }
        }
    }

    // MARK: - Thread-level Model Selection

    func loadThreadModelSelection(projectID: String, threadID: String) -> ModelSelection? {
        guard let row = try? dbPool.read({ db in
            try DBThreadModelSelection.fetchOne(db, key: ["project_id": projectID, "thread_id": threadID])
        }) else {
            return nil
        }
        return ModelSelection.from(row)
    }

    func saveThreadModelSelection(_ selection: ModelSelection?, projectID: String, threadID: String) {
        try? dbPool.write { db in
            if let selection {
                guard try projectExists(projectID: projectID, in: db) else {
                    assertionFailure("Attempted to save a thread model selection for a missing project: \(projectID)")
                    return
                }
                guard try threadExists(threadID: threadID, in: db) else {
                    assertionFailure("Attempted to save a thread model selection for a missing thread: \(threadID)")
                    return
                }

                let row = DBThreadModelSelection(
                    projectID: projectID,
                    threadID: threadID,
                    providerID: selection.providerID,
                    modelRecordID: selection.modelRecordID,
                    extra: DBModelSelectionExtra.jsonString(from: selection),
                    updatedAt: DatabaseTimestamp.toNanos(Date())
                )
                try row.save(db)
            } else {
                try DBThreadModelSelection.deleteOne(db, key: ["project_id": projectID, "thread_id": threadID])
            }
        }
    }

    func removeThreadModelSelection(projectID: String, threadID: String) {
        _ = try? dbPool.write { db in
            try DBThreadModelSelection.deleteOne(db, key: ["project_id": projectID, "thread_id": threadID])
        }
    }

    // MARK: - Keychain (unchanged)

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

    // MARK: - Private Helpers

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
        return candidate
    }

    private func mergeModels(_ models: [LLMProviderModelRecord]) -> [LLMProviderModelRecord] {
        var seenModelIDs: Set<String> = []
        var merged: [LLMProviderModelRecord] = []
        for model in models {
            let normalizedID = model.normalizedID
            guard !normalizedID.isEmpty else {
                continue
            }
            guard !seenModelIDs.contains(normalizedID) else {
                continue
            }
            seenModelIDs.insert(normalizedID)
            merged.append(model)
        }
        return merged
    }

    private func saveProviderToDB(_ provider: LLMProviderRecord) throws {
        let dbProvider = DBProvider.from(provider)
        try dbPool.write { db in
            try dbProvider.save(db)

            // Replace all models for this provider
            try DBProviderModel
                .filter(Column("provider_id") == provider.id)
                .deleteAll(db)

            for (index, model) in provider.models.enumerated() {
                let dbModel = DBProviderModel.from(model, providerID: provider.id, sortOrder: index)
                try dbModel.insert(db)
            }
        }
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

    private func projectExists(projectID: String, in db: Database) throws -> Bool {
        try DBProject.fetchOne(db, key: projectID) != nil
    }

    private func threadExists(threadID: String, in db: Database) throws -> Bool {
        try DBChatThread.fetchOne(db, key: threadID) != nil
    }
}
