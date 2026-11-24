import SwiftUI

/// Three tabs, one navigation stack each, so switching tabs keeps both the
/// scroll position and the pushed detail screen.
struct AppShell: View {
    @ObservedObject var runtime: CollectorRuntime
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Tab = AppShell.initialTab
    private let route = AppShell.initialRoute

    enum Tab: Hashable { case export, browse, settings }

    /// A screenshot job needs each screen without driving the UI, and a URL is not a
    /// reliable way to get there: the first attempt delivered nothing and produced
    /// three pictures of the same tab while the job stayed green. A launch argument
    /// cannot be dropped, because the value is read before the first render.
    /// A nested screen a capture run may land on: `Server` lives under Export,
    /// `Advanced` under Settings.
    static var initialRoute: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-initialRoute"), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    static var initialTab: Tab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-initialTab"), index + 1 < arguments.count else {
            return .export
        }
        switch arguments[index + 1] {
        case "browse": return .browse
        case "settings": return .settings
        default: return .export
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { ExportTab(runtime: runtime, initialRoute: selection == .export ? route : nil) }
                .tabItem { Label("Export", systemImage: "hand.tap") }
                .tag(Tab.export)

            NavigationStack { BrowseTab(runtime: runtime, initialRoute: selection == .browse ? route : nil) }
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                .tag(Tab.browse)

            NavigationStack { SettingsTab(runtime: runtime, initialRoute: selection == .settings ? route : nil) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task { runtime.start() }
        // Returning to the app is a collection trigger like any other, so it goes
        // through the same gate: with the switch off this call decides to skip and
        // the panel says so, instead of quietly collecting anyway.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runtime.syncNow(trigger: .foreground) }
        }
        // Three tabs are also three addresses: `healthcollector://browse` is what a
        // screenshot job, and later a Shortcut, uses to land on a screen without
        // driving the UI.
        .onOpenURL { url in
            switch url.host {
            case "browse": selection = .browse
            case "settings": selection = .settings
            default: selection = .export
            }
        }
    }
}

/// Строка статуса: одно место, где решается, как выглядит неизвестное состояние.
/// «Неизвестно» не показывается как «всё хорошо» — это отдельный цвет и отдельный текст.
struct StatusRow: View {
    let title: String
    let value: String
    var tone: Tone = .neutral

    enum Tone { case neutral, good, warn, bad }

    var body: some View {
        HStack {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.monospaced())
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch tone {
        case .neutral: return .primary
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        }
    }
}

func relative(_ date: Date?) -> String {
    guard let date else { return "never" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

func duration(_ interval: TimeInterval?) -> String {
    guard let interval, interval > 0 else { return "—" }
    if interval < 3600 { return "\(Int(interval / 60)) min" }
    if interval < 86_400 { return String(format: "%.1f h", interval / 3600) }
    return String(format: "%.1f d", interval / 86_400)
}
