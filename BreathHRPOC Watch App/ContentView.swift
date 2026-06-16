import SwiftUI

struct ContentView: View {
    @StateObject private var workout = WorkoutManager()

    var body: some View {
        VStack(spacing: 12) {
            Text("\(Int(workout.heartRate)) bpm")
                .font(.title2)

            Text("Samples: \(workout.samples.count)")
                .font(.caption)

            if workout.isRunning {
                Button("Stop") {
                    workout.stopWorkout()
                }
            } else {
                Button("Start") {
                    workout.startWorkout()
                }
            }
        }
        .onAppear {
            workout.requestAuthorization()
        }
    }
}
