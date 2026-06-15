//
//  OpenAICodexBackendHeaders.swift
//  Doufu
//
//  Created by Codex on 2026/06/15.
//

import Foundation

enum OpenAICodexBackendHeaders {
    static let originator = "codex_cli_rs"
    static let runtimeClientVersion = "0.137.0"
    static let modelDiscoveryClientVersion = "99.99.99"

    static func apply(to request: inout URLRequest, accountID: String?) {
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue(runtimeClientVersion, forHTTPHeaderField: "version")
        request.setValue(userAgentString(), forHTTPHeaderField: "User-Agent")

        if let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        }
    }

    static func userAgentString() -> String {
        "\(originator)/\(runtimeClientVersion) (\(platformDescription)) doufu"
    }

    private static var platformDescription: String {
        let osName: String
        #if os(iOS)
        osName = "iOS"
        #elseif os(macOS)
        osName = "macOS"
        #else
        osName = "Apple"
        #endif

        return "\(osName) \(ProcessInfo.processInfo.operatingSystemVersionString); \(architectureDescription)"
    }

    private static var architectureDescription: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(arm)
        return "arm"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }
}
