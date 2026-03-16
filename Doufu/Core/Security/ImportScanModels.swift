//
//  ImportScanModels.swift
//  Doufu
//

import Foundation

// MARK: - Risk Level

enum ImportRiskLevel: Int, Codable, Sendable, Comparable {
    case low = 0
    case medium = 1
    case high = 2
    case critical = 3

    static func < (lhs: ImportRiskLevel, rhs: ImportRiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .low: return String(localized: "scan.risk.low", defaultValue: "Low Risk")
        case .medium: return String(localized: "scan.risk.medium", defaultValue: "Medium Risk")
        case .high: return String(localized: "scan.risk.high", defaultValue: "High Risk")
        case .critical: return String(localized: "scan.risk.critical", defaultValue: "Critical Risk")
        }
    }

    var sfSymbolName: String {
        switch self {
        case .low: return "checkmark.shield.fill"
        case .medium: return "exclamationmark.shield.fill"
        case .high: return "xmark.shield.fill"
        case .critical: return "xmark.shield.fill"
        }
    }
}

// MARK: - Finding Severity

enum FindingSeverity: String, Codable, Sendable, Comparable {
    case info
    case low
    case medium
    case high

    nonisolated private var sortOrder: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        case .info: return 0
        }
    }

    nonisolated static func < (lhs: FindingSeverity, rhs: FindingSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Finding Category

enum FindingCategory: String, Codable, Sendable, CaseIterable {
    case binaryFiles
    case externalReferences
    case doufuAPI
    case network
    case dataExfiltration
    case execution
    case obfuscation

    var displayName: String {
        switch self {
        case .binaryFiles: return String(localized: "scan.category.binary_files", defaultValue: "Non-Auditable Binary Files")
        case .externalReferences: return String(localized: "scan.category.external_refs", defaultValue: "External References")
        case .doufuAPI: return String(localized: "scan.category.doufu_api", defaultValue: "Doufu API Usage")
        case .network: return String(localized: "scan.category.network", defaultValue: "Network Access")
        case .dataExfiltration: return String(localized: "scan.category.data_exfiltration", defaultValue: "Data Exfiltration")
        case .execution: return String(localized: "scan.category.execution", defaultValue: "Dynamic Execution")
        case .obfuscation: return String(localized: "scan.category.obfuscation", defaultValue: "Obfuscation")
        }
    }

    var sfSymbolName: String {
        switch self {
        case .binaryFiles: return "doc.questionmark"
        case .externalReferences: return "link"
        case .doufuAPI: return "lock.shield"
        case .network: return "network"
        case .dataExfiltration: return "arrow.up.doc"
        case .execution: return "terminal"
        case .obfuscation: return "eye.slash"
        }
    }
}

// MARK: - Static Finding

struct StaticFinding: Codable, Sendable, Hashable {
    let id: String
    let category: FindingCategory
    let severity: FindingSeverity
    let description: String
    let locations: [Location]

    struct Location: Codable, Sendable, Hashable {
        let filePath: String
        let lineNumber: Int
    }
}

// MARK: - LLM Finding

struct LLMFinding: Codable, Sendable, Hashable {
    let id: String
    let severity: FindingSeverity
    let description: String
    let filePath: String?
    let recommendation: String?
}

