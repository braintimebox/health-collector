import Foundation
import HealthKit
import SwiftUI

// MARK: - Workouts

struct WorkoutItem: Identifiable {
    let id = UUID()
    let name: String
    let start: Date
    let end: Date
    let minutes: Double
    let energyKcal: Double?
    let distanceKm: Double?
    let source: String
}

struct SleepSegment: Identifiable {
    let id = UUID()
    let stage: SleepStage
    let start: Date
    let end: Date
    var hours: Double { end.timeIntervalSince(start) / 3600 }
}

struct SleepNight: Identifiable {
    let id = UUID()
    let night: Date            // the day the sleep is attributed to
    let segments: [SleepSegment]
    var total: Double { segments.reduce(0) { $0 + $1.hours } }
    func hours(_ stage: SleepStage) -> Double {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.hours }
    }
    var asleep: Double { hours(.core) + hours(.deep) + hours(.rem) + hours(.asleep) }
}

extension HealthKitBrowse {

    /// Workouts are their own sample type, not a quantity: duration comes from
    /// `HKWorkout`, and energy/distance are optional because many workouts carry
    /// neither. Absent is shown as absent, never as zero.
    func workouts(since: Date, limit: Int = 100) async -> [WorkoutItem] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, _ in
                let items = (samples as? [HKWorkout] ?? []).map { workout in
                    WorkoutItem(
                        name: Self.name(for: workout.workoutActivityType),
                        start: workout.startDate,
                        end: workout.endDate,
                        minutes: workout.duration / 60,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)),
                        source: workout.sourceRevision.source.name
                    )
                }
                continuation.resume(returning: items)
            }
            store.execute(query)
        }
    }

    /// Sleep segments exactly as HealthKit stores them: one row per stage.
    /// `awake` only exists between two sleep samples, so a night without stages
    /// is normal and is shown as "no stage data", not as zero sleep.
    func sleepSegments(since: Date, limit: Int = 2000) async -> [SleepSegment] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                let rows = (samples as? [HKCategorySample] ?? []).map { sample in
                    SleepSegment(stage: SleepStage.from(categoryValue: sample.value),
                                 start: sample.startDate, end: sample.endDate)
                }
                continuation.resume(returning: rows)
            }
            store.execute(query)
        }
    }

    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
        case .rowing: return "Rowing"
        case .elliptical: return "Elliptical"
        case .stairClimbing: return "Stairs"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining: return "Core"
        case .flexibility: return "Flexibility"
        case .mindAndBody: return "Mind & Body"
        default: return "Workout"
        }
    }
}

// MARK: - Views

struct WorkoutsView: View {
    let browse: HealthKitBrowse
    @State private var items: [WorkoutItem] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading && items.isEmpty {
                HStack { ProgressView(); Text("Reading workouts…").foregroundStyle(.secondary) }
            } else if items.isEmpty {
                EmptyStateView(title: "No workouts",
                               message: "Either there are none in Apple Health, or the app has no read access. iOS does not distinguish the two.")
            } else {
                ForEach(items) { item in
                    NavigationLink { WorkoutDetailView(item: item) } label: { row(item) }
                }
            }
        }
        .navigationTitle("Workouts")
        .task { items = await browse.workouts(since: Date().addingTimeInterval(-90 * 86_400)); loading = false }
        .refreshable { items = await browse.workouts(since: Date().addingTimeInterval(-90 * 86_400)) }
    }

    private func row(_ item: WorkoutItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                Text(item.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(item.minutes)) min").font(.callout.monospacedDigit())
        }
    }
}

struct WorkoutDetailView: View {
    let item: WorkoutItem

    var body: some View {
        List {
            Section {
                Text(item.name).font(.title2.bold())
                StatusRow(title: "Duration", value: "\(Int(item.minutes)) min")
                StatusRow(title: "Start", value: item.start.formatted(date: .abbreviated, time: .shortened))
                StatusRow(title: "End", value: item.end.formatted(date: .abbreviated, time: .shortened))
                StatusRow(title: "Energy", value: item.energyKcal.map { "\(Int($0)) kcal" } ?? "not recorded")
                StatusRow(title: "Distance", value: item.distanceKm.map { String(format: "%.2f km", $0) } ?? "not recorded")
                StatusRow(title: "Source", value: item.source)
            }
        }
        .navigationTitle("Workout")
    }
}

struct SleepView: View {
    let browse: HealthKitBrowse
    @State private var nights: [SleepNight] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading && nights.isEmpty {
                HStack { ProgressView(); Text("Reading sleep…").foregroundStyle(.secondary) }
            } else if nights.isEmpty {
                EmptyStateView(title: "No sleep data",
                               message: "Apple Health has no sleep samples the app can read. Stage rows only exist when a watch recorded them.")
            } else {
                ForEach(nights) { night in
                    NavigationLink { SleepNightView(night: night) } label: { row(night) }
                }
            }
        }
        .navigationTitle("Sleep")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ night: SleepNight) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(night.night.formatted(date: .abbreviated, time: .omitted)).font(.body)
            Text(String(format: "asleep %.1f h of %.1f h recorded", night.asleep, night.total))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        let segments = await browse.sleepSegments(since: Date().addingTimeInterval(-30 * 86_400))
        nights = Self.group(segments)
        loading = false
    }

    /// A night is attributed to the morning it ends on: a segment ending before
    /// noon belongs to that day, otherwise to the day it started.
    static func group(_ segments: [SleepSegment]) -> [SleepNight] {
        let calendar = Calendar.current
        var buckets: [Date: [SleepSegment]] = [:]
        for segment in segments {
            let hour = calendar.component(.hour, from: segment.end)
            let anchor = hour < 12 ? segment.end : segment.start
            let day = calendar.startOfDay(for: anchor)
            buckets[day, default: []].append(segment)
        }
        return buckets
            .map { SleepNight(night: $0.key, segments: $0.value.sorted { $0.start < $1.start }) }
            .sorted { $0.night > $1.night }
    }
}

struct SleepNightView: View {
    let night: SleepNight

    private let order: [(SleepStage, String)] = [
        (.deep, "Deep"), (.core, "Core"), (.rem, "REM"),
        (.asleep, "Asleep (unspecified)"), (.awake, "Awake"), (.inBed, "In bed"),
        (.unspecified, "Unspecified"),
    ]

    var body: some View {
        List {
            Section {
                StatusRow(title: "Total recorded", value: String(format: "%.1f h", night.total))
                StatusRow(title: "Asleep", value: String(format: "%.1f h", night.asleep))
            }
            Section("Stages") {
                ForEach(order, id: \.0) { stage, title in
                    let hours = night.hours(stage)
                    if hours > 0 {
                        StatusRow(title: title, value: String(format: "%.1f h", hours))
                    }
                }
            }
            Section("Segments") {
                ForEach(night.segments.suffix(60)) { segment in
                    HStack {
                        Text(segment.stage.wireType.replacingOccurrences(of: "sleep_", with: ""))
                            .font(.caption)
                        Spacer()
                        Text(segment.start.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(String(format: "%.1f h", segment.hours)).font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle(night.night.formatted(date: .abbreviated, time: .omitted))
    }
}
