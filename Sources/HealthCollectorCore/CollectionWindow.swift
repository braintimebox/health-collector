import Foundation

/// How far back a manual export looks. Separate from the cursor on purpose: the
/// cursor decides what has *not been seen yet*, and a period decides what the user
/// wants to look at right now.
public enum CollectionPeriod: String, CaseIterable, Codable {
    case day
    case week
    case month
    case quarter
    case all
}

/// A half-open window `[from, to]` for a read that must not disturb the cursor.
public struct CollectionWindow: Equatable {
    /// `nil` means "the whole history" — the same meaning a nil cursor has.
    public let from: Date?
    public let to: Date

    public init(from: Date?, to: Date) {
        self.from = from
        self.to = to
    }

    public static func make(
        period: CollectionPeriod,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> CollectionWindow {
        switch period {
        case .all:
            return CollectionWindow(from: nil, to: now)
        case .day:
            return CollectionWindow(from: calendar.date(byAdding: .day, value: -1, to: now) ?? now, to: now)
        case .week:
            return CollectionWindow(from: calendar.date(byAdding: .day, value: -7, to: now) ?? now, to: now)
        case .month:
            return CollectionWindow(from: calendar.date(byAdding: .day, value: -30, to: now) ?? now, to: now)
        case .quarter:
            return CollectionWindow(from: calendar.date(byAdding: .day, value: -90, to: now) ?? now, to: now)
        }
    }

    public var isFullHistory: Bool { from == nil }
}
