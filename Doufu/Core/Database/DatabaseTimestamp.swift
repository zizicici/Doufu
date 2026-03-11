//
//  DatabaseTimestamp.swift
//  Doufu
//

import Foundation

enum DatabaseTimestamp {
    static func toNanos(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000_000)
    }

    static func fromNanos(_ nanos: Int64) -> Date {
        Date(timeIntervalSince1970: Double(nanos) / 1_000_000_000)
    }
}
