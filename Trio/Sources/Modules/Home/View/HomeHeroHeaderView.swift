import CoreData
import SwiftUI

/// Hero glucose header from the glass redesign: gradient accent bar, large rounded
/// glucose value with trend arrow, and a delta / units / minutes-ago line.
/// Mirrors CurrentGlucoseView's value, color, delta and trend-rotation logic exactly.
struct HomeHeroGlucoseView: View {
    let timerDate: Date
    let units: GlucoseUnits
    let lowGlucose: Decimal
    let highGlucose: Decimal
    let cgmAvailable: Bool
    var currentGlucoseTarget: Decimal
    let glucoseColorScheme: GlucoseColorScheme
    let glucose: [GlucoseStored] // last two readings, ascending (.last = newest)

    @State private var rotationDegrees: Double = 0.0

    @Environment(\.colorScheme) var colorScheme

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        if units == .mmolL {
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 1
            formatter.roundingMode = .halfUp
        } else {
            formatter.maximumFractionDigits = 0
        }
        formatter.positivePrefix = "+"
        formatter.negativePrefix = "-"
        return formatter
    }

    private var glucoseDisplayColor: Color {
        guard let glucoseValue = glucose.last?.glucose else { return .secondary }

        // Same workaround as CurrentGlucoseView: dynamic scheme interpolates between
        // hardcoded 55/220 bounds for smoother shades outside the user thresholds.
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        guard Decimal(glucoseValue) <= lowGlucose || Decimal(glucoseValue) >= highGlucose else {
            return .primary
        }

        return Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(glucoseValue),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    private var delta: String {
        guard glucose.count >= 2 else {
            return "--"
        }

        var lastGlucose = Decimal(glucose.last?.glucose ?? 0)
        var secondLastGlucose = Decimal(glucose.first?.glucose ?? 0)
        if units == .mmolL {
            lastGlucose = lastGlucose.asMmolL
            secondLastGlucose = secondLastGlucose.asMmolL
        }
        let delta = lastGlucose - secondLastGlucose
        return deltaFormatter.string(from: delta as NSNumber) ?? "--"
    }

    var body: some View {
        if cgmAvailable {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GlassDesign.accentGradient)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .center, spacing: 10) {
                        Group {
                            if let glucoseValue = glucose.last?.glucose {
                                let displayGlucose = units == .mgdL
                                    ? Decimal(glucoseValue).description
                                    : Decimal(glucoseValue).formattedAsMmolL
                                Text(glucoseValue == 400 ? "HIGH" : displayGlucose)
                                    .foregroundStyle(glucoseDisplayColor)
                            } else {
                                Text("--")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .kerning(-0.5)

                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.glassCyan)
                            .rotationEffect(.degrees(rotationDegrees))
                            .padding(.top, 4)
                    }

                    HStack(spacing: 8) {
                        Text(delta)
                            .font(.system(.callout, design: .rounded))
                            .fontWeight(.semibold)
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                        Text(units.rawValue)
                        Text(verbatim: "·").opacity(0.5)
                        Text(TimeAgoFormatter.minutesAgo(from: glucose.last?.date) + " " + String(localized: "ago"))
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: glucose.last?.directionEnum) {
                withAnimation {
                    switch glucose.last?.directionEnum {
                    case .doubleUp,
                         .singleUp,
                         .tripleUp:
                        rotationDegrees = -90
                    case .fortyFiveUp:
                        rotationDegrees = -45
                    case .flat:
                        rotationDegrees = 0
                    case .fortyFiveDown:
                        rotationDegrees = 45
                    case .doubleDown,
                         .singleDown,
                         .tripleDown:
                        rotationDegrees = 90
                    case nil,
                         .notComputable,
                         .rateOutOfRange:
                        rotationDegrees = 0
                    default:
                        rotationDegrees = 0
                    }
                }
            }
        } else {
            HStack(alignment: .center, spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(GlassDesign.accentGradient)
                    .frame(width: 4, height: 56)

                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .font(.title2)
                    Text("Add CGM")
                        .font(.caption).bold()
                }
            }
        }
    }
}

/// Loop pill + status caption for the trailing side of the hero header.
/// Wraps the existing LoopView (freshness colors, spinner, minutes-ago label).
struct HomeLoopPillView: View {
    let closedLoop: Bool
    let timerDate: Date
    let isLooping: Bool
    let lastLoopDate: Date
    let manualTempBasal: Bool
    let determination: [OrefDetermination]

    private var caption: String {
        if manualTempBasal {
            return String(localized: "Manual")
        } else if !closedLoop {
            return String(localized: "Open Loop")
        }
        return String(localized: "Looping")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            LoopView(
                closedLoop: closedLoop,
                timerDate: timerDate,
                isLooping: isLooping,
                lastLoopDate: lastLoopDate,
                manualTempBasal: manualTempBasal,
                determination: determination
            )
            Text(caption)
                .glassCaption()
        }
    }
}
