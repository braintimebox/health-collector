import Foundation

/// Sleep stages as they reach the wire.
///
/// Why this type exists: a sleep stage is not a property of a night, it is a
/// property of a segment. Sending every segment as `sleep_analysis` with only a
/// duration makes the rows indistinguishable — "6.2 hours of something" — and any
/// recovery analysis built on it silently averages deep, REM and awake time
/// together. The stage therefore travels in the type, not in a free-form field,
/// because the server validates a type/unit pair and nothing else.
///
/// Raw values are the documented `HKCategoryValueSleepAnalysis` constants. The
/// mapping is pure and lives here, in the core, so it is testable on Linux; the
/// HealthKit call site only reads `value` and calls `wireType`.
public enum SleepStage: String, CaseIterable, Equatable, Sendable {
    case inBed
    case asleep
    case awake
    case core
    case deep
    case rem
    case unspecified

    /// `HKCategoryValueSleepAnalysis` raw values, in Apple's documented order.
    public static let categoryValues: [Int: SleepStage] = [
        0: .inBed,
        1: .asleep,
        2: .awake,
        3: .core,
        4: .deep,
        5: .rem,
        6: .unspecified,
    ]

    public static func from(categoryValue raw: Int) -> SleepStage {
        // An unknown value is not an error: Apple may add a stage, and dropping
        // the row would lose sleep time. It is labelled as unspecified instead.
        categoryValues[raw] ?? .unspecified
    }

    public var wireType: String {
        switch self {
        case .inBed: return "sleep_in_bed"
        case .asleep: return "sleep_asleep"
        case .awake: return "sleep_awake"
        case .core: return "sleep_core"
        case .deep: return "sleep_deep"
        case .rem: return "sleep_rem"
        case .unspecified: return "sleep_unspecified"
        }
    }

    /// All sleep types the server must accept, with their single legal unit.
    public static var wireTypes: [String] { allCases.map(\.wireType) }
}
