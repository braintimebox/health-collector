import Foundation
import HealthKit
import Security

/// Persisted user settings. Token goes to the Keychain, everything else to
/// UserDefaults — a bearer token in a plist is readable from a backup.
struct AppSettings {
    private static let urlKey = "hc.serverURL"
    private static let enabledKey = "hc.automationEnabled"
    private static let typesKey = "hc.enabledTypes"

    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "https://hermes00.duckdns.org:1118" }
        set { UserDefaults.standard.setValue(newValue, forKey: urlKey) }
    }

    static var automationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.setValue(newValue, forKey: enabledKey) }
    }

    static var enabledTypes: [String] {
        get { UserDefaults.standard.stringArray(forKey: typesKey) ?? [] }
        set { UserDefaults.standard.setValue(newValue, forKey: typesKey) }
    }

    // MARK: Token (Keychain)

    private static let service = "com.braintimebox.healthcollector"
    private static let account = "server-token"

    static var token: String {
        get { (try? readKeychain()) ?? "" }
        set { try? writeKeychain(newValue) }
    }

    static var hasToken: Bool { !token.isEmpty }

    private static func readKeychain() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var query = base
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// Read-only lookups for the Browse tab. Bulk reads only — it never writes.
struct BrowseSample: Identifiable {
    let id = UUID()
    let type: String
    let title: String
    let value: Double
    let unit: String
    let date: Date
    let source: String
}

final class HealthKitBrowse {
    /// Not private: the workout/sleep extensions live in their own file, and
    /// the alternative — a second HKHealthStore — would double every query.
    let store = HKHealthStore()

    struct Metric {
        let wire: String
        let title: String
        let unit: String
        let sample: HKSampleType
        let identifier: String
    }

    /// Only types the collector already reads: the UI must not imply access to
    /// data the app never asked permission for.
    lazy var metrics: [Metric] = {
        var out: [Metric] = []
        func add(_ id: HKQuantityTypeIdentifier, _ wire: String, _ title: String, _ unit: String) {
            guard let type = HKObjectType.quantityType(forIdentifier: id) else { return }
            out.append(Metric(wire: wire, title: title, unit: unit, sample: type, identifier: id.rawValue))
        }
        add(.heartRateVariabilitySDNN, "heart_rate_variability_sdnn", "HRV (SDNN)", "ms")
        add(.heartRate, "heart_rate", "Heart Rate", "bpm")
        add(.restingHeartRate, "resting_heart_rate", "Resting Heart Rate", "bpm")
        add(.respiratoryRate, "respiratory_rate", "Respiratory Rate", "br/min")
        add(.stepCount, "step_count", "Steps", "count")
        add(.activeEnergyBurned, "active_energy", "Active Energy", "kcal")
        return out
    }()

    /// Latest values per metric, newest sample only. A metric with no samples is
    /// omitted — the UI shows "no data", never a fabricated zero.
    func latest(for metric: Metric) async -> BrowseSample? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: metric.sample,
                predicate: nil,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                guard let quantity = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: BrowseSample(
                    type: metric.wire,
                    title: metric.title,
                    value: quantity.quantity.doubleValue(for: Self.unit(for: metric)),
                    unit: metric.unit,
                    date: quantity.endDate,
                    source: quantity.sourceRevision.source.name
                ))
            }
            store.execute(query)
        }
    }

    func history(for metric: Metric, since: Date, limit: Int = 500) async -> [BrowseSample] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictEndDate)
            let query = HKSampleQuery(
                sampleType: metric.sample,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let rows = (samples as? [HKQuantitySample] ?? []).map { sample in
                    BrowseSample(
                        type: metric.wire,
                        title: metric.title,
                        value: sample.quantity.doubleValue(for: Self.unit(for: metric)),
                        unit: metric.unit,
                        date: sample.endDate,
                        source: sample.sourceRevision.source.name
                    )
                }
                continuation.resume(returning: rows)
            }
            store.execute(query)
        }
    }

    static func unit(for metric: Metric) -> HKUnit {
        switch metric.identifier {
        case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
            return .secondUnit(with: .milli)
        case HKQuantityTypeIdentifier.heartRate.rawValue,
             HKQuantityTypeIdentifier.restingHeartRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
            return HKUnit.count().unitDivided(by: .minute())
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
            return .kilocalorie()
        default:
            return .count()
        }
    }
}
