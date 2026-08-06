import SwiftUI

/// Menu shown when tapping the IOB icon on the main watch view.
/// Offers pump actions: suspending/resuming insulin delivery and setting a temp basal.
struct InsulinMenuView: View {
    let state: WatchState
    var onActionSent: () -> Void // Callback to dismiss the sheet and show the acknowledgment view
    var onSetTempBasal: () -> Void // Callback to dismiss the sheet and open the temp basal input

    @State private var showingSuspendConfirmation = false
    @State private var showingResumeConfirmation = false

    var body: some View {
        NavigationView {
            List {
                if state.isPumpSuspended {
                    Button {
                        showingResumeConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(Color.loopGreen)
                            Text("Resume Insulin")
                        }
                    }
                    .confirmationDialog(
                        "Resume insulin delivery?",
                        isPresented: $showingResumeConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Resume") {
                            state.sendPumpResumeRequest()
                            onActionSent()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                } else {
                    Button {
                        showingSuspendConfirmation = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "pause.circle.fill")
                                .foregroundStyle(Color.loopRed)
                            Text("Suspend Insulin")
                        }
                    }
                    .confirmationDialog(
                        "Suspend insulin delivery?",
                        isPresented: $showingSuspendConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Suspend", role: .destructive) {
                            state.sendPumpSuspendRequest()
                            onActionSent()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }

                Button {
                    onSetTempBasal()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(Color.insulin)
                        Text("Set Temp Basal")
                    }
                }

                if state.isPumpSuspended {
                    Text("Insulin delivery is currently suspended.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Insulin")
        }
    }
}
