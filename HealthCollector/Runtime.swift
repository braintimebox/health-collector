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
        var permissions: String = "unknown"
        var queueDepth: Int = 0
        var collected: Int = 0
        var accepted: Int = 0
        var lastRunAt: Date?
        var lastError: String?
        var detail: String = "idle"
    }

    @Published private(set) var snapshot = Snapshot()

    private let queue = DispatchQueue(label: "healthcollector.runtime", qos: .utility)
    private let userID = "owner"
    private let baseURL = URL(string: "https://hermes00.duckdns.org:1118")!
    private let token: String

    private let source: HealthKitSource
    private let outbox: OutboxStore?
    private let anchors: AnchorStore?
    private let storeError: String?

    init() {
        let env = ProcessInfo.processInfo.environment
        self.token = env["HEALTH_COLLECTOR_TOKEN"]
            ?? Bundle.main.object(forInfoDictionaryKey: "HCToken") as? String
            ?? ""
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
            throw TransportFailure(kind: .permanent, message: "no token configured")
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
                outcome = .success(try MeasurementClient.parseReply(status: http.statusCode, body: data))
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

struct RuntimeView: View {
    @ObservedObject var runtime: CollectorRuntime

    var body: some View {
        let snapshot = runtime.snapshot
        VStack(alignment: .leading, spacing: 8) {
            row("HealthKit", snapshot.permissions)
            row("Local queue", "\(snapshot.queueDepth)")
            row("New rows", "\(snapshot.collected)")
            row("Accepted", "\(snapshot.accepted)")
            row("Last run", snapshot.lastRunAt.map { Self.formatter.string(from: $0) } ?? "never")
            row("Trigger", snapshot.detail)
            if let error = snapshot.lastError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Button("Sync now") { runtime.syncNow(reason: "manual") }
                .buttonStyle(.borderedProminent)
            Text(buildIdentity).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.callout)
            Spacer()
            Text(value).font(.callout.monospaced())
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var buildIdentity: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(info?["CFBundleIdentifier"] as? String ?? "?") \(short) (\(build))"
    }
}
