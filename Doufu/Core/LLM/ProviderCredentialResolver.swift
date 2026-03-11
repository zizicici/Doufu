//
//  ProviderCredentialResolver.swift
//  Doufu
//

import Foundation

struct ProviderCredentialResolver {

    static func resolveAvailableCredentials(
        providerStore: LLMProviderSettingsStore
    ) -> [ProjectChatService.ProviderCredential] {
        providerStore.loadProviders().compactMap {
            buildCredential(for: $0, providerStore: providerStore)
        }
    }

    static func buildCredential(
        for provider: LLMProviderRecord,
        providerStore: LLMProviderSettingsStore
    ) -> ProjectChatService.ProviderCredential? {
        guard let baseURL = URL(string: provider.effectiveBaseURLString) else {
            return nil
        }

        let token: String
        do {
            token = try providerStore.loadBearerToken(for: provider)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            print("[Doufu ProviderCredentialResolver] failed to load token for provider=\(provider.id) error=\(error.localizedDescription)")
            return nil
        }

        guard !token.isEmpty else {
            return nil
        }

        return ProjectChatService.ProviderCredential(
            providerID: provider.id,
            providerLabel: provider.label,
            providerKind: provider.kind,
            authMode: provider.authMode,
            modelID: "",
            baseURL: baseURL,
            bearerToken: token,
            chatGPTAccountID: provider.chatGPTAccountID ?? extractChatGPTAccountID(fromJWT: token),
            profile: LLMModelRegistry.resolve(providerKind: provider.kind, modelID: "", modelRecord: nil)
        )
    }

    static func extractChatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payloadData = decodeBase64URL(String(parts[1])) else { return nil }
        guard let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            return nil
        }

        if let authClaims = payloadObject["https://api.openai.com/auth"] as? [String: Any],
           let accountID = normalizedString(from: authClaims["chatgpt_account_id"] ?? authClaims["account_id"]) {
            return accountID
        }

        return normalizedString(from: payloadObject["chatgpt_account_id"] ?? payloadObject["account_id"])
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        if paddingLength > 0 {
            base64.append(String(repeating: "=", count: paddingLength))
        }
        return Data(base64Encoded: base64)
    }

    private static func normalizedString(from value: Any?) -> String? {
        guard let rawValue = value as? String else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
