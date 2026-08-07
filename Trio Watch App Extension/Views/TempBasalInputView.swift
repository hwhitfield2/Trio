import Foundation
import SwiftUI
import WatchKit

// MARK: - Temp Basal Input View

struct TempBasalInputView: View {
    @Binding var navigationPath: NavigationPath
    @State private var rate = 0.0
    @State private var durationMinutes = 30

    let state: WatchState

    @FocusState private var isCrownFocused: Bool

    private let rateIncrement = 0.05
    private let durationIncrement = 30
    private let maxDurationMinutes = 720

    private var effectiveBasalLimit: Double {
        Double(truncating: state.maxBasal as NSNumber)
    }

    var trioBackgroundColor = LinearGradient(
        gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        VStack {
            if effectiveBasalLimit <= 0 {
                VStack(spacing: 8) {
                    Text("Basal limit cannot be fetched from phone!").font(.headline)
                    Text("Check device settings, connect to phone, and try again.").font(.caption)
                }
                .scenePadding()
            } else {
                Spacer()

                HStack {
                    // "-" Button
                    Button(action: {
                        if rate > 0 { rate = max(0, rate - rateIncrement) }
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .tint(Color.insulin)
                    }
                    .buttonStyle(.borderless)
                    .disabled(rate <= 0)

                    Spacer()

                    let adjustedRate = (rate / rateIncrement).rounded() * rateIncrement

                    Text(String(format: "%.2f \(String(localized: "U/hr", comment: "Basal rate unit"))", adjustedRate))
                        .fontWeight(.bold)
                        .font(.system(.title3, design: .rounded))
                        .foregroundColor(rate > 0.0 && rate >= effectiveBasalLimit ? .loopRed : .primary)
                        .focusable(true)
                        .focused($isCrownFocused)
                        .digitalCrownRotation(
                            $rate,
                            from: 0,
                            through: effectiveBasalLimit,
                            by: rateIncrement,
                            sensitivity: .medium,
                            isContinuous: false,
                            isHapticFeedbackEnabled: true
                        )

                    Spacer()

                    // "+" Button
                    Button(action: {
                        rate = min(effectiveBasalLimit, rate + rateIncrement)
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .tint(Color.insulin)
                    }
                    .buttonStyle(.borderless)
                    .disabled(rate >= effectiveBasalLimit)
                }.padding(.horizontal)

                Text("Rate")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack {
                    // "-" Button
                    Button(action: {
                        durationMinutes = max(durationIncrement, durationMinutes - durationIncrement)
                    }) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .tint(Color.insulin)
                    }
                    .buttonStyle(.borderless)
                    .disabled(durationMinutes <= durationIncrement)

                    Spacer()

                    Text("\(durationMinutes) \(String(localized: "min", comment: "Minutes abbreviation"))")
                        .fontWeight(.bold)
                        .font(.system(.title3, design: .rounded))

                    Spacer()

                    // "+" Button
                    Button(action: {
                        durationMinutes = min(maxDurationMinutes, durationMinutes + durationIncrement)
                    }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .tint(Color.insulin)
                    }
                    .buttonStyle(.borderless)
                    .disabled(durationMinutes >= maxDurationMinutes)
                }.padding(.horizontal)

                Text("Duration")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Spacer()

                if rate > 0.0 && rate >= effectiveBasalLimit {
                    Text("Max Basal Reached!")
                        .font(.footnote)
                        .foregroundColor(.loopRed)
                }

                Button("Set Temp Basal") {
                    state.tempBasalRate = min(rate, effectiveBasalLimit)
                    state.tempBasalDurationMinutes = durationMinutes
                    state.sendTempBasalRequest(rate: state.tempBasalRate, durationMinutes: state.tempBasalDurationMinutes)
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
                .buttonStyle(.bordered)
                .tint(Color.insulin)
                .disabled(durationMinutes <= 0 || rate > effectiveBasalLimit)
            }
        }
        .background(trioBackgroundColor)
        .navigationTitle("Temp Basal")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Image(systemName: "chart.bar.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .padding()
                    .background(Color.insulin)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
    }
}
