//
//  DatabaseLegacyMigration.swift
//  Doufu
//

import Foundation
import GRDB

enum DatabaseLegacyMigration {

    static func register(_ migrator: inout DatabaseMigrator) {
        // No legacy migrations needed — fresh install only.
    }

    static func registerV3(_ migrator: inout DatabaseMigrator) {
        // No legacy migrations needed — fresh install only.
    }
}
