import Foundation

// MARK: - Transport contract

/// A record the server refused, with the reason it refused it. A refusal that
/// names the id is actionable; a batch-level failure is not.
public struct RejectedRecord: Codable, Equatable {
    public let recordID: String
    public let reason: String
    /// `true` means retrying cannot help (malformed unit, unknown type). The row
    /// is dead-lettered instead of blocking the queue forever.
    public let permanent: Bool

    public init(recordID: String, reason: String, permanent: Bool) {
        self.recordID = recordID
        self.reason = reason
        self.permanent = permanent
    }
}

/// What the server says it stored. A bare `200` is not a delivery proof: a server
/// that accepts the request and fails the write is the exact silent failure the
/// whole outbox exists to prevent, so the ids must be named.
public struct ServerAck: Equatable {
    public let accepted: [String]
    public let rejected: [RejectedRecord]

    public init(accepted: [String], rejected: [RejectedRecord] = []) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

public struct TransportFailure: Error, Equatable {
    public enum Kind: Equatable {
        case transport
        case timeout
        case http
        /// The response arrived but its body could not be read as an ack.
        case malformedAck
    }

    public let kind: Kind
    public let status: Int?
    public let retryAfter: TimeInterval?
    public let message: String

    public init(kind: Kind, status: Int? = nil, retryAfter: TimeInterval? = nil, message: String) {
        self.kind = kind
        self.status = status
        self.retryAfter = retryAfter
        self.message = message
    }
}

public protocol OutboxTransport {
    func send(_ batch: WireBatch) throws -> ServerAck
}

// MARK: - Retry policy

public enum FailureClass: Equatable {
    case retryable
    case permanent
    case unconfirmed
}

public struct RetryPolicy: Equatable {
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var cap: TimeInterval
    public var jitterFraction: Double

    public init(
        baseDelay: TimeInterval = 2,
        multiplier: Double = 2,
        cap: TimeInterval = 900,
        jitterFraction: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// `attempt` is 1 for the first failure. Jitter is passed in, not sampled
    /// here, so the schedule is reproducible in a test.
    public func delay(forAttempt attempt: Int, jitter: Double = 0.5) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let raw = min(cap, baseDelay * pow(multiplier, exponent))
        let clamped = min(1, max(0, jitter))
        let spread = raw * jitterFraction * (clamped * 2 - 1)
        return max(0, raw + spread)
    }

    public func classification(for failure: TransportFailure) -> FailureClass {
        switch failure.kind {
        case .malformedAck:
            // Unreadable is not failed and not stored: resend, and let
            // idempotency make the resend free.
            return .unconfirmed
        case .transport, .timeout:
            return .retryable
        case .http:
            guard let status = failure.status else { return .retryable }
            if status == 408 || status == 429 || (500...599).contains(status) {
                return .retryable
            }
            // Retrying a malformed payload forever burns battery and hides the
            // defect behind an always-full queue.
            return .permanent
        }
    }
}
