import Foundation

/// One upload whose response the session delegate has just handed over.
public struct CompletedUpload {
    public let fileAt: URL
    public let ack: ServerAck

    public init(fileAt: URL, ack: ServerAck) {
        self.fileAt = fileAt
        self.ack = ack
    }
}

public struct WakePlan: Equatable {
    public let accepted: Int
    public let retried: Int
    public let deadLettered: Int
    /// The next batch, already on disk and waiting for an upload task. `nil` means
    /// the outbox has nothing left to send.
    public let nextBatchFile: URL?

    public init(accepted: Int, retried: Int, deadLettered: Int, nextBatchFile: URL?) {
        self.accepted = accepted
        self.retried = retried
        self.deadLettered = deadLettered
        self.nextBatchFile = nextBatchFile
    }
}

/// What the app must do when iOS wakes it because a background transfer finished.
///
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` is the
/// only chance the app gets: iOS wakes it once, when the upload completes, and
/// only for normal termination — a force-quit cancels the transfers and suppresses
/// the relaunch entirely. So the handler has two obligations, and doing only the
/// first is the failure mode this type exists to prevent:
///
/// 1. settle the batch that just finished (rows go out of `inflight`);
/// 2. **arm the next batch itself** — the trigger has already fired, and nothing
///    will wake the app again until someone opens it.
public struct BackgroundWake {
    private let engine: SyncEngine

    public init(engine: SyncEngine) {
        self.engine = engine
    }

    public func handleEvent(now: Date, completed: [CompletedUpload] = []) throws -> WakePlan {
        var accepted = 0
        var retried = 0
        var dead = 0

        for upload in completed {
            let report = try engine.settleSpooled(fileAt: upload.fileAt, ack: upload.ack, now: now)
            accepted += report.accepted
            retried += report.retried
            dead += report.deadLettered
        }

        let next = try engine.spoolNextBatch(now: now)
        return WakePlan(accepted: accepted, retried: retried, deadLettered: dead, nextBatchFile: next)
    }
}
