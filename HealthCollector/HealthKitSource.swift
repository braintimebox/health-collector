import Foundation
import HealthCollectorCore
import HealthKit

/// The real HealthKit source. It is the only file in this app that talks to
/// HealthKit, and it sits behind `HealthSource` so the core stays testable on
/// Linux and in CI without a device.
///
/// Honest limits of what is observable here (Apple, not our choice):
/// - `authorizationStatus(for:)` answers for **write** only. Read access cannot be
///   determined: a denied read looks exactly like "no data".
/// - `limited` is the only positively identifiable state.
/// - `enableBackgroundDelivery` returns `errorAuthorizationDenied` both for a
///   missing entitlement and for a denied user, so a runtime probe cannot tell
///   them apart. That is why the profile is checked before install (P1 gate).
final class HealthKitSource: HealthSource {

    struct TypeMapping {
        let wireType: String
        let unit: String
        let sampleType: HKSampleType
        let frequency: HKUpdateFrequency
    }

    enum SourceError: Error, CustomStringConvertible {
        case notAvailable
        case authorizationFailed(String)
        case queryFailed(String)
        case timeout(String)

        var description: String {
            switch self {
            case .notAvailable: return "HealthKit is not available on this device"
            case let .authorizationFailed(message): return "authorization failed: \(message)"
            case let .queryFailed(message): return "query failed: \(message)"
            case let .timeout(type): return "anchored query timed out for \(type)"
            }
        }
    }

    static let mappings: [TypeMapping] = {
        var out: [TypeMapping] = []
        func quantity(_ identifier: HKQuantityTypeIdentifier, _ wire: String, _ unit: String,
                      _ frequency: HKUpdateFrequency) {
            guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return }
            out.append(TypeMapping(wireType: wire, unit: unit, sampleType: type, frequency: frequency))
        }
        quantity(.heartRateVariabilitySDNN, "heart_rate_variability_sdnn", "ms", .hourly)
        quantity(.heartRate, "heart_rate", "count/min", .immediate)
        quantity(.restingHeartRate, "resting_heart_rate", "count/min", .hourly)
        quantity(.stepCount, "step_count", "count", .hourly)
        quantity(.activeEnergyBurned, "active_energy", "kcal", .hourly)
        quantity(.respiratoryRate, "respiratory_rate", "count/min", .hourly)

        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            out.append(TypeMapping(wireType: "sleep_analysis", unit: "h", sampleType: sleep, frequency: .hourly))
        }
        out.append(TypeMapping(wireType: "workout", unit: "min", sampleType: HKObjectType.workoutType(), frequency: .hourly))
        return out
    }()

    /// Types the collector asks for: the mapped sample types plus the sleep stages,
    /// which share one HK type (`sleepAnalysis`) but travel as distinct wire types.
    static var supportedTypes: [String] {
        mappings.map(\.wireType).filter { $0 != "sleep_analysis" } + SleepStage.wireTypes
    }

    /// A stage type resolves to the one `sleepAnalysis` sample type, so a per-stage
    /// cursor still queries the same HK type and keeps its own anchor.
    static func mapping(for type: String) -> TypeMapping? {
        if let direct = mappings.first(where: { $0.wireType == type }) { return direct }
        guard SleepStage.allCases.contains(where: { $0.wireType == type }) else { return nil }
        return mappings.first { $0.wireType == "sleep_analysis" }
    }

    private let store = HKHealthStore()
    private let userID: String
    private let lock = NSLock()
    private var pendingWake: (() -> Void)?
    /// What HealthKit answered for background delivery, per type.
    ///
    /// A `false` here cannot distinguish a missing entitlement from a user denial,
    /// so the derived state says "disabled" and never pretends to name the cause —
    /// but leaving the answer unread was worse: the diagnostics line claimed
    /// "unknown (not observable)" forever, which is a statement about our code, not
    /// about HealthKit.
    private var deliveryOutcomes: [String: Bool] = [:]

    /// Rounded-up answer across every type: all enabled, some refused, or nothing
    /// asked yet. Called from the main actor; the dictionary is written from the
    /// HealthKit completion queue, so it is only ever touched under `lock`.
    func backgroundDeliverySnapshot() -> BackgroundDeliveryState {
        lock.lock()
        let outcomes = deliveryOutcomes
        lock.unlock()
        guard !outcomes.isEmpty else { return .unknown }
        return outcomes.values.allSatisfy { $0 } ? .enabled : .disabled
    }

    private func record(deliveryEnabled: Bool, for type: String) {
        lock.lock()
        deliveryOutcomes[type] = deliveryEnabled
        lock.unlock()
    }

    init(userID: String) {
        self.userID = userID
    }

    // MARK: Authorization

    /// Requests read access for every mapped type. Write access is never asked
    /// for: the collector only reads, and asking for more than it uses is both a
    /// privacy defect and an extra permission the profile may refuse.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw SourceError.notAvailable }
        let read = Set(Self.mappings.map(\.sampleType))
        do {
            try await store.requestAuthorization(toShare: [], read: read)
        } catch {
            throw SourceError.authorizationFailed(error.localizedDescription)
        }
    }

    /// Enables background delivery per type and registers observers. Observer
    /// queries are registered at launch (Apple's requirement) and each one only
    /// signals that a fetch is due — the fetch itself is an anchored query, so a
    /// missed wake-up costs nothing: the next one picks up everything since the
    /// stored anchor.
    func startBackgroundDelivery(onWake: @escaping () -> Void) {
        lock.lock(); pendingWake = onWake; lock.unlock()
        for mapping in Self.mappings {
            let query = HKObserverQuery(sampleType: mapping.sampleType, predicate: nil) { [weak self] _, completion, error in
                defer { completion() }   // always: three missed completions disable delivery for good
                guard error == nil, let self else { return }
                self.lock.lock(); let wake = self.pendingWake; self.lock.unlock()
                wake?()
            }
            store.execute(query)
            let wireType = mapping.wireType
            store.enableBackgroundDelivery(for: mapping.sampleType, frequency: mapping.frequency) { [weak self] enabled, error in
                // Recorded, not judged: `false` cannot distinguish a missing
                // entitlement from a user denial, so the panel will say "disabled"
                // and never invent the cause.
                self?.record(deliveryEnabled: error == nil && enabled, for: wireType)
            }
        }
    }

    // MARK: Fetch

    func fetch(for type: String, since cursor: String?) throws -> FetchResult {
        guard let mapping = Self.mapping(for: type) else {
            throw SourceError.queryFailed("unknown type \(type)")
        }
        let anchor = AnchorCodec.decode(cursor)
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: [HealthRecord] = []
        var deleted: [DeletedRecord] = []
        var newAnchor: HKQueryAnchor?
        var failure: Error?

        let query = HKAnchoredObjectQuery(
            type: mapping.sampleType,
            predicate: nil,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { _, samples, deletedObjects, anchor, error in
            if let error { failure = error }
            newAnchor = anchor
            for sample in samples ?? [] {
                if let record = Self.record(from: sample, mapping: mapping, userID: self.userID) {
                    fetched.append(record)
                }
            }
            for object in deletedObjects ?? [] {
                deleted.append(DeletedRecord(
                    identity: RecordIdentity(userID: self.userID, recordID: object.uuid.uuidString),
                    deletedAt: ISOTimestamp.utcString(from: Date()),
                    sourceName: "Apple Health"
                ))
            }
            semaphore.signal()
        }
        store.execute(query)
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw SourceError.timeout(type)
        }
        if let failure { throw SourceError.queryFailed(failure.localizedDescription) }
        // The caller persists rows *before* the cursor moves (Collector's contract),
        // so returning the new anchor here is the only thing this method decides.
        return FetchResult(
            cursor: AnchorCodec.encode(newAnchor),
            inserted: fetched,
            deleted: deleted
        )
    }

    /// A window read for a manual export.
    ///
    /// It deliberately does not touch the stored anchor. A start-date predicate on
    /// the incremental query would move the cursor to the window's edge, and
    /// everything the cursor had not reached yet would be skipped — that is data
    /// loss wearing the word "filter". Deletions are not collected here either:
    /// they arrive on the anchored path, which is the only channel Apple keeps
    /// durable.
    func fetchWindow(for type: String, from: Date?, to: Date) throws -> [HealthRecord] {
        guard let mapping = Self.mapping(for: type) else {
            throw SourceError.queryFailed("unknown type \(type)")
        }
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: [HealthRecord] = []
        var failure: Error?

        let query = HKSampleQuery(
            sampleType: mapping.sampleType,
            // `options: []` even with an explicit start: `strictStartDate` on a nil
            // start is not a filter, it is a query that returns nothing.
            predicate: HKQuery.predicateForSamples(withStart: from, end: to, options: []),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        ) { _, samples, error in
            if let error { failure = error }
            for sample in samples ?? [] {
                if let record = Self.record(from: sample, mapping: mapping, userID: self.userID) {
                    fetched.append(record)
                }
            }
            semaphore.signal()
        }
        store.execute(query)
        if semaphore.wait(timeout: .now() + 30) == .timedOut {
            throw SourceError.timeout(type)
        }
        if let failure { throw SourceError.queryFailed(failure.localizedDescription) }
        return fetched
    }

    // MARK: Mapping

    private static func record(from sample: HKSample, mapping: TypeMapping, userID: String) -> HealthRecord? {
        let source = sample.sourceRevision.source
        let start = ISOTimestamp.string(from: sample.startDate, timeZone: .current)
        let end = ISOTimestamp.string(from: sample.endDate, timeZone: .current)
        let zone = TimeZone.current.identifier

        func make(_ value: Double, _ unit: String) -> HealthRecord {
            HealthRecord(
                identity: RecordIdentity(userID: userID, recordID: sample.uuid.uuidString),
                type: mapping.wireType,
                value: value,
                unit: unit,
                startDate: start,
                endDate: end,
                timeZone: zone,
                sourceName: source.name,
                sourceID: source.bundleIdentifier
            )
        }

        if let quantity = sample as? HKQuantitySample {
            switch mapping.wireType {
            case "heart_rate_variability_sdnn":
                return make(quantity.quantity.doubleValue(for: .secondUnit(with: .milli)), "ms")
            case "heart_rate", "resting_heart_rate", "respiratory_rate":
                return make(quantity.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())), "count/min")
            case "step_count":
                return make(quantity.quantity.doubleValue(for: .count()), "count")
            case "active_energy":
                return make(quantity.quantity.doubleValue(for: .kilocalorie()), "kcal")
            default:
                return nil
            }
        }

        if let category = sample as? HKCategorySample {
            guard mapping.wireType == "sleep_analysis" else { return nil }
            // One row per segment, in hours, and the stage travels in the type:
            // `sleep_analysis` alone would make deep, REM and awake rows identical.
            let hours = category.endDate.timeIntervalSince(category.startDate) / 3600
            let stage = SleepStage.from(categoryValue: category.value)
            let record = make(hours, "h")
            return HealthRecord(
                identity: record.identity,
                type: stage.wireType,
                value: record.value,
                unit: record.unit,
                startDate: record.startDate,
                endDate: record.endDate,
                timeZone: record.timeZone,
                sourceName: record.sourceName,
                sourceID: record.sourceID
            )
        }

        if let workout = sample as? HKWorkout {
            return make(workout.duration / 60, "min")
        }
        return nil
    }
}

/// Cursors are `HKQueryAnchor`, which is `NSSecureCoding`; `nil` means "from the
/// beginning" and is the recovery path after any suspicion of loss.
enum AnchorCodec {
    static func encode(_ anchor: HKQueryAnchor?) -> String {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        else { return "" }
        return data.base64EncodedString()
    }

    static func decode(_ cursor: String?) -> HKQueryAnchor? {
        guard let cursor, !cursor.isEmpty, let data = Data(base64Encoded: cursor) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
