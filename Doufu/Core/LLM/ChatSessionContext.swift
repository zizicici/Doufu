//
//  ChatSessionContext.swift
//  Doufu
//
//  Created by Claude on 2026/03/10.
//

import Foundation

/// Separates the two concerns previously merged in `projectURL`:
/// - `projectID`: storage routing key for chat data
/// - `projectURL`: tool execution context (file reads, git, AGENTS.md) — points to App/
/// - `projectRootURL`: the project container (Projects/{uuid}/) — for preview images, etc.
struct ChatSessionContext {
    /// Storage key used by `ChatDataStore` to route chat data.
    let projectID: String
    /// File-system root for tool execution (read/write files, git, AGENTS.md).
    /// Points to `Projects/{uuid}/App/`.
    let projectURL: URL
    /// The project container directory (`Projects/{uuid}/`).
    /// Used for preview images and other project-level resources.
    let projectRootURL: URL
    /// Human-readable name for display (PiP, navigation, etc.).
    let projectName: String
}
