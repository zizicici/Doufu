//
//  CapabilityActivityLogTypes.swift
//  Doufu
//

nonisolated enum ActivityLogSectionID: Hashable, Sendable {
    case date(String)
    case empty
}

nonisolated enum ActivityLogItemID: Hashable, Sendable {
    case activity(id: Int64)
    case empty
}

enum ActivityLogFilter {
    case project(id: String)
    case capability(type: CapabilityType)
}
