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
///
/// State model: there is exactly one published object, `RuntimeState`. It holds
/// the core's `CollectorStatus` (the numbers, read back from disk) plus four
/// separate facts — permission, background delivery, collection, connection.
/// The view layer used to keep a parallel struct of strings, and its visible
/// "Background delivery" line was a literal that nothing could ever fill: the
/// screen and the core disagreed by construction.
@MainActor
final class CollectorRuntime: ObservableObject {

    @Published private(set) var state = RuntimeState()

    private let queue = DispatchQueue(label: "healthcollector.runtime", qos: .utility)
    private let userID = "owner"

    private let source: HealthKitSource
    private let outbox: OutboxStore?
    private let anchors: AnchorStore?
    private let storeError: String?

    /// Endpoint and token come from settings, not from the binary: a token baked
    /// into an IPA is a token in every copy of that IPA.
    ///
    /// There is no fallback address. An empty or mistyped endpoint used to become
    /// a compiled-in production host, so a typo sent measurements to a server the
    /// owner never chose and looked exactly like success. Every caller below
    /// guards on this value, which is why a bad endpoint builds no request at all.
    private var endpoint: Result<ServerEndpoint, EndpointError> {
        ServerEndpoint.parse(AppSettings.serverURL)
    }

    /// Human-readable reason the endpoint is unusable, or nil when it is fine.
    private var notConfigured: String? {
        if case .failure(let error) = endpoint { return error.description }
        return nil
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
        self.state.automationEnabled = AppSettings.automationEnabled
    }

    // MARK: - Lifecycle

    func start() {
        // Read on every launch rather than remembered: this is the one setting that
        // decides whether the process may collect at all.
        state.automationEnabled = AppSettings.automationEnabled

        // A screenshot run must not be interrupted by the HealthKit permission sheet:
        // the point of those captures is the app's own layout, and a sheet would be
        // the only thing visible. Nothing else changes — no data is read, nothing is
        // enqueued, and the panel says so instead of pretending.
        if ProcessInfo.processInfo.arguments.contains("-uiScreenshots") {
            state.collection = .disabled
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.source.requestAuthorization()
                self.state.permission = .requested
            } catch {
                // Apple does not let an app distinguish a denied read from an empty
                // store, so the panel reports only what it can prove. The failure is
                // recorded as a collection fault, never as a permission verdict.
                self.state.permission = .unknown
                self.state.collection = .failed("\(error)")
            }
            // The observer stays registered even with automation off: its wake is
            // gated inside `syncNow`. Unregistering would make switching the setting
            // back on take effect only at the next launch.
            self.source.startBackgroundDelivery { [weak self] in
                self?.syncNow(trigger: .backgroundDelivery)
            }
            self.syncNow(trigger: .launch)
        }
    }

    /// Applies the switch immediately — no relaunch, no waiting for the next trigger.
    func setAutomation(_ enabled: Bool) {
        AppSettings.automationEnabled = enabled
        state.automationEnabled = enabled
        if enabled {
            syncNow(trigger: .foreground)
        } else {
            // A pass already running is allowed to finish; what must stop is the app
            // claiming collection is armed.
            state.collection = .disabled
        }
    }

    func requestPermissions() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.source.requestAuthorization()
                self.state.permission = .requested
            } catch {
                self.state.permission = .unknown
                self.state.collection = .failed("\(error)")
            }
        }
    }

    // MARK: - Connection

    /// Проверка соединения — это GET по тому же базовому адресу, что и приём.
    /// Ничего не отправляет и ничего не подтверждает.
    func testServer(completion: @escaping (String) -> Void) {
        guard case .success(let server) = endpoint else {
            let reason = notConfigured ?? "no endpoint"
            state.connection = .notConfigured(reason)
            completion("not configured: \(reason)")
            return
        }
        var request = URLRequest(url: server.url.appendingPathComponent(ApiRoute.relative(ApiRoute.healthProbe)))
        request.timeoutInterval = 10
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let connection: ConnectionState
            if let error {
                connection = .unreachable(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                connection = (200...299).contains(http.statusCode)
                    ? .ok(http.statusCode)
                    : .httpError(http.statusCode)
            } else {
                connection = .unreachable("no response")
            }
            Task { @MainActor in
                self?.state.connection = connection
                completion(connection.label)
            }
        }.resume()
    }

    // MARK: - Collection

    /// Manual window export.
    ///
    /// Reads `[from, to]` for every supported type, puts the rows into the same
    /// outbox the automatic path uses, and drains it through the same `SyncEngine`.
    /// The stored cursor is not touched, so a manual look never costs data; a row
    /// already delivered is refused by the outbox's key and simply not counted.
    ///
    /// An explicit request, so it ignores the automation switch — that is why
    /// `CollectionTrigger.isExplicit` lives in the core where it can be tested.
    func exportWindow(period: CollectionPeriod, completion: ((String) -> Void)? = nil) {
        guard AutomationGate.decide(trigger: .windowExport, automationEnabled: state.automationEnabled).runs else {
            completion?("automation disabled")
            return
        }
        guard let outbox, let anchors else {
            let message = storeError ?? "storage unavailable"
            state.collection = .failed(message)
            completion?(message)
            return
        }
        // A window export exists to deliver a range: with no usable endpoint there
        // is nowhere to deliver it, so nothing is read and no request is built.
        guard case .success(let server) = endpoint else {
            let message = notConfigured ?? "no endpoint configured"
            state.connection = .notConfigured(message)
            completion?(message)
            return
        }
        let window = CollectionWindow.make(period: period, now: Date())
        let source = self.source
        let types = HealthKitSource.supportedTypes
        let transport = URLSessionTransport(baseURL: server.url, token: token)
        let permission = state.permission
        let background = state.backgroundDelivery
        state.trigger = .windowExport
        state.collection = .running
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
            let status = CollectorStatus.make(
                store: outbox, anchors: anchors, types: types, now: Date(),
                permissions: permission, backgroundDelivery: background)
            Task { @MainActor in
                guard let self else { return }
                self.apply(status: status, collected: collected, accepted: accepted, failure: failure)
                completion?(failure ?? "collected \(collected), accepted \(accepted)")
            }
        }
    }

    // MARK: - Sync

    func syncNow(trigger: CollectionTrigger) {
        switch AutomationGate.decide(trigger: trigger, automationEnabled: state.automationEnabled) {
        case .skip:
            state.trigger = trigger
            state.lastRunAt = Date()
            state.lastRunCollected = 0
            state.lastRunAccepted = 0
            state.collection = .disabled
            return
        case .run:
            break
        }
        guard let outbox, let anchors else {
            state.collection = .failed(storeError ?? "storage unavailable")
            return
        }
        let source = self.source
        let types = HealthKitSource.supportedTypes
        // Collection still runs without an endpoint: readings already in HealthKit
        // belong in the durable outbox, and dropping them would turn a settings
        // mistake into lost data. Only the transfer is skipped — and it is skipped
        // by never building a transport, not by trying and failing.
        let transport: OutboxTransport? = {
            guard case .success(let server) = endpoint else { return nil }
            return URLSessionTransport(baseURL: server.url, token: token)
        }()
        let misconfiguration = notConfigured
        let permission = state.permission
        // The only honest source for this: what HealthKit answered when the
        // observers were registered on this process.
        let background = source.backgroundDeliverySnapshot()
        state.trigger = trigger
        state.collection = .running
        queue.async { [weak self] in
            var collected = 0
            var accepted = 0
            var failure: String?
            do {
                let collector = Collector(
                    source: source, outbox: outbox, anchors: anchors, types: types, clock: Date.init)
                collected = try collector.collectOnce().inserted
                if let transport {
                    let engine = SyncEngine(userID: "owner", store: outbox, transport: transport)
                    accepted = try engine.drain(now: Date()).accepted
                } else {
                    failure = misconfiguration ?? "no endpoint configured"
                }
            } catch {
                failure = "\(error)"
            }
            let status = CollectorStatus.make(
                store: outbox, anchors: anchors, types: types, now: Date(),
                permissions: permission, backgroundDelivery: background)
            Task { @MainActor in
                guard let self else { return }
                self.apply(status: status, collected: collected, accepted: accepted, failure: failure)
            }
        }
    }

    /// One place where a finished pass becomes visible state.
    private func apply(status: CollectorStatus, collected: Int, accepted: Int, failure: String?) {
        state.status = status
        state.lastRunAt = Date()
        state.lastRunCollected = collected
        state.lastRunAccepted = accepted
        state.permission = status.permissions
        state.backgroundDelivery = status.backgroundDelivery
        if let failure {
            state.collection = .failed(failure)
        } else if state.collection != .disabled {
            state.collection = .idle
        }
    }

    // MARK: - Diagnostics

    /// Диагностика без секретов и без значений измерений.
    func diagnosticsText() -> String {
        let host: String
        switch endpoint {
        case .success(let server): host = server.host
        case .failure(let error): host = "not configured (\(error))"
        }
        let state = self.state
        return [
            "HealthCollector",
            "queue_depth=\(state.queueDepth)",
            "dead_letter=\(state.deadCount)",
            "oldest_pending_s=\(Int(state.oldestPending ?? 0))",
            "last_success=\(state.lastSuccessAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "last_run=\(state.lastRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
            "automation=\(state.automationEnabled ? "on" : "off")",
            "collection=\(state.collection.label)",
            "permissions=\(state.permission.rawValue)",
            "background_delivery=\(state.backgroundDelivery.rawValue)",
            "connection=\(state.connection.label)",
            "server_host=\(host)",
            "token_configured=\(AppSettings.hasToken)",
            "last_error=\(state.lastError ?? "none")",
        ].joined(separator: "\n")
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
