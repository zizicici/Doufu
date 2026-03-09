//
//  LLMModelRegistry.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import Foundation

struct ResolvedModelProfile {
    let providerKind: LLMProviderRecord.Kind
    let modelID: String

    // Model capabilities
    let reasoningEfforts: [ProjectChatService.ReasoningEffort]
    let thinkingSupported: Bool
    let thinkingCanDisable: Bool
    let structuredOutputSupported: Bool

    // Token budgets
    let maxOutputTokens: Int
    let contextWindowTokens: Int
}

struct LLMModelRegistry {

    struct ModelEntry {
        let reasoningEfforts: [ProjectChatService.ReasoningEffort]
        let thinkingSupported: Bool
        let thinkingCanDisable: Bool
        let structuredOutputSupported: Bool
        let maxOutputTokens: Int
        let contextWindowTokens: Int
    }

    // MARK: - Resolve

    /// Single entry point: produces a fully-resolved, non-optional profile
    /// that every downstream consumer (providers, configuration, UI) should use.
    ///
    /// Resolution order per field:
    ///  1. User-edited custom model record (highest priority)
    ///  2. Built-in registry (precise known models)
    ///  3. Discovery/official model record
    ///  4. Conservative family fallback
    static func resolve(
        providerKind: LLMProviderRecord.Kind,
        modelID: String,
        modelRecord: LLMProviderModelRecord?
    ) -> ResolvedModelProfile {
        let builtIn = lookup(providerKind: providerKind, modelID: modelID)
        let fallback = conservativeFallback(providerKind: providerKind)

        // Capabilities: custom record > built-in > discovery record > fallback
        let capabilities: LLMProviderModelCapabilities
        if let record = modelRecord, record.source == .custom {
            capabilities = record.capabilities
        } else if let builtIn {
            capabilities = LLMProviderModelCapabilities(
                reasoningEfforts: builtIn.reasoningEfforts,
                thinkingSupported: builtIn.thinkingSupported,
                thinkingCanDisable: builtIn.thinkingCanDisable,
                structuredOutputSupported: builtIn.structuredOutputSupported
            )
        } else if let record = modelRecord {
            capabilities = record.capabilities
        } else {
            capabilities = LLMProviderModelCapabilities(
                reasoningEfforts: fallback.reasoningEfforts,
                thinkingSupported: fallback.thinkingSupported,
                thinkingCanDisable: fallback.thinkingCanDisable,
                structuredOutputSupported: fallback.structuredOutputSupported
            )
        }

        // Token limits: user override > built-in > discovery-inferred > fallback
        let maxOutput: Int
        if let override = modelRecord?.capabilities.maxOutputTokensOverride, override > 0 {
            maxOutput = override
        } else {
            maxOutput = builtIn?.maxOutputTokens ?? fallback.maxOutputTokens
        }

        let contextWindow: Int
        if let override = modelRecord?.capabilities.contextWindowTokensOverride, override > 0 {
            contextWindow = override
        } else {
            contextWindow = builtIn?.contextWindowTokens ?? fallback.contextWindowTokens
        }

        return ResolvedModelProfile(
            providerKind: providerKind,
            modelID: modelID,
            reasoningEfforts: capabilities.reasoningEfforts,
            thinkingSupported: capabilities.thinkingSupported,
            thinkingCanDisable: capabilities.thinkingCanDisable,
            structuredOutputSupported: capabilities.structuredOutputSupported,
            maxOutputTokens: maxOutput,
            contextWindowTokens: contextWindow
        )
    }

    // MARK: - Built-in Registry

    static func lookup(
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> ModelEntry? {
        let key = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let registry: [String: ModelEntry]
        switch providerKind {
        case .openAICompatible: registry = openAIRegistry
        case .anthropic:        registry = anthropicRegistry
        case .googleGemini:     registry = geminiRegistry
        }

        // Exact match first.
        if let entry = registry[key] {
            return entry
        }

        // Prefix match: handles dated model IDs like "claude-sonnet-4-5-20250514"
        // or "gemini-2.5-pro-preview-0506" matching their base entries.
        // Pick the longest matching prefix to avoid e.g. "gpt-4" matching "gpt-4o".
        var bestMatch: (key: String, entry: ModelEntry)?
        for (registryKey, entry) in registry {
            guard key.hasPrefix(registryKey),
                  key.count > registryKey.count,
                  // Ensure the character after the prefix is a separator (-, .)
                  // to avoid partial matches like "gpt-4" matching "gpt-4o".
                  let separator = key[key.index(key.startIndex, offsetBy: registryKey.count)...].first,
                  separator == "-" || separator == "." || separator == ":"
            else { continue }
            if bestMatch == nil || registryKey.count > bestMatch!.key.count {
                bestMatch = (registryKey, entry)
            }
        }
        return bestMatch?.entry
    }

    // MARK: - Conservative Fallback

    static func conservativeFallback(
        providerKind: LLMProviderRecord.Kind
    ) -> ModelEntry {
        switch providerKind {
        case .openAICompatible:
            return ModelEntry(
                reasoningEfforts: [],
                thinkingSupported: false,
                thinkingCanDisable: false,
                structuredOutputSupported: false,
                maxOutputTokens: 16_384,
                contextWindowTokens: 128_000
            )
        case .anthropic:
            // Conservative for third-party Anthropic-compatible endpoints.
            // Official models get precise values from the registry above.
            return ModelEntry(
                reasoningEfforts: [],
                thinkingSupported: true,
                thinkingCanDisable: true,
                structuredOutputSupported: true,
                maxOutputTokens: 8_192,
                contextWindowTokens: 200_000
            )
        case .googleGemini:
            return ModelEntry(
                reasoningEfforts: [],
                thinkingSupported: false,
                thinkingCanDisable: false,
                structuredOutputSupported: true,
                maxOutputTokens: 16_384,
                contextWindowTokens: 1_048_576
            )
        }
    }

    // MARK: - OpenAI Registry

    private static let openAIRegistry: [String: ModelEntry] = [
        // GPT-5 family
        "gpt-5.4-pro": ModelEntry(
            reasoningEfforts: [.medium, .high, .xhigh],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 128_000, contextWindowTokens: 1_050_000
        ),
        "gpt-5.4": ModelEntry(
            reasoningEfforts: [.low, .medium, .high, .xhigh],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 128_000, contextWindowTokens: 1_050_000
        ),
        "gpt-5.3-codex": ModelEntry(
            reasoningEfforts: [.medium, .high, .xhigh],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 128_000, contextWindowTokens: 400_000
        ),
        "gpt-5-mini": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 128_000, contextWindowTokens: 400_000
        ),
        // GPT-4.1 family
        "gpt-4.1": ModelEntry(
            reasoningEfforts: [.low, .medium, .high, .xhigh],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 32_768, contextWindowTokens: 1_047_576
        ),
        "gpt-4.1-mini": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 32_768, contextWindowTokens: 1_047_576
        ),
        "gpt-4.1-nano": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 32_768, contextWindowTokens: 1_047_576
        ),
        // o-series
        "o3": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 100_000, contextWindowTokens: 200_000
        ),
        "o4-mini": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 100_000, contextWindowTokens: 200_000
        ),
        // GPT-4o
        "gpt-4o": ModelEntry(
            reasoningEfforts: [.low, .medium, .high, .xhigh],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 16_384, contextWindowTokens: 128_000
        ),
        "gpt-4o-mini": ModelEntry(
            reasoningEfforts: [.low, .medium, .high],
            thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 16_384, contextWindowTokens: 128_000
        ),
    ]

    // MARK: - Anthropic Registry

    private static let anthropicRegistry: [String: ModelEntry] = [
        "claude-opus-4-6": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 128_000, contextWindowTokens: 200_000
        ),
        "claude-opus-4-5": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 64_000, contextWindowTokens: 200_000
        ),
        "claude-sonnet-4-6": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 64_000, contextWindowTokens: 200_000
        ),
        "claude-sonnet-4-5": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 64_000, contextWindowTokens: 200_000
        ),
        "claude-haiku-4-5": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 64_000, contextWindowTokens: 200_000
        ),
    ]

    // MARK: - Gemini Registry

    private static let geminiRegistry: [String: ModelEntry] = [
        "gemini-2.5-pro": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 65_536, contextWindowTokens: 1_048_576
        ),
        "gemini-2.5-flash": ModelEntry(
            reasoningEfforts: [], thinkingSupported: true, thinkingCanDisable: true,
            structuredOutputSupported: true,
            maxOutputTokens: 65_536, contextWindowTokens: 1_048_576
        ),
        "gemini-2.0-flash": ModelEntry(
            reasoningEfforts: [], thinkingSupported: false, thinkingCanDisable: false,
            structuredOutputSupported: true,
            maxOutputTokens: 8_192, contextWindowTokens: 1_048_576
        ),
    ]
}
