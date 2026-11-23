import SwiftUI

struct BrowseTab: View {
    @ObservedObject var runtime: CollectorRuntime
    private let browse = HealthKitBrowse()
    @State private var latest: [BrowseSample] = []
    @State private var loading = false

    var body: some View {
        List {
            Section {
                if loading && latest.isEmpty {
                    HStack { ProgressView(); Text("Reading Apple Health…").foregroundStyle(.secondary) }
                } else if latest.isEmpty {
                    EmptyStateView(
                        title: "No readings",
                        message: "Either the app has no read permission yet, or Apple Health has no samples for these types. iOS does not distinguish the two."
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(latest) { sample in RecentCard(sample: sample) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Text("Recent").font(.caption).foregroundStyle(.secondary)
            }

            Section("Metrics") {
                ForEach(browse.metrics, id: \.wire) { metric in
                    NavigationLink {
                        MetricDetailView(metric: metric, browse: browse,
                                         last: latest.first { $0.type == metric.wire })
                    } label: {
                        MetricRow(metric: metric, last: latest.first { $0.type == metric.wire })
                    }
                }
            }

            Section {
                NavigationLink("Workouts") { NotImplementedView(feature: "Workouts",
                    reason: "The collector does not read HKWorkout yet; only duration in minutes is mapped today.") }
                NavigationLink("Sleep") { NotImplementedView(feature: "Sleep",
                    reason: "Sleep stages are collected as separate rows, but no sleep screen is built yet.") }
                NavigationLink("Activity") { NotImplementedView(feature: "Activity",
                    reason: "Steps and active energy are shown under Metrics. Rings need stand hours, which are not collected.") }
                NavigationLink("Heart Health") { NotImplementedView(feature: "Heart Health",
                    reason: "HRV, heart rate and resting heart rate live under Metrics.") }
                NavigationLink("Body Measurements") { NotImplementedView(feature: "Body Measurements",
                    reason: "Body metrics are not collected by this app.") }
                NavigationLink("Nutrition") { NotImplementedView(feature: "Nutrition",
                    reason: "Nutrition is not collected by this app.") }
                Text("Categories listed as not implemented are marked honestly: the app never asked for those types, so there is nothing to show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Browse")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        var rows: [BrowseSample] = []
        for metric in browse.metrics {
            if let sample = await browse.latest(for: metric) { rows.append(sample) }
        }
        latest = rows.sorted { $0.date > $1.date }
        loading = false
    }
}

struct RecentCard: View {
    let sample: BrowseSample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sample.title).font(.caption).foregroundStyle(.secondary)
            Text("\(sample.value.formatted(.number.precision(.fractionLength(0...1)))) \(sample.unit)")
                .font(.title3.monospacedDigit())
            Text(relative(sample.date)).font(.caption2).foregroundStyle(.tertiary)
            Text(sample.source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MetricRow: View {
    let metric: HealthKitBrowse.Metric
    let last: BrowseSample?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(metric.title)
                if let last {
                    Text(relative(last.date)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let last {
                Text("\(last.value.formatted(.number.precision(.fractionLength(0...1)))) \(last.unit)")
                    .font(.callout.monospacedDigit())
            } else {
                Text("no data").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MetricDetailView: View {
    let metric: HealthKitBrowse.Metric
    let browse: HealthKitBrowse
    let last: BrowseSample?

    @State private var period: Period = .week
    @State private var rows: [BrowseSample] = []
    @State private var loading = true

    enum Period: String, CaseIterable, Identifiable {
        case day = "24h", week = "7d", month = "30d", quarter = "90d", all = "All"
        var id: String { rawValue }
        var since: Date {
            switch self {
            case .day: return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            case .month: return Date().addingTimeInterval(-30 * 86_400)
            case .quarter: return Date().addingTimeInterval(-90 * 86_400)
            case .all: return .distantPast
            }
        }
    }

    var body: some View {
        List {
            Section {
                if let last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(last.value.formatted(.number.precision(.fractionLength(0...1)))) \(last.unit)")
                            .font(.largeTitle.monospacedDigit())
                        Text("\(last.date.formatted(date: .abbreviated, time: .shortened)) · \(last.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No samples for this type yet.").foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { _, _ in Task { await load() } }
            }

            if !rows.isEmpty {
                Section("Trend") {
                    Sparkline(values: rows.map(\.value))
                        .frame(height: 90)
                    Text("\(rows.count) samples, raw values — nothing is smoothed or averaged.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("Samples") {
                ForEach(rows.suffix(200).reversed()) { row in
                    HStack {
                        Text("\(row.value.formatted(.number.precision(.fractionLength(0...1)))) \(row.unit)")
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Text(row.date.formatted(date: .numeric, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(metric.title)
        .task { await load() }
        .overlay { if loading && rows.isEmpty { ProgressView() } }
    }

    private func load() async {
        loading = true
        rows = await browse.history(for: metric, since: period.since)
        loading = false
    }
}

/// Линия без осей и без сглаживания: показываем форму, но не выдаём её за аналитику.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let minValue = values.min() ?? 0
            let maxValue = values.max() ?? 1
            let span = max(maxValue - minValue, 0.0001)
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                    let y = geometry.size.height * (1 - CGFloat((value - minValue) / span))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct NotImplementedView: View {
    let feature: String
    let reason: String

    var body: some View {
        List {
            Section {
                Label("Not implemented", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(reason).font(.callout)
            }
        }
        .navigationTitle(feature)
    }
}
