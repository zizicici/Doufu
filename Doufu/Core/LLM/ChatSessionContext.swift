//
//  ChatSessionContext.swift
//  Doufu
//
//  Created by Claude on 2026/03/10.
//

import Foundation

/// Separates the two concerns previously merged in `projectURL`:
/// - `projectID`: storage routing key for chat data
/// - `projectURL`: tool execution context (file reads, git, AGENTS.md)
struct ChatSessionContext {
    /// Storage key used by `ChatDataStore` to route chat data.
    let projectID: String
    /// File-system root for tool execution (read/write files, git, AGENTS.md).
    let projectURL: URL
    /// Human-readable name for display (PiP, navigation, etc.).
    let projectName: String
}
