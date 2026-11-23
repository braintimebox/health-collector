import Foundation
import HealthCollectorCore
import HealthKit
import SwiftUI

/// Owns every long-lived object and runs collection on one serial queue.
///
/// Concurrency model, stated once and enforced here: `OutboxStore` and
/// `AnchorStore` are touched only from `queue`. The stores carry a lock for
/// cross-queue reads (the UI), but the queue is the actual owner — that is the
/// difference between "we added a mutex" and "we defined the model".
@MainActor
final class CollectorRuntime: ObservableObject {

    struct Snapshot {
        var permissions: String = "not requested"
        var backgroundDelivery: String = "unknown (not observable)"
        var queueDepth: Int = 0
        var deadCount: Int = 0
        var oldestPending: TimeInterval?
        var lastSuccessAt: Date?
        var collected: Int = 0
        var accepted: Int = 0
        var lastRunAt: Date?
        var lastError: String?
        var serverStatus: String = "not checked"
        var detail: String = "idle"
    }

    @Published private(set) var snapshot = Snapshot()

    private let queue = DispatchQueue(label: "healthcollector.runtime", qos: .utility)
    private let userID = "owner"

    private let source: HealthKitSource
    private let outbox: OutboxStore?
    private let anchors: AnchorStore?
    private let storeError: String?

    /// Endpoint and token come from settings, not from the binary: a token baked
    /// into an IPA is a token in every copy of that IPA.
    private var baseURL: URL {
        URL(string: AppSettings.serverURL) ?? URL(string: "https://hermes00.duckdns.org:1118")!
    }

    private var token: String { AppSettings.token }

    init() {
        self.source = HealthKitSource(userID: "owner")

        var outbox: OutboxStore?
        var anchors: AnchorStore?
        var storageError: String?
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            outbox = try OutboxStore(directory: support.appendingPathComponent("outbox", isDirectory: true))
            anchors = try AnchorStore(directory: support.appendingPathComponent("anchors", isDirectory: true))
        } catch let failure {
            storageError = "storage unavailable: \(failure.localizedDescription)"
        }
        self.outbox = outbox
        self.anchors = anchors
        self.storeError = storageError
    }

    func start() {
        // A screenshot run must not be interrupted by the HealthKit permission sheet:
        // the point of those captures is the app's own layout, and a sheet would be
        // the only thing visible. Nothing else changes — no data is read, nothing is
        // enqueued, and the panel says so instead of pretending.
        if ProcessInfo.processInfo.arguments.contains("-uiScreenshots") {
            snapshot.permissions = "not requested (screenshot run)"
            return
        }
        Task {
            do {
                try await source.requestAuthorization()
                snapshot.permissions = "requested (read status is not observable on iOS)"
            } catch {
                // Apple does not let an app distinguish a denied read from an empty
                // store, so the panel reports only what it can prove.
                snapshot.permissions = "request failed"
                snapshot.lastError = "\(error)"
            }
            source.startBackgroundDelivery { [weak self] in
                self?.syncNow(reason: "background delivery")
            }
            syncNow(reason: "launch")
        }
    }

    func requestPermissions() {
        Task {
            do {
                try await source.requestAuthorization()
                snapshot.permissions = "requested (read status not observable)"
            } catch {
                snapshot.permissions = "request failed"
                snapshot.lastError = "\(error)"
            }
        }
    }

    /// Проверка соединения — это GET по тому же базовому адресу, что и приём.
    /// Ничего не отправляет и ничего не подтверждает.
    func testServer(completion: @escaping (String) -> Void) {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/health"))
        request.timeoutInterval = 10
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: String
            if let error {
                result = "unreachable: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                result = (200...299).contains(http.statusCode) ? "ok (\(http.statusCode))" : "HTTP \(http.statusCode)"
            } else {
                result = "no response"
            }
            Task { @MainActor in
                self?.snapshot.serverStatus = result
                completion(result)
            }
        }.resume()
    }

    /// Manual window export.
    ///
    /// Reads `[from, to]` for every supported type, puts the rows into the same
    /// outbox the automatic path uses, and drains it through the same `SyncEngine`.
    /// The stored cursor is not touched, so a manual look never costs data; a row
    /// already delivered is refused by the outbox's key and simply not counted.
    func exportWindow(period: CollectionPeriod, completion: ((String) -> Void)? = nil) {
        guard let outbox, let anchors else {
            let message = storeError ?? "storage unavailable"
            snapshot.lastError = message
            completion?(message)
            return
        }
        let window = CollectionWindow.make(period: period, now: Date())
        let source = self.source
        let types = HealthKitSource.supportedTypes
        let transport = URLSessionTransport(baseURL: baseURL, token: token)
        queue.async { [weak self] in
            var collected = 0
            var accepted = 0
            var failure: String?
            for type in types {
                do {
                    let records = try source.fetchWindow(for: type, from: window.from, to: window.to)
                    for record in records {
                        if try outbox.enqueue(.insert(record), now: Date()) {
                            collected += 1
                        }
                    }
                } catch {
                    failure = failure ?? "\(type): \(error)"
                }
            }
            do {
                let engine = SyncEngine(userID: "owner", store: outbox, transport: transport)
                accepted = try engine.drain(now: Date()).accepted
            } catch {
                failure = failure ?? "\(error)"
            }
            let status = CollectorStatus.make(store: outbox, anchors: anchors, types: types, now: Date())
            Task { @MainActor in
                guard let self else { return }
                self.snapshot.queueDepth = status.queueDepth
                self.snapshot.deadCount = status.deadLettered
                self.snapshot.oldestPending = status.oldestPendingAge
                self.snapshot.lastSuccessAt = status.lastSuccessAt
                self.snapshot.collected = collected
                self.snapshot.accepted = accepted
                self.snapshot.lastRunAt = Date()
                self.snapshot.detail = "manual \(period.rawValue)"
                self.snapshot.lastError = failure
                completion?(failure ?? "collected \(collected), accepted \(accepted)")
            }
        }
    }

    /// Диагностика без секретов и без значений измерений.
    func diagnosticsText() -> String {
        let host = URL(string: AppSettings.serverURL)?.host ?? "?"
        let snapshot = self.snapshot
        return [
            "HealthCollector",
            "queue_depth=\(snapshot.queueDepth)",
            "dead_letter=\(snapshot.deadCount)",
            "oldest_pending_s=\(Int(snapshot.oldestPending ?? 0))",
            "last_success=\(snapshot.lastSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "last_run=\(snapshot.lastRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "permissions=\(snapshot.permissions)",
            "server_host=\(host)",
            "token_configured=\(AppSettings.hasToken)",
            "last_error=\(snapshot.lastError ?? "none")",
        ].joined(separator: "\n")
    }

    func syncNow(reason: String) {
        guard let outbox, let anchors else {
            snapshot.lastError = storeError ?? "storage unavailable"
            return
        }
        let source = self.source
        let types = HealthKitSource.supportedTypes
        let transport = URLSessionTransport(baseURL: baseURL, token: token)
        queue.async { [weak self] in
            var collected = 0
            var accepted = 0
            var failure: String?
            do {
                let collector = Collector(
                    source: source, outbox: outbox, anchors: anchors, types: types, clock: Date.init)
                collected = try collector.collectOnce().inserted
                let engine = SyncEngine(userID: "owner", store: outbox, transport: transport)
                accepted = try engine.drain(now: Date()).accepted
            } catch {
                failure = "\(error)"
            }
            let status = CollectorStatus.make(
                store: outbox, anchors: anchors, types: types, now: Date())
            Task { @MainActor in
                guard let self else { return }
                self.snapshot.queueDepth = status.queueDepth
                self.snapshot.deadCount = status.deadLettered
                self.snapshot.oldestPending = status.oldestPendingAge
                self.snapshot.lastSuccessAt = status.lastSuccessAt
                self.snapshot.collected = collected
                self.snapshot.accepted = accepted
                self.snapshot.lastRunAt = Date()
                self.snapshot.detail = reason
                if let failure {
                    self.snapshot.lastError = failure
                } else if collected > 0 || accepted > 0 {
                    self.snapshot.lastError = nil
                }
            }
        }
    }
}

/// The one place a byte leaves the phone. Request building lives in the core and
/// is unit-tested there; this only performs the call and classifies the answer.
struct URLSessionTransport: OutboxTransport {
    let baseURL: URL
    let token: String

    func send(_ batch: WireBatch) throws -> ServerAck {
        guard !token.isEmpty else {
            throw TransportFailure(kind: .http, status: 401, message: "no token configured")
        }
        let request = try MeasurementClient.makeRequest(batch: batch, baseURL: baseURL, token: token)
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<ServerAck, TransportFailure>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(TransportFailure(kind: .transport, message: error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                outcome = .failure(TransportFailure(kind: .transport, message: "no response"))
                return
            }
            do {
                outcome = .success(try MeasurementClient.decode(
                    reply: HTTPReply(status: http.statusCode,
                                     retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init),
                                     body: data)))
            } catch let failure as TransportFailure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(TransportFailure(kind: .malformedAck, message: "\(error)"))
            }
        }.resume()
        guard semaphore.wait(timeout: .now() + 45) == .success else {
            throw TransportFailure(kind: .transport, message: "request timed out")
        }
        switch outcome {
        case let .success(ack): return ack
        case let .failure(failure): throw failure
        case .none: throw TransportFailure(kind: .transport, message: "no outcome")
        }
    }
}
