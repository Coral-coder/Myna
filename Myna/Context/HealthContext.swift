import Foundation
import HealthKit

/// Answers "how did I sleep?" and "did I hit my steps?" from Apple Health.
///
/// Read-only, and only four types: sleep, steps, resting heart rate and
/// workouts. Myna never writes to Health, never stores what it reads, and only
/// reads at all when you ask the assistant something about your body.
@MainActor
final class HealthContext: ObservableObject {
    @Published private(set) var hasRequested: Bool

    private let store = HKHealthStore()
    private static let requestedKey = "myna.context.health.requested"

    private let readTypes: Set<HKObjectType> = [
        HKCategoryType(.sleepAnalysis),
        HKQuantityType(.stepCount),
        HKQuantityType(.restingHeartRate),
        HKObjectType.workoutType(),
    ]

    init() {
        hasRequested = UserDefaults.standard.bool(forKey: Self.requestedKey)
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// HealthKit never reveals whether reading was allowed (that itself would
    /// be health information), so "access" here means the sheet was answered;
    /// types you declined simply come back empty.
    func requestAccess() async -> Bool {
        guard Self.isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            hasRequested = true
            UserDefaults.standard.set(true, forKey: Self.requestedKey)
            return true
        } catch {
            return false
        }
    }

    /// One line for the assistant, or nil when there's nothing (or the phone is
    /// locked — Health data is encrypted then).
    func summary(now: Date = .now) async -> String? {
        guard Self.isAvailable, hasRequested else { return nil }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        var parts: [String] = []

        if let sleep = await lastNightSleep(now: now, startOfDay: startOfDay), sleep > 0 {
            parts.append("slept \(HealthMath.spokenDuration(sleep)) last night")
        }
        if let steps = await stepsToday(from: startOfDay, to: now), steps > 0 {
            parts.append("\(steps.formatted()) steps today so far")
        }
        if let resting = await latestRestingHeartRate() {
            parts.append("resting heart rate \(resting) bpm")
        }
        let workouts = await recentWorkouts(since: calendar.date(byAdding: .hour, value: -36, to: now) ?? startOfDay)
        if !workouts.isEmpty {
            parts.append("recent workouts: " + workouts.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : "HEALTH (from Apple Health): " + parts.joined(separator: "; ")
    }

    // MARK: - Queries

    private func lastNightSleep(now: Date, startOfDay: Date) async -> TimeInterval? {
        // From 6 pm yesterday, so a night that started before midnight counts.
        let start = Calendar.current.date(byAdding: .hour, value: -6, to: startOfDay) ?? startOfDay
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: start, end: now))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let samples = try? await descriptor.result(for: store) else { return nil }
        let asleep = HKCategoryValueSleepAnalysis.allAsleepValues
        let intervals = samples
            .filter { HKCategoryValueSleepAnalysis(rawValue: $0.value).map(asleep.contains) ?? false }
            .map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
        return HealthMath.coveredDuration(of: intervals)
    }

    private func stepsToday(from start: Date, to end: Date) async -> Int? {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(.stepCount), predicate: HKQuery.predicateForSamples(withStart: start, end: end)),
            options: .cumulativeSum
        )
        guard let statistics = try? await descriptor.result(for: store),
              let sum = statistics.sumQuantity() else { return nil }
        return Int(sum.doubleValue(for: .count()))
    }

    private func latestRestingHeartRate() async -> Int? {
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.restingHeartRate), predicate: HKQuery.predicateForSamples(withStart: weekAgo, end: .now))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try? await descriptor.result(for: store).first else { return nil }
        return Int(sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
    }

    private func recentWorkouts(since start: Date) async -> [String] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForSamples(withStart: start, end: .now))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 5
        )
        guard let workouts = try? await descriptor.result(for: store) else { return [] }
        return workouts.map { workout in
            let when = workout.startDate.formatted(date: .abbreviated, time: .shortened)
            return "\(Self.name(of: workout.workoutActivityType)) for \(HealthMath.spokenDuration(workout.duration)) (\(when))"
        }
    }

    private static func name(of type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "run"
        case .walking: return "walk"
        case .hiking: return "hike"
        case .cycling: return "ride"
        case .swimming: return "swim"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .rowing: return "row"
        case .elliptical: return "elliptical"
        case .dance: return "dance"
        case .pilates: return "pilates"
        default: return "workout"
        }
    }
}
