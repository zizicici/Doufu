//
//  ToolPermissionPickerTypes.swift
//  Doufu
//

nonisolated enum ToolPermissionPickerSectionID: Hashable, Sendable {
    case options
}

nonisolated enum ToolPermissionPickerItemID: Hashable, Sendable {
    case useDefault
    case mode(String) // ToolPermissionMode.rawValue
}
