import Foundation
import HealthKit
import Combine

final class WorkoutManager: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    @Published var heartRate: Double = 0
    @Published var samples: [(Date, Double)] = []
    @Published var isRunning = false

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        let typesToShare: Set = [
            HKObjectType.workoutType()
        ]

        let typesToRead: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!
        ]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { success, error in
            print("HealthKit auth:", success, error?.localizedDescription ?? "")
        }
    }

    func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .unknown

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            builder = session?.associatedWorkoutBuilder()
        } catch {
            print("Workout session error:", error)
            return
        }

        builder?.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: config
        )

        session?.delegate = self
        builder?.delegate = self

        let startDate = Date()
        session?.startActivity(with: startDate)
        builder?.beginCollection(withStart: startDate) { success, error in
            print("Begin collection:", success, error?.localizedDescription ?? "")
        }

        DispatchQueue.main.async {
            self.isRunning = true
            self.samples.removeAll()
        }
    }

    func stopWorkout() {
        session?.end()
        isRunning = false
    }

    func exportCSV() -> String {
        var csv = "timestamp,heart_rate_bpm\n"
        let formatter = ISO8601DateFormatter()

        for sample in samples {
            csv += "\(formatter.string(from: sample.0)),\(sample.1)\n"
        }

        return csv
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .ended {
            builder?.endCollection(withEnd: date) { success, error in
                self.builder?.finishWorkout { workout, error in
                    print("Workout finished:", workout?.uuid.uuidString ?? "", error?.localizedDescription ?? "")
                }
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout failed:", error)
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        guard collectedTypes.contains(HKQuantityType.quantityType(forIdentifier: .heartRate)!) else {
            return
        }

        let stats = workoutBuilder.statistics(for: HKQuantityType.quantityType(forIdentifier: .heartRate)!)
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())

        guard let value = stats?.mostRecentQuantity()?.doubleValue(for: unit) else {
            return
        }

        DispatchQueue.main.async {
            self.heartRate = value
            self.samples.append((Date(), value))
        }
    }
}
