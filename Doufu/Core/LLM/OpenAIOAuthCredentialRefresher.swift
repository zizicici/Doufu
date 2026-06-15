//
//  OpenAIOAuthCredentialRefresher.swift
//  Doufu
//
//  Created by Codex on 2026/06/15.
//

import Foundation

enum OpenAIOAuthCredentialRefresher {
    static func shouldRefresh(
        providerKind: LLMProviderRecord.Kind,
        authMode: LLMProviderRecord.AuthMode,
        statusCode: Int? = nil,
        responseBodyData: Data? = nil,
        errorMessage: String? = nil,
        alreadyRefreshed: Bool
    ) -> Bool {
        guard !alreadyRefreshed,
              authMode == .oauth,
              providerKind == .openAIResponses
        else {
            return false
        }

        let parsedMessage = errorMessage
            ?? responseBodyData.flatMap { LLMProviderHelpers.parseErrorMessage(from: $0) }
            ?? ""
        let message = parsedMessage.lowercased()
        if message.contains("provided authentication token is expired") {
            return true
        }
        if message.contains("token") && message.contains("expired") {
            return true
        }
        if statusCode == 401, message.isEmpty {
            return true
        }
        if (statusCode == 401 || statusCode == 403),
           message.contains("authentication"),
           message.contains("token") {
            return true
        }
        return false
    }

    static func refreshedCredential(
        from credential: ProjectChatService.ProviderCredential,
        providerStore: LLMProviderSettingsStore = .shared
    ) async throws -> ProjectChatService.ProviderCredential? {
        guard let provider = providerStore.loadProvider(id: credential.providerID) else {
            return nil
        }
        guard let refreshed = try await refreshedProvider(for: provider, providerStore: providerStore) else {
            return nil
        }
        guard let baseURL = URL(string: refreshed.provider.effectiveBaseURLString) else {
            return nil
        }

        let refreshedAccountID = refreshed.provider.chatGPTAccountID
            ?? ProviderCredentialResolver.extractChatGPTAccountID(fromJWT: refreshed.bearerToken)

        return ProjectChatService.ProviderCredential(
            providerID: credential.providerID,
            providerLabel: credential.providerLabel,
            providerKind: credential.providerKind,
            authMode: .oauth,
            modelID: credential.modelID,
            baseURL: baseURL,
            bearerToken: refreshed.bearerToken,
            chatGPTAccountID: refreshedAccountID,
            profile: credential.profile
        )
    }

    static func refreshedProvider(
        for provider: LLMProviderRecord,
        providerStore: LLMProviderSettingsStore = .shared
    ) async throws -> (provider: LLMProviderRecord, bearerToken: String)? {
        try await OpenAIOAuthRefreshCoordinator.shared.refreshedProvider(
            for: provider,
            providerStore: providerStore
        )
    }

    fileprivate static func performRefresh(
        for provider: LLMProviderRecord,
        providerStore: LLMProviderSettingsStore
    ) async throws -> (provider: LLMProviderRecord, bearerToken: String)? {
        guard provider.authMode == .oauth,
              provider.kind == .openAIResponses
        else {
            return nil
        }

        let loadedRefreshToken = try providerStore.loadOAuthRefreshToken(forProviderID: provider.id)
        guard
            let storedRefreshToken = loadedRefreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            !storedRefreshToken.isEmpty
        else {
            print("[Doufu OpenAI OAuth] refresh skipped providerID=\(provider.id) reason=missing_refresh_token")
            return nil
        }

        print("[Doufu OpenAI OAuth] refresh started providerID=\(provider.id) baseURL=\(provider.effectiveBaseURLString)")
        let refreshed = try await OpenAIOAuthService().refreshSignIn(refreshToken: storedRefreshToken)
        let updatedProvider = try providerStore.updateOpenAIOAuthCredential(
            providerID: provider.id,
            baseURLString: refreshed.baseURLString,
            autoAppendV1: refreshed.autoAppendV1,
            bearerToken: refreshed.bearerToken,
            refreshToken: refreshed.refreshToken,
            chatGPTAccountID: refreshed.chatGPTAccountID
        )
        print("[Doufu OpenAI OAuth] refresh stored providerID=\(provider.id) baseURL=\(updatedProvider.effectiveBaseURLString) bearerTokenLength=\(refreshed.bearerToken.count) hasRefreshToken=\(!refreshed.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        return (updatedProvider, refreshed.bearerToken)
    }
}

private actor OpenAIOAuthRefreshCoordinator {
    static let shared = OpenAIOAuthRefreshCoordinator()

    private var tasks: [String: Task<(provider: LLMProviderRecord, bearerToken: String)?, Error>] = [:]

    func refreshedProvider(
        for provider: LLMProviderRecord,
        providerStore: LLMProviderSettingsStore
    ) async throws -> (provider: LLMProviderRecord, bearerToken: String)? {
        let key = provider.id
        if let existing = tasks[key] {
            print("[Doufu OpenAI OAuth] refresh joined providerID=\(provider.id)")
            return try await existing.value
        }

        let task = Task {
            try await OpenAIOAuthCredentialRefresher.performRefresh(
                for: provider,
                providerStore: providerStore
            )
        }
        tasks[key] = task

        do {
            let refreshed = try await task.value
            tasks[key] = nil
            return refreshed
        } catch {
            tasks[key] = nil
            throw error
        }
    }
}
