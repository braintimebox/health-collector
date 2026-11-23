import Foundation

public enum PermissionState: String, Equatable {
    case unknown
    case full
    case partial
    case denied
}

public enum BackgroundDeliveryState: String, Equatable {
    case unknown
    case enabled
    case disabled
    /// The capability is not in this build's profile at all.
    case unavailable
}

/// A status panel the user can check against reality.
///
/// Every number here is read back from persisted state: queue depth, the age of
/// the oldest row that still owes the server something, the time of the last
/// *acceptance* (not the last attempt). A counter that only ever goes up proves
/// nothing, and "the app ran" is not a delivery.
public struct CollectorStatus: Equatable {
    public enum Verdict: String, Equatable {
        /// Nothing has ever been delivered and nothing is waiting.
        case idle
        case healthy
        /// Something is late or some rows are dead-lettered.
        case degraded
        /// Rows have been waiting longer than a day.
        case stalled
    }

    public static let degradedThreshold: TimeInterval = 6 * 3600
    public static let stallThreshold: TimeInterval = 24 * 3600
    /// No new row for this long is not "healthy". After a read permission is
    /// revoked, HealthKit answers exactly like an empty day, so the only honest
    /// signal left is that nothing arrived for a long time — and silence must not
    /// be dressed as health.
    public static let silenceThreshold: TimeInterval = 36 * 3600

    public let queueDepth: Int
    public let deadLettered: Int
    public let oldestPendingAge: TimeInterval?
    public let lastSuccessAt: Date?
    /// When a measurement last entered the queue, regardless of what happened to it.
    public let lastNewRowAt: Date?
    public let lastError: String?
    public let permissions: PermissionState
    public let backgroundDelivery: BackgroundDeliveryState
    /// Types whose cursor is `nil`, i.e. a full re-import is scheduled.
    public let fullHistoryTypes: [String]
    public let verdict: Verdict

    public init(
        queueDepth: Int,
        deadLettered: Int,
        oldestPendingAge: TimeInterval?,
        lastSuccessAt: Date?,
        lastNewRowAt: Date?,
        lastError: String?,
        permissions: PermissionState,
        backgroundDelivery: BackgroundDeliveryState,
        fullHistoryTypes: [String],
        verdict: Verdict
    ) {
        self.queueDepth = queueDepth
        self.deadLettered = deadLettered
        self.oldestPendingAge = oldestPendingAge
        self.lastSuccessAt = lastSuccessAt
        self.lastNewRowAt = lastNewRowAt
        self.lastError = lastError
        self.permissions = permissions
        self.backgroundDelivery = backgroundDelivery
        self.fullHistoryTypes = fullHistoryTypes
        self.verdict = verdict
    }

    public static func make(
        store: OutboxStore,
        anchors: AnchorStore,
        permissions: PermissionState = .unknown,
        backgroundDelivery: BackgroundDeliveryState = .unknown,
        types: [String],
        now: Date
    ) -> CollectorStatus {
        let depth = store.queueDepth
        let dead = store.deadCount
        let age = store.oldestPendingAge(now: now)
        let lastSuccess = store.lastAcceptedAt()
        let lastRow = store.latestRowAt()
        let fullHistory = types.filter { anchors.isFullHistory(for: $0) }

        let verdict: Verdict
        if dead > 0 {
            verdict = .degraded
        } else if let age, age > stallThreshold {
            verdict = .stalled
        } else if depth == 0, lastSuccess == nil {
            verdict = .idle
        } else if let reference = lastRow ?? lastSuccess, now.timeIntervalSince(reference) > silenceThreshold {
            // Nothing new for a day and a half with an empty queue: an empty day,
            // a revoked read permission, or a dead pipeline. We cannot tell which,
            // so we do not call it healthy.
            verdict = .degraded
        } else if let age, age > degradedThreshold {
            verdict = .degraded
        } else {
            verdict = .healthy
        }

        return CollectorStatus(
            queueDepth: depth,
            deadLettered: dead,
            oldestPendingAge: age,
            lastSuccessAt: lastSuccess,
            lastNewRowAt: lastRow,
            lastError: store.lastError(),
            permissions: permissions,
            backgroundDelivery: backgroundDelivery,
            fullHistoryTypes: fullHistory,
            verdict: verdict
        )
    }

    /// The block the diagnostics screen shows. Deliberately derives from stored
    /// state only, so it cannot claim HEALTHY while rows sit unacked.
    public func diagnosticText(appVersion: String, apiVersion: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        let lastSuccess = lastSuccessAt.map { formatter.string(from: $0) } ?? "never"
        let lastRow = lastNewRowAt.map { formatter.string(from: $0) } ?? "never"
        let oldest = oldestPendingAge.map { String(format: "%.1fh", $0 / 3600) } ?? "-"

        return """
        HEALTH COLLECTOR
        Permissions: \(permissions.rawValue.uppercased())
        Background Delivery: \(backgroundDelivery.rawValue.uppercased())
        Local Queue: \(queueDepth)
        Oldest Pending: \(oldest)
        Dead-lettered: \(deadLettered)
        Last Success: \(lastSuccess)
        Last New Row: \(lastRow)
        Last Error: \(lastError ?? "-")
        Full History Types: \(fullHistoryTypes.isEmpty ? "-" : fullHistoryTypes.joined(separator: ", "))
        App: \(appVersion)  API: \(apiVersion)
        Status: \(verdict.rawValue.uppercased())
        """
    }
}
