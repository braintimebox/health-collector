import SwiftUI

struct ExportTab: View {
    @ObservedObject var runtime: CollectorRuntime

    private let cards: [(String, String, String)] = [
        ("Manual", "square.and.arrow.up", "Run a collection and send it now"),
        ("Automated", "clock.arrow.circlepath", "What iOS actually permits"),
        ("Sync to Mac", "desktopcomputer", "Not implemented"),
        ("Server", "server.rack", "Endpoint, token, test, sync"),
        ("Shortcuts", "bolt.horizontal", "Planned"),
        ("Help", "questionmark.circle", "How it works"),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(cards, id: \.0) { card in
                    NavigationLink {
                        destination(card.0)
                    } label: {
                        CardTile(title: card.0, symbol: card.1, subtitle: card.2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()

            StatusStrip(runtime: runtime)
                .padding(.horizontal)
                .padding(.bottom)
        }
        .navigationTitle("Export")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    runtime.syncNow(reason: "manual")
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    @ViewBuilder
    private func destination(_ title: String) -> some View {
        switch title {
        case "Manual": ManualExportView(runtime: runtime)
        case "Automated": AutomatedView(runtime: runtime)
        case "Server": ServerView(runtime: runtime)
        case "Shortcuts": ShortcutsView()
        case "Help": HelpView()
        default: SyncToMacView()
        }
    }
}

struct CardTile: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Настоящее состояние очереди, а не «всё хорошо».
struct StatusStrip: View {
    @ObservedObject var runtime: CollectorRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collector").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            StatusRow(title: "Queue", value: "\(runtime.snapshot.queueDepth)",
                      tone: runtime.snapshot.queueDepth > 0 ? .warn : .good)
            StatusRow(title: "Oldest pending", value: duration(runtime.snapshot.oldestPending),
                      tone: (runtime.snapshot.oldestPending ?? 0) > 86_400 ? .warn : .neutral)
            StatusRow(title: "Last success", value: relative(runtime.snapshot.lastSuccessAt))
            StatusRow(title: "Last run", value: relative(runtime.snapshot.lastRunAt))
            if let error = runtime.snapshot.lastError {
                StatusRow(title: "Last error", value: error, tone: .bad)
                    .lineLimit(3)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Manual

struct ManualExportView: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var range: Range = .today
    @State private var sending = false

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days", everything = "All history"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section("Period") {
                Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.inline)
                Text("Collection reads HealthKit through the same anchored query as the automatic path — the period only decides how far back a first run looks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Result") {
                StatusRow(title: "New rows", value: "\(runtime.snapshot.collected)")
                StatusRow(title: "Accepted", value: "\(runtime.snapshot.accepted)", tone: .good)
                if let error = runtime.snapshot.lastError {
                    StatusRow(title: "Error", value: error, tone: .bad)
                }
            }
            Section {
                Button {
                    runtime.syncNow(reason: "manual \(range.rawValue)")
                } label: {
                    HStack { Spacer(); Text("Collect and send").bold(); Spacer() }
                }
                .disabled(sending)
                Text("Manual runs go through the same Outbox and the same acknowledgement rules. Nothing here bypasses the queue.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Manual")
    }
}

// MARK: - Automated

struct AutomatedView: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var enabled = AppSettings.automationEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Automatic collection", isOn: $enabled)
                    .onChange(of: enabled) { _, value in AppSettings.automationEnabled = value }
                Text("iOS decides when a background wake-up happens. The collector registers an observer and enables background delivery; it does not promise a schedule.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Last run") {
                StatusRow(title: "Run", value: relative(runtime.snapshot.lastRunAt))
                StatusRow(title: "Success", value: relative(runtime.snapshot.lastSuccessAt))
                StatusRow(title: "Trigger", value: runtime.snapshot.detail)
            }
            Section("Queue") {
                StatusRow(title: "Pending", value: "\(runtime.snapshot.queueDepth)",
                          tone: runtime.snapshot.queueDepth > 0 ? .warn : .good)
                StatusRow(title: "Dead letter", value: "\(runtime.snapshot.deadCount)",
                          tone: runtime.snapshot.deadCount > 0 ? .bad : .good)
                StatusRow(title: "Oldest pending", value: duration(runtime.snapshot.oldestPending))
            }
            Section {
                Text("Background delivery, observer wake-ups and BGTaskScheduler are the only mechanisms available. A force-quit stops transfers until you open the app again — that is an iOS rule, not a setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Automated")
    }
}

// MARK: - Server

struct ServerView: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var url = AppSettings.serverURL
    @State private var token = ""
    @State private var check: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section("Endpoint") {
                TextField("https://host:port", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField(AppSettings.hasToken ? "Token (saved in Keychain)" : "Token", text: $token)
                Button("Save") {
                    AppSettings.serverURL = url
                    if !token.isEmpty { AppSettings.token = token; token = "" }
                }
            }
            Section("Connection") {
                StatusRow(title: "API", value: check ?? "not checked",
                          tone: check == nil ? .neutral : (check == "ok" ? .good : .bad))
                Button(checking ? "Checking…" : "Test connection") {
                    checking = true
                    check = nil
                    runtime.testServer { result in
                        check = result
                        checking = false
                    }
                }
                .disabled(checking || url.isEmpty)
            }
            Section("Sync") {
                StatusRow(title: "Awaiting send", value: "\(runtime.snapshot.queueDepth)")
                StatusRow(title: "Last success", value: relative(runtime.snapshot.lastSuccessAt))
                StatusRow(title: "Last error", value: runtime.snapshot.lastError ?? "none",
                          tone: runtime.snapshot.lastError == nil ? .good : .bad)
                Button("Send now") { runtime.syncNow(reason: "manual from server screen") }
                Text("Uses the existing measurement contract: idempotent by (user, record id), deletes as tombstones, per-record acknowledgement.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Server")
    }
}

// MARK: - Honest placeholders

struct SyncToMacView: View {
    var body: some View {
        List {
            Section {
                Label("Not implemented", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Mac sync needs a receiver on the Mac. Today there is no such receiver, and the app will not show a connected state for something that does not exist. The planned path is the same measurement API over the local network.").font(.caption).foregroundStyle(.secondary)
            }
            Section("What it would take") {
                Text("1. A receiver on the Mac exposing the measurement endpoint.")
                Text("2. Discovery: Bonjour, or a fixed address you enter once.")
                Text("3. The same outbox rules — a Mac is just another server.")
            }
            .font(.callout)
        }
        .navigationTitle("Sync to Mac")
    }
}

struct ShortcutsView: View {
    var body: some View {
        List {
            Section {
                Label("Not implemented", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("App Intents are not written yet. The three planned actions map to existing core calls, so the work is the intent layer, not the logic.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Planned actions") {
                Text("Sync Now — drains the outbox once.")
                Text("Collect Health Data — reads HealthKit into the outbox.")
                Text("Get Collector Status — returns queue depth and last success.")
            }
            .font(.callout)
        }
        .navigationTitle("Shortcuts")
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("Permissions") {
                Text("The app asks for read access to the types it collects. iOS cannot tell an app whether read access was granted: a denied type simply looks empty. Full access and denied access are indistinguishable, and limited access is the only state an app can positively identify.")
            }
            Section("How collection works") {
                Text("An anchored query returns samples added since the stored cursor. Rows are written to the local outbox before the cursor moves, so a crash replays a window instead of skipping it.")
            }
            Section("Delivery") {
                Text("The engine sends batches, and settles a row only when the server names its id as accepted. An unreadable answer is treated as unconfirmed and retried later with backoff — never as success.")
            }
            Section("Troubleshooting") {
                Text("Empty days with data in Apple Health usually mean permissions were revoked for the app. A queue that never drains means the endpoint or token is wrong — check Server.")
            }
        }
        .navigationTitle("Help")
    }
}
