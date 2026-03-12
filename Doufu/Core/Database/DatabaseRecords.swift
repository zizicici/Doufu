//
//  DatabaseRecords.swift
//  Doufu
//

import Foundation
import GRDB

// MARK: - Provider Extra JSON

struct DBProviderExtra: Codable {
    var chatGPTAccountID: String?
    var modelID: String?
}

struct DBModelSelectionExtra: Codable {
    var reasoningEffort: String?
    var thinkingEnabled: Bool?

    static func decode(from json: String?) -> DBModelSelectionExtra? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DBModelSelectionExtra.self, from: data)
    }

    static func jsonString(from selection: ModelSelection) -> String? {
        let extra = DBModelSelectionExtra(
            reasoningEffort: selection.reasoningEffort?.rawValue,
            thinkingEnabled: selection.thinkingEnabled
        )
        guard extra.reasoningEffort != nil || extra.thinkingEnabled != nil else { return nil }
        guard let data = try? JSONEncoder().encode(extra) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Model Capabilities JSON

struct DBModelCapabilities: Codable {
    var reasoningEfforts: [String]
    var thinkingSupported: Bool
    var thinkingCanDisable: Bool
    var structuredOutputSupported: Bool
    var maxOutputTokensOverride: Int?
    var contextWindowTokensOverride: Int?
}

// MARK: - DB Records

struct DBProject: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project"

    var id: String
    var createdAt: Int64
    var title: String
    var description: String
    var sortOrder: Int
    var updatedAt: Int64

    enum Columns: String, ColumnExpression {
        case id
        case createdAt = "created_at"
        case title, description
        case sortOrder = "sort_order"
        case updatedAt = "updated_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case title, description
        case sortOrder = "sort_order"
        case updatedAt = "updated_at"
    }
}

struct DBPermission: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "permission"

    var id: Int64?
    var projectID: String
    var agentToolPermission: Int

    enum Columns: String, ColumnExpression {
        case id
        case projectID = "project_id"
        case agentToolPermission = "agent_tool_permission"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case agentToolPermission = "agent_tool_permission"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // ToolPermissionMode mapping
    static let modeStandard = 0
    static let modeAutoApproveNonDestructive = 1
    static let modeFullAutoApprove = 2

    static func modeInt(from mode: ToolPermissionMode) -> Int {
        switch mode {
        case .standard: return modeStandard
        case .autoApproveNonDestructive: return modeAutoApproveNonDestructive
        case .fullAutoApprove: return modeFullAutoApprove
        }
    }

    static func modeEnum(from value: Int) -> ToolPermissionMode {
        switch value {
        case modeAutoApproveNonDestructive: return .autoApproveNonDestructive
        case modeFullAutoApprove: return .fullAutoApprove
        default: return .standard
        }
    }
}

struct DBProvider: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "llm_provider"

    var id: String
    var kind: Int
    var authMode: Int
    var label: String
    var baseURL: String
    var autoAppendV1: Bool
    var extra: String?
    var createdAt: Int64
    var updatedAt: Int64

    enum Columns: String, ColumnExpression {
        case id, kind, authMode = "auth_mode", label, baseURL = "base_url"
        case autoAppendV1 = "auto_append_v1", extra, createdAt = "created_at", updatedAt = "updated_at"
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case authMode = "auth_mode"
        case label
        case baseURL = "base_url"
        case autoAppendV1 = "auto_append_v1"
        case extra
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DBProviderModel: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "llm_provider_model"

    var id: String
    var providerID: String
    var modelID: String
    var displayName: String
    var source: Int
    var capabilities: String?
    var sortOrder: Int

    enum Columns: String, ColumnExpression {
        case id, providerID = "provider_id", modelID = "model_id"
        case displayName = "display_name", source, capabilities
        case sortOrder = "sort_order"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider_id"
        case modelID = "model_id"
        case displayName = "display_name"
        case source, capabilities
        case sortOrder = "sort_order"
    }
}

struct DBTokenUsage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "token_usage"

    var id: Int64?
    var providerID: String
    var modelRequestID: String
    var projectID: String?
    var inputTokens: Int64
    var outputTokens: Int64
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider_id"
        case modelRequestID = "model_request_id"
        case projectID = "project_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct DBAppModelSelection: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "app_model_selection"

    var id: String
    var providerID: String
    var modelRecordID: String
    var extra: String?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case providerID = "provider_id"
        case modelRecordID = "model_record_id"
        case extra
        case updatedAt = "updated_at"
    }
}

struct DBProjectModelSelection: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project_model_selection"

    var projectID: String
    var providerID: String
    var modelRecordID: String
    var extra: String?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case providerID = "provider_id"
        case modelRecordID = "model_record_id"
        case extra
        case updatedAt = "updated_at"
    }
}

struct DBThreadModelSelection: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread_model_selection"

    var projectID: String
    var threadID: String
    var providerID: String
    var modelRecordID: String
    var extra: String?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
        case threadID = "thread_id"
        case providerID = "provider_id"
        case modelRecordID = "model_record_id"
        case extra
        case updatedAt = "updated_at"
    }
}

// MARK: - Domain ↔ DB Mapping

extension DBProvider {
    static let kindOpenAICompatible = 0
    static let kindAnthropic = 1
    static let kindGoogleGemini = 2

    static let authModeAPIKey = 0
    static let authModeOAuth = 1

    static func kindInt(from kind: LLMProviderRecord.Kind) -> Int {
        switch kind {
        case .openAICompatible: return kindOpenAICompatible
        case .anthropic: return kindAnthropic
        case .googleGemini: return kindGoogleGemini
        }
    }

    static func kindEnum(from value: Int) -> LLMProviderRecord.Kind {
        switch value {
        case kindAnthropic: return .anthropic
        case kindGoogleGemini: return .googleGemini
        default: return .openAICompatible
        }
    }

    static func authModeInt(from mode: LLMProviderRecord.AuthMode) -> Int {
        switch mode {
        case .apiKey: return authModeAPIKey
        case .oauth: return authModeOAuth
        }
    }

    static func authModeEnum(from value: Int) -> LLMProviderRecord.AuthMode {
        switch value {
        case authModeOAuth: return .oauth
        default: return .apiKey
        }
    }

    static func from(_ record: LLMProviderRecord) -> DBProvider {
        let encoder = JSONEncoder()
        let extraJSON: String? = {
            let extra = DBProviderExtra(
                chatGPTAccountID: record.chatGPTAccountID,
                modelID: record.modelID
            )
            guard extra.chatGPTAccountID != nil || extra.modelID != nil else { return nil }
            guard let data = try? encoder.encode(extra) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        return DBProvider(
            id: record.id,
            kind: kindInt(from: record.kind),
            authMode: authModeInt(from: record.authMode),
            label: record.label,
            baseURL: record.baseURLString,
            autoAppendV1: record.autoAppendV1,
            extra: extraJSON,
            createdAt: DatabaseTimestamp.toNanos(record.createdAt),
            updatedAt: DatabaseTimestamp.toNanos(record.updatedAt)
        )
    }

    func toLLMProviderRecord(models: [LLMProviderModelRecord]) -> LLMProviderRecord {
        let parsedExtra: DBProviderExtra? = {
            guard let json = extra, let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DBProviderExtra.self, from: data)
        }()

        return LLMProviderRecord(
            id: id,
            kind: DBProvider.kindEnum(from: kind),
            authMode: DBProvider.authModeEnum(from: authMode),
            createdAt: DatabaseTimestamp.fromNanos(createdAt),
            updatedAt: DatabaseTimestamp.fromNanos(updatedAt),
            label: label,
            baseURLString: baseURL,
            autoAppendV1: autoAppendV1,
            chatGPTAccountID: parsedExtra?.chatGPTAccountID,
            modelID: parsedExtra?.modelID,
            models: models
        )
    }
}

extension DBProviderModel {
    static let sourceOfficial = 0
    static let sourceCustom = 1

    static func sourceInt(from source: LLMProviderModelRecord.Source) -> Int {
        switch source {
        case .official: return sourceOfficial
        case .custom: return sourceCustom
        }
    }

    static func sourceEnum(from value: Int) -> LLMProviderModelRecord.Source {
        switch value {
        case sourceCustom: return .custom
        default: return .official
        }
    }

    static func from(_ record: LLMProviderModelRecord, providerID: String, sortOrder: Int) -> DBProviderModel {
        let capJSON: String? = {
            guard let data = try? JSONEncoder().encode(DBModelCapabilities(
                reasoningEfforts: record.capabilities.reasoningEfforts.map(\.rawValue),
                thinkingSupported: record.capabilities.thinkingSupported,
                thinkingCanDisable: record.capabilities.thinkingCanDisable,
                structuredOutputSupported: record.capabilities.structuredOutputSupported,
                maxOutputTokensOverride: record.capabilities.maxOutputTokensOverride,
                contextWindowTokensOverride: record.capabilities.contextWindowTokensOverride
            )) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        return DBProviderModel(
            id: record.id,
            providerID: providerID,
            modelID: record.modelID,
            displayName: record.displayName,
            source: sourceInt(from: record.source),
            capabilities: capJSON,
            sortOrder: sortOrder
        )
    }

    func toLLMProviderModelRecord(providerKind: LLMProviderRecord.Kind) -> LLMProviderModelRecord {
        let caps: LLMProviderModelCapabilities = {
            guard let json = capabilities, let data = json.data(using: .utf8),
                  let dbCap = try? JSONDecoder().decode(DBModelCapabilities.self, from: data)
            else {
                return LLMProviderModelCapabilities.defaults(for: providerKind, modelID: modelID)
            }
            return LLMProviderModelCapabilities(
                reasoningEfforts: dbCap.reasoningEfforts.compactMap(ProjectChatService.ReasoningEffort.init(rawValue:)),
                thinkingSupported: dbCap.thinkingSupported,
                thinkingCanDisable: dbCap.thinkingCanDisable,
                structuredOutputSupported: dbCap.structuredOutputSupported,
                maxOutputTokensOverride: dbCap.maxOutputTokensOverride,
                contextWindowTokensOverride: dbCap.contextWindowTokensOverride
            )
        }()

        return LLMProviderModelRecord(
            id: id,
            modelID: modelID,
            displayName: displayName,
            source: DBProviderModel.sourceEnum(from: source),
            capabilities: caps
        )
    }
}

extension ModelSelection {
    static func from(_ db: DBAppModelSelection) -> ModelSelection {
        let extra = DBModelSelectionExtra.decode(from: db.extra)
        return ModelSelection(
            providerID: db.providerID,
            modelRecordID: db.modelRecordID,
            reasoningEffort: extra?.reasoningEffort.flatMap(ProjectChatService.ReasoningEffort.init(rawValue:)),
            thinkingEnabled: extra?.thinkingEnabled
        )
    }

    static func from(_ db: DBProjectModelSelection) -> ModelSelection {
        let extra = DBModelSelectionExtra.decode(from: db.extra)
        return ModelSelection(
            providerID: db.providerID,
            modelRecordID: db.modelRecordID,
            reasoningEffort: extra?.reasoningEffort.flatMap(ProjectChatService.ReasoningEffort.init(rawValue:)),
            thinkingEnabled: extra?.thinkingEnabled
        )
    }

    static func from(_ db: DBThreadModelSelection) -> ModelSelection {
        let extra = DBModelSelectionExtra.decode(from: db.extra)
        return ModelSelection(
            providerID: db.providerID,
            modelRecordID: db.modelRecordID,
            reasoningEffort: extra?.reasoningEffort.flatMap(ProjectChatService.ReasoningEffort.init(rawValue:)),
            thinkingEnabled: extra?.thinkingEnabled
        )
    }
}

// MARK: - Chat Records

struct DBChatThread: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread"

    var id: String
    var projectID: String
    var title: String
    var isCurrent: Bool
    var sortOrder: Int
    var currentVersion: Int
    var createdAt: Int64
    var updatedAt: Int64

    enum Columns: String, ColumnExpression {
        case id
        case projectID = "project_id"
        case title
        case isCurrent = "is_current"
        case sortOrder = "sort_order"
        case currentVersion = "current_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case title
        case isCurrent = "is_current"
        case sortOrder = "sort_order"
        case currentVersion = "current_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct DBAssistant: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "assistant"

    var id: String
    var threadID: String
    var label: String
    var sortOrder: Int
    var createdAt: Int64

    enum Columns: String, ColumnExpression {
        case id
        case threadID = "thread_id"
        case label
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case label
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}

struct DBChatMessage: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"

    var id: Int64?
    var threadID: String
    var assistantID: String?
    var messageType: Int
    var content: String
    var sortOrder: Int
    var createdAt: Int64
    var tokenUsageID: Int64?
    var summary: String?
    var startedAt: Int64?
    var finishedAt: Int64?

    enum Columns: String, ColumnExpression {
        case id
        case threadID = "thread_id"
        case assistantID = "assistant_id"
        case messageType = "message_type"
        case content
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case tokenUsageID = "token_usage_id"
        case summary
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case threadID = "thread_id"
        case assistantID = "assistant_id"
        case messageType = "message_type"
        case content
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case tokenUsageID = "token_usage_id"
        case summary
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // Message type constants
    static let typeSystem = 0
    static let typeNormal = 1
    static let typeProgress = 2
    static let typeTool = 3
}

struct DBSessionMemory: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_memory"

    var threadID: String
    var objective: String
    var constraints: String?
    var changedFiles: String?
    var todoItems: String?

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case objective
        case constraints
        case changedFiles = "changed_files"
        case todoItems = "todo_items"
    }
}

// MARK: - Chat Domain ↔ DB Mapping

extension DBChatThread {
    static func from(_ record: ProjectChatThreadRecord, projectID: String, isCurrent: Bool, sortOrder: Int) -> DBChatThread {
        DBChatThread(
            id: record.id,
            projectID: projectID,
            title: record.title,
            isCurrent: isCurrent,
            sortOrder: sortOrder,
            currentVersion: record.currentVersion,
            createdAt: DatabaseTimestamp.toNanos(record.createdAt),
            updatedAt: DatabaseTimestamp.toNanos(record.updatedAt)
        )
    }

    func toThreadRecord() -> ProjectChatThreadRecord {
        ProjectChatThreadRecord(
            id: id,
            title: title,
            createdAt: DatabaseTimestamp.fromNanos(createdAt),
            updatedAt: DatabaseTimestamp.fromNanos(updatedAt),
            currentVersion: currentVersion
        )
    }
}

extension DBChatMessage {
    static func from(_ msg: ChatMessage, threadID: String, assistantID: String?, sortOrder: Int) -> DBChatMessage {
        let messageType: Int = {
            switch msg.role {
            case .system: return typeSystem
            case .tool: return typeTool
            case .user, .assistant:
                return msg.isProgress ? typeProgress : typeNormal
            }
        }()

        return DBChatMessage(
            id: nil,
            threadID: threadID,
            assistantID: msg.role == .assistant ? assistantID : nil,
            messageType: messageType,
            content: msg.content,
            sortOrder: sortOrder,
            createdAt: DatabaseTimestamp.toNanos(msg.createdAt),
            tokenUsageID: msg.requestTokenUsage?.tokenUsageID,
            summary: msg.summary,
            startedAt: DatabaseTimestamp.toNanos(msg.startedAt),
            finishedAt: msg.finishedAt.map(DatabaseTimestamp.toNanos)
        )
    }

    func toChatMessage(tokenUsage: DBTokenUsage?) -> ChatMessage? {
        let role: ChatMessage.Role
        if messageType == DBChatMessage.typeSystem {
            role = .system
        } else if messageType == DBChatMessage.typeTool {
            role = .tool
        } else if assistantID != nil {
            role = .assistant
        } else {
            role = .user
        }

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let createdAtDate = DatabaseTimestamp.fromNanos(createdAt)
        let startedAtDate = startedAt.map(DatabaseTimestamp.fromNanos) ?? createdAtDate
        let isProgress = messageType == DBChatMessage.typeProgress

        let finishedAtDate: Date? = {
            if let finishedAt {
                return DatabaseTimestamp.fromNanos(finishedAt)
            }
            if isProgress { return startedAtDate }
            return createdAtDate
        }()

        let requestTokenUsage: ProjectChatService.RequestTokenUsage? = {
            guard let tokenUsage else { return nil }
            let input = max(0, tokenUsage.inputTokens)
            let output = max(0, tokenUsage.outputTokens)
            guard input > 0 || output > 0 else { return nil }
            return ProjectChatService.RequestTokenUsage(
                tokenUsageID: tokenUsageID,
                inputTokens: input,
                outputTokens: output
            )
        }()

        return ChatMessage(
            role: role,
            content: text,
            createdAt: createdAtDate,
            startedAt: startedAtDate,
            finishedAt: finishedAtDate,
            isProgress: isProgress,
            requestTokenUsage: requestTokenUsage,
            summary: summary
        )
    }
}

extension DBSessionMemory {
    static func from(_ memory: SessionMemory, threadID: String) -> DBSessionMemory {
        let encoder = JSONEncoder()
        return DBSessionMemory(
            threadID: threadID,
            objective: memory.objective,
            constraints: {
                guard !memory.constraints.isEmpty,
                      let data = try? encoder.encode(memory.constraints) else { return nil }
                return String(data: data, encoding: .utf8)
            }(),
            changedFiles: {
                guard !memory.changedFiles.isEmpty,
                      let data = try? encoder.encode(memory.changedFiles) else { return nil }
                return String(data: data, encoding: .utf8)
            }(),
            todoItems: {
                guard !memory.todoItems.isEmpty,
                      let data = try? encoder.encode(memory.todoItems) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
        )
    }

    func toSessionMemory() -> SessionMemory {
        let decoder = JSONDecoder()
        return SessionMemory(
            objective: objective,
            constraints: constraints.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? [],
            changedFiles: changedFiles.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? [],
            todoItems: todoItems.flatMap { try? decoder.decode([String].self, from: Data($0.utf8)) } ?? []
        )
    }
}
