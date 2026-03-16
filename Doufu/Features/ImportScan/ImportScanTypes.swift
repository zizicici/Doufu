//
//  ImportScanTypes.swift
//  Doufu
//

import Foundation

// MARK: - Section IDs

nonisolated enum ImportScanSectionID: Hashable, Sendable {
    case archiveInfo
    case projectInfo
    case scanProgress
    case findings(FindingCategory)
    case llmStatus
}

// MARK: - Item IDs

nonisolated enum ImportScanItemID: Hashable, Sendable {
    case archiveName(String)
    case archiveSize(String)
    case archiveFiles(Int)
    case appDataWarning

    case staticScanning

    case finding(id: String, severity: String, category: String)
    case noFindings

    case llmStatus(LLMPhase)
    case llmFinding(id: String, severity: String)
    case llmSummary(String)
    case blocked

    nonisolated enum LLMPhase: Hashable, Sendable {
        case running
        case done
        case failed
        case malicious
    }
}
