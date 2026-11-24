import SwiftUI
import HealthCollectorCore

struct SettingsTab: View {
    @ObservedObject var runtime: CollectorRuntime
    var initialRoute: String?
    @State private var pushed: String?

    var body: some View {
        List {
            Section {
                NavigationLink("Health Permissions") { PermissionsView(runtime: runtime) }
                NavigationLink("Export Settings") { ExportSettingsView(runtime: runtime) }
                NavigationLink("Unit Preferences") { UnitPreferencesView() }
                NavigationLink("Advanced") { AdvancedView(runtime: runtime) }
                NavigationLink("Notifications") { NotificationsView() }
                NavigationLink("About") { AboutView() }
                Text("Every value on these screens comes from the collector's stored state or from HealthKit. Nothing is a demo value.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationDestination(item: $pushed) { title in
            switch title {
            case "Advanced": AdvancedView(runtime: runtime)
            case "Health Permissions": PermissionsView(runtime: runtime)
            case "Export Settings": ExportSettingsView(runtime: runtime)
            case "Unit Preferences": UnitPreferencesView()
            case "Notifications": NotificationsView()
            case "About": AboutView()
            // A deep link we do not know must not render a blank screen that looks
            // like a broken transition.
            default: Text("Unknown screen: \(title)")
            }
        }
        .onAppear {
            if pushed == nil, let initialRoute { pushed = initialRoute }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Permissions

struct PermissionsView: View {
    @ObservedObject var runtime: CollectorRuntime

    var body: some View {
        List {
            Section {
                StatusRow(title: "Request", value: runtime.state.permissionLabel)
                Text("iOS does not tell an app whether read access was granted. A refused type looks exactly like a type with no data, and limited access is the only state an app can positively identify. This screen therefore reports what was requested, not a false \"Connected\".").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Open Apple Health") {
                    if let url = URL(string: "x-apple-health://") { UIApplication.shared.open(url) }
                }
                Button("Request access again") { runtime.requestPermissions() }
            }
            Section("How to check manually") {
                Text("Health app → profile picture → Privacy → Apps → Health Collector. Read access is listed per type there, and only you can see it.")
                    .font(.callout)
            }
        }
        .navigationTitle("Health Permissions")
    }
}

// MARK: - Export settings

struct ExportSettingsView: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var automated = AppSettings.automationEnabled
    @State private var url = AppSettings.serverURL

    var body: some View {
        Form {
            Section {
                Toggle("Automatic collection", isOn: $automated)
                    .onChange(of: automated) { _, value in runtime.setAutomation(value) }
                    // Both screens read the same runtime state, so a change made on
                    // one is not invisible on the other.
                    .onAppear { automated = runtime.state.automationEnabled }
                Text("When off, the collector only runs when you open the app or press Sync. Background wakes are requested from iOS either way; it decides when they happen.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Server") {
                TextField("Endpoint", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save endpoint") {
                    switch ServerEndpoint.parse(url) {
                    case .success(let endpoint):
                        url = endpoint.url.absoluteString
                        AppSettings.serverURL = endpoint.url.absoluteString
                    case .failure(.empty):
                        AppSettings.serverURL = ""
                    case .failure:
                        // Same refusal as the Server screen: the field keeps what was
                        // typed, the stored endpoint keeps what was proven to work.
                        break
                    }
                }
                Text("Only https is accepted (plain http for loopback). An empty or invalid address means “not configured” — the collector keeps readings in the queue and sends nothing.").font(.caption).foregroundStyle(.secondary)
                StatusRow(title: "Token", value: AppSettings.hasToken ? "stored in Keychain" : "not set",
                          tone: AppSettings.hasToken ? .good : .warn)
            }
            Section("Collected types") {
                ForEach(HealthKitSource.supportedTypes, id: \.self) { type in
                    Text(type).font(.callout.monospaced())
                }
            }
        }
        .navigationTitle("Export Settings")
    }
}

// MARK: - Units

struct UnitPreferencesView: View {
    var body: some View {
        List {
            Section {
                Label("Not implemented", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Stored values keep the unit the server validated (ms, count/min, kcal, h, min). Display conversion would live here and would never rewrite stored rows — changing stored units retroactively would break the series.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Planned") {
                Text("Distance: km / mi")
                Text("Energy: kcal / kJ")
                Text("Weight: kg / lb")
                Text("Temperature: °C / °F")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Unit Preferences")
    }
}

// MARK: - Advanced

struct AdvancedView: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var copied = false

    var body: some View {
        List {
            Section("Collector") {
                StatusRow(title: "Queue depth", value: "\(runtime.state.queueDepth)",
                          tone: runtime.state.queueDepth > 0 ? .warn : .good)
                StatusRow(title: "Pending records", value: "\(runtime.state.queueDepth)")
                StatusRow(title: "Dead letter", value: "\(runtime.state.deadCount)",
                          tone: runtime.state.deadCount > 0 ? .bad : .good)
                StatusRow(title: "Oldest pending", value: duration(runtime.state.oldestPending))
            }
            Section("Activity") {
                StatusRow(title: "Last collection", value: relative(runtime.state.lastRunAt))
                StatusRow(title: "Last successful sync", value: relative(runtime.state.lastSuccessAt))
                StatusRow(title: "Last error", value: runtime.state.lastError ?? "none",
                          tone: runtime.state.lastError == nil ? .good : .bad)
                StatusRow(title: "Trigger", value: runtime.state.triggerLabel)
            }
            Section("HealthKit") {
                StatusRow(title: "Authorization", value: runtime.state.permissionLabel)
                StatusRow(title: "Background delivery", value: runtime.state.backgroundLabel)
            }
            Section("Server") {
                StatusRow(title: "Endpoint", value: AppSettings.serverURL)
                StatusRow(title: "Connectivity", value: runtime.state.connectionLabel)
            }
            Section {
                Button(copied ? "Copied" : "Copy diagnostics") {
                    UIPasteboard.general.string = runtime.diagnosticsText()
                    copied = true
                }
                Text("The export contains counts, timestamps and the endpoint host. It never contains the token or any measurement values.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Advanced")
    }
}

// MARK: - Notifications, About

struct NotificationsView: View {
    var body: some View {
        List {
            Section {
                Label("Not implemented", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Local notifications for sync failures need an authorisation request and a notification scheduler; neither is written. Nothing here pretends to be enabled.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Planned") {
                Text("Sync errors")
                Text("Connection problems")
                Text("Queue stuck for more than a day")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Notifications")
    }
}

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                StatusRow(title: "Version", value: version)
                StatusRow(title: "Bundle", value: Bundle.main.bundleIdentifier ?? "?")
            }
            Section("What this app is") {
                Text("A collector: it reads Apple Health, keeps an outbox on disk, and delivers measurements to your own server. The server is where the history lives — the phone is a courier.")
                    .font(.callout)
            }
            Section("What it is not") {
                Text("It does not analyse your data, does not send anything to a third party, and cannot guarantee a wake-up time. Those are platform limits, not missing features.")
                    .font(.callout)
            }
        }
        .navigationTitle("About")
    }
}
