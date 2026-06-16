import SwiftUI
import HealthKit
import Combine

struct HRPoint: Identifiable {
    let id = UUID()
    let time: Date
    let bpm: Double
}

struct BreathResult: Identifiable {
    let id = UUID()
    let bpmRate: Double
    let hrvScore: Double
    let durationSeconds: Int
}

final class BreathHRModel: NSObject, ObservableObject {
    @Published var status = "Ready"
    @Published var currentHR: Double?
    @Published var phase = "Press Start"
    @Published var countdown = 0
    @Published var breathCountdown = 0
    @Published var baselineHRV: Double?
    @Published var results: [BreathResult] = []
    @Published var bestRate: Double?
    @Published var bestHRV: Double?
    @Published var isRunning = false

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var heartRates: [HRPoint] = []
    private var phaseRates: [HRPoint] = []

    func start() {
        guard !isRunning else { return }
        isRunning = true
        results = []
        bestRate = nil
        bestHRV = nil
        baselineHRV = nil
        heartRates = []

        Task {
            await requestPermission()
            await MainActor.run { self.status = "Starting workout..." }
            startWorkout()
            await runProtocol()
        }
    }

    private func requestPermission() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate),
              let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            await MainActor.run { self.status = "HealthKit unavailable" }
            return
        }

        let workout = HKObjectType.workoutType()

        do {
            try await healthStore.requestAuthorization(
                toShare: [workout],
                read: [heartRate, hrv]
            )
        } catch {
            await MainActor.run { self.status = "Health permission failed" }
        }
    }

    private func startWorkout() {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            builder = session?.associatedWorkoutBuilder()
            builder?.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )

            session?.delegate = self
            builder?.delegate = self

            let startDate = Date()
            session?.startActivity(with: startDate)
            builder?.beginCollection(withStart: startDate) { _, _ in }
        } catch {
            status = "Workout failed to start"
        }
    }

    private func runProtocol() async {
        await MainActor.run {
            self.status = "Live HR test"
            self.phase = "Reading heart rate..."
            self.countdown = 5
            self.breathCountdown = 0
        }

        for i in stride(from: 5, through: 1, by: -1) {
            await MainActor.run { self.countdown = i }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        await runStage(name: "Baseline", breathRate: nil, seconds: 30)

        let breathRates = [5.0, 5.5, 6.0, 6.5, 7.0]
        let cyclesPerRate = 3.0

        for rate in breathRates {
            let cycleLength = 60.0 / rate
            let duration = Int(ceil(cycleLength * cyclesPerRate))

            await runStage(
                name: "\(rate) breaths/min",
                breathRate: rate,
                seconds: duration
            )
        }

        let best = results.max { $0.hrvScore < $1.hrvScore }

        await MainActor.run {
            self.bestRate = best?.bpmRate
            self.bestHRV = best?.hrvScore
            self.status = "Best rate found"
            self.phase = "Keep breathing"
            self.countdown = 0
        }

        if let rate = best?.bpmRate {
            await runContinuousBreathing(rate: rate)
        }
    }

    private func runStage(name: String, breathRate: Double?, seconds: Int) async {
        await MainActor.run {
            self.status = name
            self.phaseRates = []
            self.countdown = seconds
            self.breathCountdown = 0
        }

        let start = Date()

        while Date().timeIntervalSince(start) < Double(seconds) {
            let elapsed = Date().timeIntervalSince(start)
            let remaining = max(0, seconds - Int(elapsed))

            var instruction = "Relax"
            var breathTimeLeft = 0

            if let rate = breathRate {
                let cycleLength = 60.0 / rate
                let halfCycle = cycleLength / 2.0
                let cyclePosition = elapsed.truncatingRemainder(dividingBy: cycleLength)

                if cyclePosition < halfCycle {
                    instruction = "Breathe in"
                    breathTimeLeft = Int(ceil(halfCycle - cyclePosition))
                } else {
                    instruction = "Breathe out"
                    breathTimeLeft = Int(ceil(cycleLength - cyclePosition))
                }
            }

            await MainActor.run {
                self.phase = instruction
                self.countdown = remaining
                self.breathCountdown = breathTimeLeft
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        let score = calculateHRVLikeScore(from: phaseRates)

        await MainActor.run {
            if breathRate == nil {
                self.baselineHRV = score
            } else if let breathRate {
                self.results.append(
                    BreathResult(
                        bpmRate: breathRate,
                        hrvScore: score,
                        durationSeconds: seconds
                    )
                )
            }
        }
    }

    private func runContinuousBreathing(rate: Double) async {
        let start = Date()

        while true {
            let elapsed = Date().timeIntervalSince(start)
            let cycleLength = 60.0 / rate
            let halfCycle = cycleLength / 2.0
            let cyclePosition = elapsed.truncatingRemainder(dividingBy: cycleLength)

            let instruction: String
            let breathTimeLeft: Int

            if cyclePosition < halfCycle {
                instruction = "Breathe in"
                breathTimeLeft = Int(ceil(halfCycle - cyclePosition))
            } else {
                instruction = "Breathe out"
                breathTimeLeft = Int(ceil(cycleLength - cyclePosition))
            }

            await MainActor.run {
                self.status = "Best: \(rate) breaths/min"
                self.phase = instruction
                self.breathCountdown = breathTimeLeft
                self.countdown = 0
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func calculateHRVLikeScore(from points: [HRPoint]) -> Double {
        let values = points.map { $0.bpm }
        guard values.count >= 2 else { return 0 }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        return sqrt(variance)
    }
}

extension BreathHRModel: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType),
              let stats = workoutBuilder.statistics(for: heartRateType)
        else { return }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let bpm = stats.mostRecentQuantity()?.doubleValue(for: unit)

        DispatchQueue.main.async {
            if let bpm {
                self.currentHR = bpm
                let point = HRPoint(time: Date(), bpm: bpm)
                self.heartRates.append(point)
                self.phaseRates.append(point)
            }
        }
    }
}

extension BreathHRModel: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {}

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.status = "Workout error"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = BreathHRModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(model.status)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(model.phase)
                    .font(.title3)
                    .multilineTextAlignment(.center)

                if model.breathCountdown > 0 {
                    Text("\(model.breathCountdown)")
                        .font(.largeTitle)
                }

                if let hr = model.currentHR {
                    Text("❤️ \(Int(hr)) bpm")
                        .font(.title2)
                } else {
                    Text("No HR yet")
                }

                if model.countdown > 0 {
                    Text("Test: \(model.countdown)s left")
                        .font(.caption)
                }

                if let baseline = model.baselineHRV {
                    Text("Baseline: \(baseline, specifier: "%.2f")")
                        .font(.caption)
                }

                if let bestRate = model.bestRate, let bestHRV = model.bestHRV {
                    Text("Best rate")
                        .font(.headline)
                    Text("\(bestRate, specifier: "%.1f") breaths/min")
                    Text("HRV-like: \(bestHRV, specifier: "%.2f")")
                        .font(.caption)
                }

                ForEach(model.results) { result in
                    Text("\(result.bpmRate, specifier: "%.1f"): \(result.hrvScore, specifier: "%.2f")")
                        .font(.caption2)
                }

                if !model.isRunning {
                    Button("Start") {
                        model.start()
                    }
                }
            }
            .padding()
        }
    }
}
