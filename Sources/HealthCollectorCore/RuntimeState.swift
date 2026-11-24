import Foundation

/// Whether a pass is happening right now. Kept apart from `ConnectionState` on
/// purpose: a pass can collect while no endpoint is configured, and the previous
/// batch can still be in flight while collection fails. Collapsing these into one
/// value is how "automatic collection is on" starts hiding a dead pipeline.
public enum CollectionState: Equatable, Sendable {
    case idle
    case running
    /// Not collecting because the automation switch is off — a decision, not a fault.
    case disabled
    case failed(String)

    public var label: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .disabled: return "off (automatic collection disabled)"
        case .failed(let message): return "failed: \(message)"
        }
    }
}

/// The result of the last `Test connection`, as a fact rather than a sentence the
/// view layer assembles.
public enum ConnectionState: Equatable, Sendable {
    case notChecked
    case ok(Int)
    case httpError(Int)
    case unreachable(String)
    case notConfigured(String)

    public var label: String {
        switch self {
        case .notChecked: return "not checked"
        case .ok(let code): return "ok (\(code))"
        case .httpError(let code): return "HTTP \(code)"
        case .unreachable(let message): return "unreachable: \(message)"
        case .notConfigured(let reason): return "not configured: \(reason)"
        }
    }

    public var isSuccess: Bool {
        if case .ok = self { return true }
        return false
    }
}

extension PermissionState {
    public var label: String {
        switch self {
        case .unknown: return "not requested"
        case .requested: return "requested (read status is not observable on iOS)"
        case .full: return "full"
        case .partial: return "partial"
        case .denied: return "denied"
        }
    }
}

extension BackgroundDeliveryState {
    public var label: String {
        switch self {
        case .unknown: return "unknown (not observable)"
        case .enabled: return "enabled"
        case .disabled: return "disabled"
        case .unavailable: return "unavailable (no entitlement in this profile)"
        }
    }
}

/// Everything the interface may show, in one typed object.
///
/// The app used to keep a parallel `Snapshot` of strings next to the core's
/// `CollectorStatus`, and the visible "Background delivery" line was a literal in
/// that copy: filling the core's field could never change what the user saw. Here
/// the core type is the only holder of the numbers, and the strings are derived.
public struct RuntimeState: Equatable {
    public var permission: PermissionState
    public var backgroundDelivery: BackgroundDeliveryState
    public var collection: CollectionState
    public var connection: ConnectionState
    public var automationEnabled: Bool
    public var trigger: CollectionTrigger?
    public var lastRunAt: Date?
    public var lastRunCollected: Int
    public var lastRunAccepted: Int
    public var status: CollectorStatus?

    public init(
        permission: PermissionState = .unknown,
        backgroundDelivery: BackgroundDeliveryState = .unknown,
        collection: CollectionState = .idle,
        connection: ConnectionState = .notChecked,
        automationEnabled: Bool = true,
        trigger: CollectionTrigger? = nil,
        lastRunAt: Date? = nil,
        lastRunCollected: Int = 0,
        lastRunAccepted: Int = 0,
        status: CollectorStatus? = nil
    ) {
        self.permission = permission
        self.backgroundDelivery = backgroundDelivery
        self.collection = collection
        self.connection = connection
        self.automationEnabled = automationEnabled
        self.trigger = trigger
        self.lastRunAt = lastRunAt
        self.lastRunCollected = lastRunCollected
        self.lastRunAccepted = lastRunAccepted
        self.status = status
    }

    // MARK: - Read-only view of the persisted status

    public var queueDepth: Int { status?.queueDepth ?? 0 }
    public var deadCount: Int { status?.deadLettered ?? 0 }
    public var oldestPending: TimeInterval? { status?.oldestPendingAge }
    public var lastSuccessAt: Date? { status?.lastSuccessAt }
    public var lastNewRowAt: Date? { status?.lastNewRowAt }
    public var fullHistoryTypes: [String] { status?.fullHistoryTypes ?? [] }
    public var verdict: CollectorStatus.Verdict? { status?.verdict }

    /// The failure the user must see: a collection error wins over a stored one,
    /// because it is the newer fact.
    public var lastError: String? {
        if case .failed(let message) = collection { return message }
        return status?.lastError
    }

    public var permissionLabel: String { permission.label }
    public var backgroundLabel: String { backgroundDelivery.label }
    public var connectionLabel: String { connection.label }
    public var triggerLabel: String { trigger?.label ?? "-" }
}
