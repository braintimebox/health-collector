import Foundation

// MARK: - Identity

/// One source record, named the way the source names it.
///
/// The pair `(user, record uuid)` IS the deduplication mechanism: the server's
/// unique constraint on it is what makes a re-sent batch free. Type, unit, value
/// and metadata are attributes, never key parts — folding the type into the key
/// turns a re-classification into a duplicate, and folding the value in turns any
/// correction into one.
public struct RecordIdentity: Hashable, Codable {
    public let userID: String
    public let recordID: String

    public init(userID: String, recordID: String) {
        self.userID = userID
        self.recordID = recordID
    }

    public var canonicalKey: String {
        "\(userID.lowercased()):\(recordID.lowercased())"
    }

    // Spelled out, not inferred: `keyDecodingStrategy = .convertFromSnakeCase`
    // turns `user_id` into `userId`, while the synthesized key is `userID`, and the
    // decode throws. An explicit contract also survives a rename of a Swift
    // property, which a strategy would silently carry onto the wire.
    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case recordID = "record_id"
    }
}

// MARK: - Payloads

/// A measurement exactly as the source reported it. Values are never converted
/// at the collector: the raw number and its unit travel together, so a wrong
/// interpretation stays recomputable instead of becoming unrecoverable.
public struct HealthRecord: Codable, Equatable {
    public let identity: RecordIdentity
    public let type: String
    public let value: Double
    public let unit: String
    /// ISO-8601 instant with the offset that was in force at the recording site.
    public let startDate: String
    public let endDate: String
    /// IANA zone the offsets belong to, e.g. "Europe/Warsaw".
    public let timeZone: String
    public let sourceName: String
    public let sourceID: String

    public init(
        identity: RecordIdentity,
        type: String,
        value: Double,
        unit: String,
        startDate: String,
        endDate: String,
        timeZone: String,
        sourceName: String,
        sourceID: String
    ) {
        self.identity = identity
        self.type = type
        self.value = value
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
        self.timeZone = timeZone
        self.sourceName = sourceName
        self.sourceID = sourceID
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case type
        case value
        case unit
        case startDate = "start_date"
        case endDate = "end_date"
        case timeZone = "time_zone"
        case sourceName = "source_name"
        case sourceID = "source_id"
    }
}

/// A deletion. The vendor hands these out transiently, so the only durable
/// delete channel is one that turns the notification into a row immediately.
public struct DeletedRecord: Codable, Equatable {
    public let identity: RecordIdentity
    public let deletedAt: String
    public let sourceName: String

    public init(identity: RecordIdentity, deletedAt: String, sourceName: String) {
        self.identity = identity
        self.deletedAt = deletedAt
        self.sourceName = sourceName
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case deletedAt = "deleted_at"
        case sourceName = "source_name"
    }
}

public struct OutboxPayload: Codable, Equatable {
    public enum Kind: String, Codable {
        case insert
        case delete
    }

    public let kind: Kind
    public let record: HealthRecord?
    public let deletion: DeletedRecord?

    public init(kind: Kind, record: HealthRecord?, deletion: DeletedRecord?) {
        self.kind = kind
        self.record = record
        self.deletion = deletion
    }

    public static func insert(_ record: HealthRecord) -> OutboxPayload {
        OutboxPayload(kind: .insert, record: record, deletion: nil)
    }

    public static func delete(_ deletion: DeletedRecord) -> OutboxPayload {
        OutboxPayload(kind: .delete, record: nil, deletion: deletion)
    }

    /// Synthetic deletion derived from a row that has to be undone locally.
    public static func deletion(of record: HealthRecord, at instant: String) -> OutboxPayload {
        .delete(DeletedRecord(
            identity: record.identity,
            deletedAt: instant,
            sourceName: record.sourceName
        ))
    }

    public var identity: RecordIdentity {
        switch kind {
        case .insert: return record!.identity
        case .delete: return deletion!.identity
        }
    }

    /// The queue key: identity **plus the operation**. An insert and a delete for
    /// the same record are two separate things to deliver — keying them alike
    /// silently drops the delete whenever the insert is still queued, and the
    /// server then keeps a measurement the user deleted.
    public var outboxKey: String {
        identity.canonicalKey + "|" + kind.rawValue
    }
}

// MARK: - Wire contract

/// What actually goes over HTTPS. Inserts and deletes travel in one request but
/// as separate arrays: a delete must never depend on its insert being acked
/// first, or an out-of-order retry drops it.
public struct WireBatch: Codable, Equatable {
    public let userID: String
    /// Journal key, not an identity: the server deduplicates on
    /// `(user_id, record_id)`, so a resend after a lost answer carries a new
    /// `batch_id` and still creates no duplicate. Its only job is to be found in
    /// the server's `batches` table afterwards.
    public let batchID: String
    public let records: [HealthRecord]
    public let deletes: [DeletedRecord]

    public init(
        userID: String,
        batchID: String = UUID().uuidString,
        records: [HealthRecord],
        deletes: [DeletedRecord]
    ) {
        self.userID = userID
        self.batchID = batchID
        self.records = records
        self.deletes = deletes
    }

    private enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case batchID = "batch_id"
        case records
        case deletes
    }

    public var isEmpty: Bool {
        records.isEmpty && deletes.isEmpty
    }
}

/// One encoder/decoder pair, built once. Writing with one date strategy and
/// reading with another throws, the throw gets swallowed, and the queue empties
/// itself on the next launch — so nothing here configures dates at all: the wire
/// timestamps are already strings with their offset attached.
public enum WireCodec {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

// MARK: - Timestamps

/// Absolute instant plus the zone it was recorded in. A daily average cannot be
/// expanded back into measurements, and a timestamp without its offset cannot be
/// placed back into the day the user actually had.
public enum ISOTimestamp {
    private static func formatter(fractional: Bool, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = fractional ? "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }

    public static func string(from date: Date, timeZone: TimeZone) -> String {
        formatter(fractional: true, timeZone: timeZone).string(from: date)
    }

    public static func string(from date: Date, timeZoneIdentifier: String) -> String {
        let zone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        return string(from: date, timeZone: zone)
    }

    /// The wire format the spec fixes: an instant in UTC, `Z`. The local zone is not
    /// lost — it travels in `time_zone` — but the timestamp itself is not ambiguous.
    public static func utcString(from date: Date) -> String {
        string(from: date, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    public static func isUTC(_ string: String) -> Bool {
        string.hasSuffix("Z")
    }

    public static func date(from string: String) -> Date? {
        let utc = TimeZone(secondsFromGMT: 0)!
        if let parsed = formatter(fractional: true, timeZone: utc).date(from: string) {
            return parsed
        }
        return formatter(fractional: false, timeZone: utc).date(from: string)
    }
}
