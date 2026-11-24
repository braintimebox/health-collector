import Foundation

/// Why a collection pass was started.
///
/// The reason decides whether the user's "Automatic collection" switch applies.
/// A manual run is an explicit request and must work with automation off; every
/// timer-driven reason must not. Keeping this decision in the core makes it a
/// unit-testable fact instead of a side effect of where a call happens to sit in
/// the view hierarchy.
public enum CollectionTrigger: String, CaseIterable, Equatable, Sendable {
    case launch
    case foreground
    case observer
    case backgroundDelivery
    case retry
    case manual
    case windowExport

    /// The user asked for this one, so the automation switch does not apply.
    public var isExplicit: Bool {
        switch self {
        case .manual, .windowExport:
            return true
        case .launch, .foreground, .observer, .backgroundDelivery, .retry:
            return false
        }
    }

    public var label: String { rawValue }
}

public enum SkipReason: String, Equatable, Sendable {
    case automationDisabled
}

public enum CollectionDecision: Equatable, Sendable {
    case run
    case skip(SkipReason)

    public var runs: Bool {
        if case .run = self { return true }
        return false
    }
}

/// The single rule that answers "may this pass read HealthKit?".
public enum AutomationGate {
    public static func decide(
        trigger: CollectionTrigger,
        automationEnabled: Bool
    ) -> CollectionDecision {
        if trigger.isExplicit { return .run }
        return automationEnabled ? .run : .skip(.automationDisabled)
    }
}
