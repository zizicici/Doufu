//
//  SessionMemory.swift
//  Doufu
//

import Foundation

struct SessionMemory: Codable, Equatable {
    var objective: String
    var constraints: [String]
    var changedFiles: [String]
    var todoItems: [String]

    static let empty = SessionMemory(
        objective: "",
        constraints: [],
        changedFiles: [],
        todoItems: []
    )
}
