import SwiftUI

/// Three tabs, one navigation stack each, so switching tabs keeps both the
/// scroll position and the pushed detail screen.
struct AppShell: View {
    @ObservedObject var runtime: CollectorRuntime
    @State private var selection: Tab = .export

    enum Tab: Hashable { case export, browse, settings }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { ExportTab(runtime: runtime) }
                .tabItem { Label("Export", systemImage: "hand.tap") }
                .tag(Tab.export)

            NavigationStack { BrowseTab(runtime: runtime) }
                .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
                .tag(Tab.browse)

            NavigationStack { SettingsTab(runtime: runtime) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task { runtime.start() }
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
