import CoreData
import SpriteKit
import SwiftDate
import SwiftUI
import Swinject

struct TimePicker: Identifiable {
    var active: Bool
    let hours: Int16
    var id: String { hours.description }
}

/// A pending preset activation from a dock chip, awaiting the
/// "Require Adjustments Confirmation" dialog.
struct DockChipActivation: Identifiable {
    let id = UUID()
    let name: String
    let isOverride: Bool
    let objectID: NSManagedObjectID
}

extension Home {
    struct RootView: BaseView {
        let resolver: Resolver
        let safeAreaSize: CGFloat = 0.08

        @Environment(\.managedObjectContext) var moc
        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        @State var state = StateModel()

        @State var settingsPath = NavigationPath()
        @State var settingsSearchHighlight = SettingsSearchHighlight()
        @State var isStatusPopupPresented = false
        @State var showCancelAlert = false
        @State var showCancelConfirmDialog = false
        @State var isConfirmStopOverrideShown = false
        @State var isConfirmStopOverridePresented = false
        @State var isConfirmStopTempTargetShown = false
        @State var isMenuPresented = false
        @State var showTreatments = false
        @State var selectedTab: Int = 0
        @State var showPumpSelection: Bool = false
        @State var showCGMSelection: Bool = false
        @State var notificationsDisabled = false
        @State var timeButtons: [TimePicker] = [
            TimePicker(active: false, hours: 4),
            TimePicker(active: false, hours: 6),
            TimePicker(active: false, hours: 12),
            TimePicker(active: false, hours: 24)
        ]

        /// Adjustments state powering the dock's preset chip enacting; wired
        /// lazily on first chip use (same DI path Adjustments.RootView uses).
        @State var adjustmentsState = Adjustments.StateModel()
        @State var activeTileDetail: HomeTileDetail?
        @State var showQuickActions = false
        @State var activeEntryKind: HomeEntryKind?
        @State var showDockSheet = false
        @State var plusButtonPressed = false
        @State var dockToastText: String?
        @State var pendingChipActivation: DockChipActivation?

        @FetchRequest(fetchRequest: OverrideStored.fetch(
            NSPredicate.lastActiveOverride,
            ascending: false,
            fetchLimit: 1
        )) var latestOverride: FetchedResults<OverrideStored>

        @FetchRequest(fetchRequest: TempTargetStored.fetch(
            NSPredicate.lastActiveTempTarget,
            ascending: false,
            fetchLimit: 1
        )) var latestTempTarget: FetchedResults<TempTargetStored>

        // Live preset lists for the dock chips (same predicate/order as the
        // Adjustments screen); enact/cancel still routes through adjustmentsState.
        @FetchRequest(fetchRequest: {
            let request = OverrideStored.fetchRequest()
            request.predicate = NSPredicate.allOverridePresets
            request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
            return request
        }()) var overridePresetChips: FetchedResults<OverrideStored>

        @FetchRequest(fetchRequest: {
            let request = TempTargetStored.fetchRequest()
            request.predicate = NSPredicate.allTempTargetPresets
            request.sortDescriptors = [NSSortDescriptor(key: "orderPosition", ascending: true)]
            return request
        }()) var tempTargetPresetChips: FetchedResults<TempTargetStored>

        var bolusProgressFormatter: NumberFormatter {
            let fractionDigits: Int = switch state.settingsManager.preferences.bolusIncrement {
            case 0.1: 1
            case 0.025: 3
            default: 2
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = fractionDigits
            formatter.minimumFractionDigits = fractionDigits
            formatter.allowsFloats = true
            formatter.roundingIncrement = Double(state.settingsManager.preferences.bolusIncrement) as NSNumber
            return formatter
        }

        private var fetchedTargetFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumFractionDigits = 1
            } else { formatter.maximumFractionDigits = 0 }
            return formatter
        }

        private var historySFSymbol: String {
            if #available(iOS 17.0, *) {
                return "book.pages"
            } else {
                return "book"
            }
        }

        @ViewBuilder func pumpTimezoneView(_ badgeImage: UIImage, _ badgeColor: Color) -> some View {
            HStack {
                Image(uiImage: badgeImage.withRenderingMode(.alwaysTemplate))
                    .font(.system(size: 14))
                    .colorMultiply(badgeColor)
                Text(String(localized: "Time Change Detected", comment: ""))
                    .bold()
                    .font(.system(size: 14))
                    .foregroundStyle(badgeColor)
            }
            .onTapGesture {
                if state.pumpDisplayState != nil {
                    // sends user to pump settings
                    state.shouldDisplayPumpSetupSheet.toggle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .overlay(
                Capsule()
                    .stroke(badgeColor.opacity(0.4), lineWidth: 2)
            )
        }

        var cgmSelectionButtons: some View {
            ForEach(cgmOptions, id: \.name) { option in
                if let cgm = state.listOfCGM.first(where: option.predicate) {
                    Button(option.name) {
                        state.addCGM(cgm: cgm)
                    }
                }
            }
        }

        /// Tap behavior shared by the hero glucose value and the CGM tile:
        /// CGM selection dialog when none is set up, else CGM settings.
        func handleCGMTap() {
            if !state.cgmAvailable {
                showCGMSelection.toggle()
            } else {
                state.shouldDisplayCGMSetupSheet.toggle()
            }
        }

        /// Tap behavior shared by the pump tiles: pump-model dialog when no pump
        /// is set up, else pump settings.
        func handlePumpTap() {
            if state.pumpDisplayState == nil {
                // shows user confirmation dialog with pump model choices, then proceeds to setup
                showPumpSelection.toggle()
            } else {
                // sends user to pump settings
                state.shouldDisplayPumpSetupSheet.toggle()
            }
        }

        var basalString: String? {
            var rate: NSNumber = 0
            var manualBasalString = ""

            guard let apsManager = state.apsManager else {
                return nil
            }

            if apsManager.isScheduledBasal == true {
                guard let scheduledRate = scheduledBasalDeliveryRate(at: Date()) else {
                    return nil
                }
                rate = scheduledRate
            } else {
                guard let lastTempBasal = state.tempBasals.last?.tempBasal, let tempRate = lastTempBasal.rate else {
                    return nil
                }
                if apsManager.isManualTempBasal {
                    manualBasalString = String(
                        localized: " - Manual Basal ⚠️",
                        comment: "Manual Temp basal"
                    )
                }
                rate = tempRate
            }

            let rateString = Formatter.decimalFormatterWithThreeFractionDigits.string(from: rate) ?? "0"
            return rateString + String(localized: " U/hr", comment: "Unit per hour with space") +
                manualBasalString
        }

        // Returns the scheduled basal rate for the current time based on the saved basal scheduled.
        // Would be better if in the future BasalDeliveryStatus could be updated to include this info.
        func scheduledBasalDeliveryRate(at when: Date) -> NSNumber? {
            let calendar = Calendar(identifier: .gregorian)
            // calendar.timeZone = timeZone /// should come from pumpManager in case it's different!

            let hours = calendar.component(.hour, from: when)
            let minutes = calendar.component(.minute, from: when)
            let totalMinutes = hours * 60 + minutes

            if let rate = findBasalRateForOffset(for: totalMinutes, in: state.basalProfile) {
                return NSDecimalNumber(decimal: rate)
            }
            return nil
        }

        var overrideString: String? {
            guard let latestOverride = latestOverride.first else {
                return nil
            }

            guard let settingsManager = state.settingsManager else {
                return nil
            }

            let percent = latestOverride.percentage
            let percentString = percent == 100 ? "" : "\(percent.formatted(.number)) %"

            let unit = state.units
            var target = (latestOverride.target ?? 0) as Decimal
            target = unit == .mmolL ? target.asMmolL : target

            var targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " + unit
                .rawValue
            if tempTargetString != nil {
                targetString = ""
            }

            let duration = latestOverride.duration ?? 0
            let addedMinutes = Int(truncating: duration)
            let date = latestOverride.date ?? Date()
            let newDuration = max(
                Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
                0
            )
            let indefinite = latestOverride.indefinite
            var durationString = ""

            if !indefinite {
                if newDuration >= 1 {
                    durationString = formatHrMin(Int(newDuration))
                } else if newDuration > 0 {
                    durationString = "\(Int(newDuration * 60)) s"

                } else {
                    /// Do not show the Override anymore
                    Task {
                        guard let objectID = self.latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: objectID)
                    }
                }
            }

            let smbScheduleString = latestOverride
                .smbIsScheduledOff && ((latestOverride.start?.stringValue ?? "") != (latestOverride.end?.stringValue ?? ""))
                ? " \(formatTimeRange(start: latestOverride.start?.stringValue, end: latestOverride.end?.stringValue))"
                : ""

            let smbToggleString = latestOverride.smbIsOff || latestOverride
                .smbIsScheduledOff ? String(localized: "SMBs Off\(smbScheduleString)") : ""

            var smbMinuteString: String = ""
            var uamMinuteString: String = ""

            if !latestOverride.smbIsOff, latestOverride.advancedSettings {
                if let smbMinutes = latestOverride.smbMinutes,
                   smbMinutes.decimalValue != settingsManager.preferences.maxSMBBasalMinutes
                {
                    smbMinuteString = "SMB\u{00A0}\(smbMinutes)\u{00A0}" +
                        String(localized: "m", comment: "Abbreviation for Minutes")
                }

                if let uamMinutes = latestOverride.uamMinutes,
                   uamMinutes.decimalValue != settingsManager.preferences.maxUAMSMBBasalMinutes
                {
                    uamMinuteString = "UAM\u{00A0}\(uamMinutes)\u{00A0}" +
                        String(localized: "m", comment: "Abbreviation for Minutes")
                }
            }

            let components = [durationString, percentString, targetString, smbToggleString, smbMinuteString, uamMinuteString]
                .filter { !$0.isEmpty }
            return components.isEmpty ? nil : components.joined(separator: ", ")
        }

        var tempTargetString: String? {
            guard let latestTempTarget = latestTempTarget.first else {
                return nil
            }
            let duration = latestTempTarget.duration
            let addedMinutes = Int(truncating: duration ?? 0)
            let date = latestTempTarget.date ?? Date()
            let newDuration = max(
                Decimal(Date().distance(to: date.addingTimeInterval(addedMinutes.minutes.timeInterval)).minutes),
                0
            )
            var durationString = ""
            var percentageString = ""
            var target = (latestTempTarget.target ?? 100) as Decimal
            // Use TempTargetCalculations to get effective HBT (handles both custom and auto-adjusted standard TT)
            let effectiveHBT = TempTargetCalculations.computeEffectiveHBT(
                tempTargetHalfBasalTarget: latestTempTarget.halfBasalTarget?.decimalValue,
                settingHalfBasalTarget: state.settingHalfBasalTarget,
                target: target,
                autosensMax: state.autosensMax
            ) ?? state.settingHalfBasalTarget
            var showPercentage = false
            if target > 100, state.isExerciseModeActive || state.highTTraisesSens { showPercentage = true }
            if target < 100, state.lowTTlowersSens, state.autosensMax > 1 { showPercentage = true }
            if showPercentage {
                percentageString =
                    " \(Int(TempTargetCalculations.computeAdjustedPercentage(halfBasalTarget: effectiveHBT, target: target, autosensMax: state.autosensMax)))%"
            }
            target = state.units == .mmolL ? target.asMmolL : target
            let targetString = target == 0 ? "" : (fetchedTargetFormatter.string(from: target as NSNumber) ?? "") + " " +
                state.units.rawValue + percentageString

            if newDuration >= 1 {
                durationString =
                    "\(newDuration.formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) min"
            } else if newDuration > 0 {
                durationString =
                    "\((newDuration * 60).formatted(.number.grouping(.never).rounded().precision(.fractionLength(0)))) s"
            } else {
                /// Do not show the Temp Target anymore
                Task {
                    guard let objectID = self.latestTempTarget.first?.objectID else { return }
                    await state.cancelTempTarget(withID: objectID)
                }
            }

            let components = [targetString, durationString].filter { !$0.isEmpty }
            return components.isEmpty ? nil : components.joined(separator: ", ")
        }

        var timeIntervalButtons: some View {
            HStack(spacing: 0) {
                ForEach(timeButtons) { button in
                    Button(action: {
                        state.hours = button.hours
                    }) {
                        Text(
                            button.hours.description + "\u{00A0}" +
                                String(localized: "h", comment: "h")
                        )
                        .font(.footnote)
                        .fontWeight(button.active ? .semibold : .regular)
                        .frame(width: 52, height: 28)
                        .foregroundColor(
                            button.active
                                ? (colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                                : Color.primary.opacity(0.8)
                        )
                        .background(button.active ? Color.tabBar : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(2)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.13 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }

        var statsIconString: String {
            if #available(iOS 18, *) {
                return "chart.line.text.clipboard"
            } else {
                return "list.clipboard"
            }
        }

        /// Compact 34pt square glass icon button used in the chart header row.
        @ViewBuilder private func glassIconButton(
            iconString: String,
            accessibilityLabel: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: {
                action()
            }) {
                Image(systemName: iconString)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .glassCard(radius: 10, opacity: 0.7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
        }

        @ViewBuilder func mainChart(geo: GeometryProxy) -> some View {
            ZStack {
                MainChartView(
                    geo: geo,
                    safeAreaSize: notificationsDisabled == true ? safeAreaSize : 0,
                    units: state.units,
                    hours: state.filteredHours,
                    highGlucose: state.highGlucose,
                    lowGlucose: state.lowGlucose,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    screenHours: state.hours,
                    displayXgridLines: state.displayXgridLines,
                    displayYgridLines: state.displayYgridLines,
                    thresholdLines: state.thresholdLines,
                    state: state
                )
            }
            .padding(.bottom, UIDevice.adjustPadding(min: 0, max: nil))
        }

        func highlightButtons() {
            for i in 0 ..< timeButtons.count {
                timeButtons[i].active = timeButtons[i].hours == state.hours
            }
        }

        // MARK: - Hero header (glucose + loop pill)

        var heroHeader: some View {
            HStack(alignment: .top, spacing: 12) {
                HomeHeroGlucoseView(
                    timerDate: state.timerDate,
                    units: state.units,
                    lowGlucose: state.lowGlucose,
                    highGlucose: state.highGlucose,
                    cgmAvailable: state.cgmAvailable,
                    currentGlucoseTarget: state.currentGlucoseTarget,
                    glucoseColorScheme: state.glucoseColorScheme,
                    glucose: state.latestTwoGlucoseValues
                )
                .onTapGesture {
                    handleCGMTap()
                }
                .onLongPressGesture {
                    let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                    impactHeavy.impactOccurred()
                    state.showModal(for: .snooze)
                }

                Spacer()

                HomeLoopPillView(
                    closedLoop: state.closedLoop,
                    timerDate: state.timerDate,
                    isLooping: state.isLooping,
                    lastLoopDate: state.lastLoopDate,
                    manualTempBasal: state.manualTempBasal,
                    determination: state.determinationsFromPersistence
                )
                .onTapGesture {
                    state.isLoopStatusPresented = true
                }
                .onLongPressGesture {
                    let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                    impactHeavy.impactOccurred()
                    state.runLoop()
                }
            }
        }

        // MARK: - Metric tiles (IOB / COB / Basal / Eventual)

        /// Formats a forecast glucose value (mg/dL) for display, clamping into the range the
        /// non-carb forecast curves use (39–401). Out-of-range values keep an explicit
        /// ≤/≥ marker in both directions — a predicted severe low must not silently
        /// render as a near-normal 39.
        private func forecastGlucoseDisplayString(for value: Int) -> String {
            let clamped = Decimal(min(max(value, 39), 401))
            let text = state.units == .mgdL ? clamped.description : clamped.formattedAsMmolL
            if value < 39 { return "≤" + text }
            if value > 401 { return "≥" + text }
            return text
        }

        private var eventualBGString: String {
            guard let eventualBG = state.enactedAndNonEnactedDeterminations.first?.eventualBG else {
                return "--"
            }
            return forecastGlucoseDisplayString(for: Int(truncating: eventualBG as NSNumber))
        }

        /// Detail text for the Eventual tile: what the number means, the current spread of
        /// the forecast curves, and where to go when it is consistently off.
        private var eventualDetailBody: String {
            var body = String(
                localized: "\(eventualBGString) \(state.units.rawValue) predicted once active insulin and carbs are absorbed."
            )

            if let minEnd = state.minForecast.last, let maxEnd = state.maxForecast.last, maxEnd > 0 {
                let minString = forecastGlucoseDisplayString(for: minEnd)
                let maxString = forecastGlucoseDisplayString(for: maxEnd)
                body += " " + String(
                    localized: "Trio's forecast scenarios currently end between \(minString) and \(maxString) \(state.units.rawValue); eventual glucose is deliberately the highest carb-based outcome, so it errs on the side of caution."
                )
            }

            body += " " + String(
                localized: "If this number is consistently far off, your insulin sensitivity or carb ratio may need tuning. See Therapy Settings → ISF & CR Calculator."
            )
            return body
        }

        /// Compact current basal rate for the metric tile; detail popover carries the
        /// full string. "--" while the pump is suspended or unavailable (matches the
        /// old meal panel, which hid the rate in those states).
        private var basalTileValue: String {
            guard let apsManager = state.apsManager,
                  apsManager.isScheduledBasal != nil,
                  !apsManager.isSuspended
            else { return "--" }

            var rate: NSNumber?
            if apsManager.isScheduledBasal == true {
                rate = scheduledBasalDeliveryRate(at: Date())
            } else if let tempRate = state.tempBasals.last?.tempBasal?.rate {
                rate = tempRate
            }
            guard let rate else { return "--" }
            let rateString = Formatter.decimalFormatterWithThreeFractionDigits.string(from: rate) ?? "--"
            return apsManager.isManualTempBasal ? rateString + " ⚠️" : rateString
        }

        private var manualTempBasalAction: HomeTileDetail.Action? {
            guard state.allowManualTemp else { return nil }
            return HomeTileDetail.Action(
                name: String(localized: "Manual Temp Basal"),
                icon: "slider.horizontal.3"
            ) { activeEntryKind = .basal }
        }

        private var metricTiles: [(icon: String, label: String, value: String, color: Color, detail: HomeTileDetail)] {
            let determination = state.enactedAndNonEnactedDeterminations.first

            let iobValue = Formatter.decimalFormatterWithTwoFractionDigits
                .string(from: state.currentIOB as NSNumber) ?? "--"
            let maxIOBZero = state.maxIOB == 0.0
            var iobBody = String(localized: "\(iobValue) U of insulin on board.")
            if maxIOBZero {
                iobBody += " " + String(localized: "Warning: Max IOB is 0 U, so Trio cannot deliver automatic boluses.")
            }
            var iobActions: [HomeTileDetail.Action] = [
                HomeTileDetail.Action(name: String(localized: "Bolus"), icon: "syringe.fill") {
                    activeEntryKind = .bolus
                }
            ]
            if let manualTempBasalAction { iobActions.append(manualTempBasalAction) }

            let cobValue = determination.map { "\($0.cob)" } ?? "--"
            let cobDetail = HomeTileDetail(
                title: String(localized: "Carbs on Board"),
                body: String(localized: "\(cobValue) g of carbs still absorbing."),
                actions: [
                    HomeTileDetail.Action(name: String(localized: "Add Carbs"), icon: "fork.knife") {
                        activeEntryKind = .carbs
                    }
                ]
            )

            var basalActions: [HomeTileDetail.Action] = [
                HomeTileDetail.Action(name: String(localized: "Pump Settings"), icon: "gearshape.fill") {
                    handlePumpTap()
                }
            ]
            if let manualTempBasalAction { basalActions.append(manualTempBasalAction) }

            return [
                (
                    icon: maxIOBZero ? "exclamationmark.circle.fill" : "syringe.fill",
                    label: String(localized: "IOB"),
                    value: iobValue,
                    color: maxIOBZero ? .loopRed : .insulin,
                    detail: HomeTileDetail(
                        title: String(localized: "Insulin on Board"),
                        body: iobBody,
                        actions: iobActions
                    )
                ),
                (
                    icon: "fork.knife",
                    label: String(localized: "COB"),
                    value: cobValue + " g",
                    color: .loopYellow,
                    detail: cobDetail
                ),
                (
                    icon: "drop.fill",
                    label: String(localized: "Basal"),
                    value: basalTileValue,
                    color: .insulinTintColor,
                    detail: HomeTileDetail(
                        title: String(localized: "Current Basal"),
                        body: basalString.map { String(localized: "Delivering \($0).") } ??
                            String(localized: "No basal delivery data. The pump may be suspended or not reachable."),
                        actions: basalActions
                    )
                ),
                (
                    icon: "arrow.right.circle",
                    label: String(localized: "Eventual"),
                    value: eventualBGString,
                    color: .tabBar,
                    detail: HomeTileDetail(
                        title: String(localized: "Eventual Glucose"),
                        body: eventualDetailBody,
                        actions: [
                            HomeTileDetail.Action(name: String(localized: "Loop Status"), icon: "circle") {
                                state.isLoopStatusPresented = true
                            }
                        ]
                    )
                )
            ]
        }

        var metricsRow: some View {
            HomeMetricsRow(
                tiles: metricTiles,
                highlightedTitle: activeTileDetail?.title
            ) { detail in
                withAnimation(.easeOut(duration: 0.16)) { activeTileDetail = detail }
            }
        }

        // MARK: - Device tiles (Reservoir / Pod / Battery / CGM)

        private var reservoirValueString: String {
            guard let reservoir = state.reservoir else { return "--" }
            if reservoir == 0xDEAD_BEEF {
                return String(localized: "50+ U", comment: "Reservoir sentinel for 'more than 50 units'")
            }
            return (Formatter.integerFormatter.string(from: reservoir as NSNumber) ?? "--")
                + " " + String(localized: "U", comment: "Insulin unit")
        }

        private var reservoirColor: Color {
            guard let reservoir = state.reservoir else { return .gray }
            if reservoir == 0xDEAD_BEEF { return .insulin }
            if reservoir <= 10 { return .loopRed }
            if reservoir <= 30 { return .orange }
            return .insulin
        }

        private func podRemainingString(expiresAt: Date) -> String {
            let remaining = expiresAt.timeIntervalSince(state.timerDate)
            guard remaining > 0 else { return String(localized: "Replace") }
            let days = Int(remaining / 86400)
            let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
            let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            if days >= 1 { return "\(days)d \(hours)h" }
            if hours >= 1 { return hours < 12 ? "\(hours)h \(minutes)m" : "\(hours)h" }
            return "\(minutes)m"
        }

        private var podColor: Color {
            if let activatedAt = state.pumpActivatedAtDate {
                // Patch pumps report age: warn once past the normal 80h patch life.
                let ageHours = state.timerDate.timeIntervalSince(activatedAt) / 3600
                return ageHours > 80 ? .yellow : .loopGreen
            }
            guard let expiresAt = state.pumpExpiresAtDate else { return .gray }
            let remaining = expiresAt.timeIntervalSince(state.timerDate)
            if remaining <= 8 * 3600 { return .loopRed }
            if remaining <= 24 * 3600 { return .orange }
            return .loopGreen
        }

        private var pumpBatteryPercent: Double? {
            guard let battery = state.batteryFromPersistence.first, battery.display else { return nil }
            return battery.percent
        }

        private var pumpBatteryColor: Color {
            guard let percent = pumpBatteryPercent else { return .gray }
            if percent <= 10 { return .loopRed }
            if percent <= 20 { return .orange }
            return .loopGreen
        }

        @ViewBuilder private func deviceTile(
            icon: String,
            label: String,
            value: String,
            color: Color,
            detail: HomeTileDetail,
            tapAction: @escaping () -> Void
        ) -> some View {
            HomeDeviceTile(
                icon: icon,
                label: label,
                value: value,
                color: color,
                isHighlighted: activeTileDetail?.title == detail.title
            )
            .onTapGesture { tapAction() }
            .onLongPressGesture {
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
                withAnimation(.easeOut(duration: 0.16)) { activeTileDetail = detail }
            }
        }

        @ViewBuilder var deviceRow: some View {
            HStack(spacing: 8) {
                if let statusMessage = state.pumpStatusHighlightMessage {
                    // A pump status highlight replaces the pump tiles entirely (same as PumpView).
                    Button {
                        handlePumpTap()
                    } label: {
                        Text(statusMessage)
                            .font(.footnote).bold()
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .glassCard(radius: GlassDesign.tileRadius, opacity: 0.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: GlassDesign.tileRadius)
                                    .stroke(Color.loopRed.opacity(0.55), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                } else if state.pumpDisplayState == nil {
                    deviceTile(
                        icon: "keyboard.onehanded.left",
                        label: String(localized: "Pump"),
                        value: String(localized: "Add"),
                        color: .secondary,
                        detail: HomeTileDetail(
                            title: String(localized: "Add Pump"),
                            body: String(localized: "No insulin pump is set up yet. Tap the tile to choose a pump model."),
                            actions: []
                        ),
                        tapAction: { handlePumpTap() }
                    )
                } else {
                    deviceTile(
                        icon: "cross.vial.fill",
                        label: String(localized: "Reservoir"),
                        value: reservoirValueString,
                        color: reservoirColor,
                        detail: HomeTileDetail(
                            title: String(localized: "Reservoir"),
                            body: String(localized: "\(reservoirValueString) of insulin remaining."),
                            actions: []
                        ),
                        tapAction: { handlePumpTap() }
                    )

                    if let expiresAt = state.pumpExpiresAtDate {
                        deviceTile(
                            icon: state.pumpActivatedAtDate != nil ? "hourglass.badge.plus" : "hourglass.bottomhalf.filled",
                            label: String(localized: "Pod"),
                            value: podRemainingString(expiresAt: expiresAt),
                            color: podColor,
                            detail: HomeTileDetail(
                                title: String(localized: "Pod Expiry"),
                                body: String(
                                    localized: "Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))."
                                ),
                                actions: []
                            ),
                            tapAction: { handlePumpTap() }
                        )
                    }

                    if let percent = pumpBatteryPercent {
                        deviceTile(
                            icon: "battery.100",
                            label: String(localized: "Battery"),
                            value: "\(Int(percent)) %",
                            color: pumpBatteryColor,
                            detail: HomeTileDetail(
                                title: String(localized: "Pump Battery"),
                                body: String(localized: "\(Int(percent)) % pump battery remaining."),
                                actions: []
                            ),
                            tapAction: { handlePumpTap() }
                        )
                    }
                }

                deviceTile(
                    icon: "sensor.tag.radiowaves.forward.fill",
                    label: String(localized: "CGM"),
                    value: state.cgmAvailable ? state.cgmCurrent.displayName : String(localized: "Add"),
                    color: state.cgmAvailable ? .loopGreen : .secondary,
                    detail: HomeTileDetail(
                        title: String(localized: "CGM"),
                        body: state.cgmAvailable
                            ? String(localized: "\(state.cgmCurrent.displayName) is the active glucose source.")
                            : String(localized: "No CGM is set up yet. Tap the tile to choose a glucose source."),
                        actions: []
                    ),
                    tapAction: { handleCGMTap() }
                )
            }
        }

        // MARK: - Chart header row

        var chartHeaderRow: some View {
            HStack(spacing: 6) {
                Text("Basal").glassCaption()
                Spacer()
                glassIconButton(
                    iconString: statsIconString,
                    accessibilityLabel: String(localized: "Stats", comment: "Stats icon in main view")
                ) {
                    state.showModal(for: .statistics)
                }
                glassIconButton(
                    iconString: "info",
                    accessibilityLabel: String(localized: "Info", comment: "Info icon in main view")
                ) {
                    state.isLegendPresented.toggle()
                }
            }
        }

        // MARK: - Adjustments dock

        private var hasActiveAdjustment: Bool {
            overrideString != nil || tempTargetString != nil
        }

        private var dockChips: [HomeDockChip] {
            var chips: [HomeDockChip] = overridePresetChips.map { preset in
                let name = preset.name ?? String(localized: "Custom Override")
                let isActive = preset.enabled
                let objectID = preset.objectID
                return HomeDockChip(
                    id: "override-" + objectID.uriRepresentation().absoluteString,
                    name: name,
                    icon: "clock.arrow.2.circlepath",
                    color: .purple,
                    isActive: isActive
                ) {
                    handleChipTap(name: name, isOverride: true, objectID: objectID, isActive: isActive)
                }
            }
            chips += tempTargetPresetChips.map { preset in
                let name = preset.name ?? String(localized: "Temp Target")
                let isActive = preset.enabled
                let objectID = preset.objectID
                return HomeDockChip(
                    id: "temptarget-" + objectID.uriRepresentation().absoluteString,
                    name: name,
                    icon: "target",
                    color: .loopGreen,
                    isActive: isActive
                ) {
                    handleChipTap(name: name, isOverride: false, objectID: objectID, isActive: isActive)
                }
            }
            return chips
        }

        func handleChipTap(name: String, isOverride: Bool, objectID: NSManagedObjectID, isActive: Bool) {
            if isActive {
                // Cancelling goes through the same confirmation dialogs as the dock Cancel button.
                if isOverride {
                    isConfirmStopOverridePresented = true
                } else {
                    isConfirmStopTempTargetShown = true
                }
            } else if state.settingsManager.settings.requireAdjustmentsConfirmation {
                pendingChipActivation = DockChipActivation(
                    name: name,
                    isOverride: isOverride,
                    objectID: objectID
                )
            } else {
                activateChip(DockChipActivation(name: name, isOverride: isOverride, objectID: objectID))
            }
        }

        func activateChip(_ activation: DockChipActivation) {
            // Wire the Adjustments state lazily: enacting is the only thing that
            // needs it, and wiring subscribes the model (which triggers a
            // determine-basal pass) — don't pay that on every Home appear.
            if adjustmentsState.resolver == nil {
                adjustmentsState.resolver = resolver
            }
            Task {
                if activation.isOverride {
                    await adjustmentsState.enactOverridePreset(withID: activation.objectID)
                    // Resync other module instances (e.g. the Adjustments tab) —
                    // same notification the Home-screen cancel path posts.
                    Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
                } else {
                    await adjustmentsState.enactTempTargetPreset(withID: activation.objectID)
                    Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)
                }
                showDockToast(String(localized: "\(activation.name) started"))
            }
        }

        @State private var dockToastGeneration = 0

        func showDockToast(_ text: String) {
            dockToastGeneration += 1
            let generation = dockToastGeneration
            withAnimation(.easeOut(duration: 0.18)) { dockToastText = text }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                guard generation == dockToastGeneration else { return }
                withAnimation(.easeIn(duration: 0.2)) { dockToastText = nil }
            }
        }

        @ViewBuilder private func dockBolusRow(_ progress: Decimal) -> some View {
            /// ensure that state.lastPumpBolus has a value, i.e. there is a last bolus done by the pump and not an external bolus
            if let bolusTotal = state.lastPumpBolus?.bolus?.amount {
                let bolusFraction = progress * (bolusTotal as Decimal)
                let bolusString =
                    (bolusProgressFormatter.string(from: bolusFraction as NSNumber) ?? "0")
                        + String(localized: " of ", comment: "Bolus string partial message: 'x U of y U' in home view") +
                        (Formatter.decimalFormatterWithThreeFractionDigits.string(from: bolusTotal as NSNumber) ?? "0")
                        + String(localized: " U", comment: "Insulin unit")

                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "cross.vial.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Color.insulin)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bolusing")
                                .font(.subheadline).fontWeight(.semibold)
                            Text(bolusString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.showProgressView()
                            state.cancelBolus()
                        } label: {
                            Image(systemName: "xmark.app")
                                .font(.system(size: 24))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel bolus")
                    }
                    BolusProgressBar(progress: progress)
                }
            }
        }

        @ViewBuilder private var dockStatusRow: some View {
            if let progress = state.bolusProgress {
                dockBolusRow(progress)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17))
                        .foregroundStyle(hasActiveAdjustment ? Color.purple : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        if let overrideString = overrideString {
                            HStack(spacing: 4) {
                                Text(latestOverride.first?.name ?? String(localized: "Custom Override"))
                                    .font(.subheadline).fontWeight(.semibold)
                                    .lineLimit(1)
                                Text("· " + overrideString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if let tempTargetString = tempTargetString {
                            HStack(spacing: 4) {
                                Text(latestTempTarget.first?.name ?? String(localized: "Temp Target"))
                                    .font(.subheadline).fontWeight(.semibold)
                                    .lineLimit(1)
                                Text("· " + tempTargetString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !hasActiveAdjustment {
                            (
                                Text("No Active Adjustment — ").foregroundStyle(Color.secondary)
                                    + Text("Profile at 100 %").fontWeight(.semibold)
                            )
                            .font(.subheadline)
                            .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if hasActiveAdjustment {
                        Button {
                            if !latestTempTarget.isEmpty, !latestOverride.isEmpty {
                                showCancelConfirmDialog = true
                            } else if !latestOverride.isEmpty {
                                isConfirmStopOverridePresented = true
                            } else if !latestTempTarget.isEmpty {
                                isConfirmStopTempTargetShown = true
                            }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.loopRed)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Color.loopRed.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(Color.loopRed.opacity(0.5), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }

        var adjustmentsDock: some View {
            HomeAdjustmentsDock(
                chips: dockChips,
                // The dock's compact preset sheet reuses the live fetch results and
                // the chip enact/cancel paths — no extra state model per open.
                onOpen: { showDockSheet = true }
            ) {
                dockStatusRow
            }
            .confirmationDialog(
                "Stop the Override \"\(latestOverride.first?.name ?? "")\"?",
                isPresented: $isConfirmStopOverridePresented,
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    Task {
                        guard let objectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: objectID)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Stop the Temp Target \"\(latestTempTarget.first?.name ?? "")\"?",
                isPresented: $isConfirmStopTempTargetShown,
                titleVisibility: .visible
            ) {
                Button("Stop", role: .destructive) {
                    Task {
                        guard let objectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: objectID)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Adjustment to Stop", isPresented: $showCancelConfirmDialog) {
                Button("Stop Override", role: .destructive) {
                    Task {
                        guard let objectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: objectID)
                    }
                }
                Button("Stop Temp Target", role: .destructive) {
                    Task {
                        guard let objectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: objectID)
                    }
                }
                Button("Stop All Adjustments", role: .destructive) {
                    Task {
                        guard let overrideObjectID = latestOverride.first?.objectID else { return }
                        await state.cancelOverride(withID: overrideObjectID)

                        guard let tempTargetObjectID = latestTempTarget.first?.objectID else { return }
                        await state.cancelTempTarget(withID: tempTargetObjectID)
                    }
                }
            } message: {
                Text("Select Adjustment")
            }
            .confirmationDialog(
                pendingChipActivation.map {
                    $0.isOverride
                        ? String(localized: "Start the Override \"\($0.name)\"?")
                        : String(localized: "Start the Temp Target \"\($0.name)\"?")
                } ?? "",
                isPresented: Binding(
                    get: { pendingChipActivation != nil },
                    set: { if !$0 { pendingChipActivation = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingChipActivation
            ) { activation in
                // `presenting:` hands the captured value into the action, so the
                // dismissal binding clearing pendingChipActivation cannot race it.
                Button("Start") {
                    activateChip(activation)
                }
                Button("Cancel", role: .cancel) {}
            }
        }

        // MARK: - Quick actions (long-press on the + tab button)

        private var quickActions: [HomeQuickAction] {
            var items: [HomeQuickAction] = [
                HomeQuickAction(name: String(localized: "Carbs"), icon: "fork.knife", color: .loopYellow) {
                    activeEntryKind = .carbs
                },
                HomeQuickAction(name: String(localized: "Bolus"), icon: "syringe.fill", color: .insulin) {
                    activeEntryKind = .bolus
                },
                HomeQuickAction(
                    name: String(localized: "Meal Presets"),
                    icon: "bookmark.fill",
                    color: .loopYellow,
                    hint: String(localized: "Treatments")
                ) {
                    state.showModal(for: .treatmentView)
                },
                HomeQuickAction(name: String(localized: "Manual Glucose"), icon: "drop.fill", color: .loopGreen) {
                    activeEntryKind = .glucose
                }
            ]
            if state.allowManualTemp {
                items.append(
                    HomeQuickAction(name: String(localized: "Manual Temp Basal"), icon: "slider.horizontal.3", color: .tabBar) {
                        activeEntryKind = .basal
                    }
                )
            }
            items.append(
                HomeQuickAction(name: String(localized: "Adjustments"), icon: "clock.arrow.2.circlepath", color: .purple) {
                    showDockSheet = true
                }
            )
            return items
        }

        /// Glucose rise in display units for the unannounced meal prompt.
        private func riseString(_ mgdl: Int) -> String {
            if state.units == .mmolL {
                return (
                    Formatter.decimalFormatterWithOneFractionDigit
                        .string(from: Decimal(mgdl).asMmolL as NSNumber) ?? "\(mgdl)"
                ) + " " + state.units.rawValue
            }
            return "\(mgdl) " + state.units.rawValue
        }

        /// Scheduled profile basal rate for the drawer's temp-basal note.
        private var profileBasalRateString: String? {
            guard let rate = scheduledBasalDeliveryRate(at: Date()) else { return nil }
            return (Formatter.decimalFormatterWithThreeFractionDigits.string(from: rate) ?? "0")
                + String(localized: " U/hr", comment: "Unit per hour with space")
        }

        @ViewBuilder func alertSafetyNotificationsView(geo: GeometryProxy) -> some View {
            ZStack {
                /// rectangle as background
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        Color(
                            red: 0.9,
                            green: 0.133333333,
                            blue: 0.2156862745
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .frame(height: geo.size.height * safeAreaSize)
                    .coordinateSpace(name: "alertSafetyNotificationsView")
                    .shadow(
                        color: colorScheme == .dark ? Color(red: 0.02745098039, green: 0.1098039216, blue: 0.1411764706) :
                            Color.black.opacity(0.33),
                        radius: 3
                    )
                HStack {
                    Spacer()
                    VStack {
                        Text("⚠️ Safety Notifications are OFF")
                            .font(.headline)
                            .fontWeight(.bold)
                            .fontDesign(.rounded)
                            .foregroundStyle(.white.gradient)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Fix now by turning Notifications ON.")
                            .font(.footnote)
                            .fontDesign(.rounded)
                            .foregroundStyle(.white.gradient)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, 5)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundColor(.white)
                        .font(.headline)
                }.padding(.horizontal, 10)
                    .padding(.trailing, 8)
                    .onTapGesture {
                        UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    }
            }.padding(.horizontal, 10)
                .padding(.top, 0)
        }

        @ViewBuilder func mainViewElements(_ geo: GeometryProxy) -> some View {
            VStack(spacing: 0) {
                Group {
                    if let apsManager = state.apsManager, let bluetoothManager = apsManager.bluetoothManager,
                       bluetoothManager.bluetoothAuthorization != .authorized
                    {
                        BluetoothRequiredView()
                    } else {
                        heroHeader
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if notificationsDisabled {
                        alertSafetyNotificationsView(geo: geo)
                    }
                    if let badgeImage = state.pumpStatusBadgeImage, let badgeColor = state.pumpStatusBadgeColor {
                        pumpTimezoneView(badgeImage, badgeColor)
                            .padding(.horizontal, 20)
                    }
                }

                metricsRow
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                deviceRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                chartHeaderRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                mainChart(geo: geo)

                HStack {
                    Spacer()
                    timeIntervalButtons
                    Spacer()
                }
                .padding(.vertical, 6)

                adjustmentsDock
            }
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onReceive(
                resolver.resolve(AlertPermissionsChecker.self)!.$notificationsDisabled,
                perform: {
                    if notificationsDisabled != $0 {
                        notificationsDisabled = $0
                        if notificationsDisabled {
                            debug(.default, "notificationsDisabled")
                        }
                    }
                }
            )
        }

        @ViewBuilder func mainView() -> some View {
            GeometryReader { geo in
                mainViewElements(geo)
            }
            .onChange(of: state.hours) {
                highlightButtons()
            }
            .onAppear {
                configureView {
                    highlightButtons()
                }
            }
            .navigationTitle("Home")
            .navigationBarHidden(true)
            .blur(radius: state.isLoopStatusPresented ? 3 : 0)
            .sheet(isPresented: $state.isLoopStatusPresented) {
                LoopStatusView(state: state)
            }
            .sheet(isPresented: $state.isLegendPresented) {
                ChartLegendView(state: state)
            }
            // PUMP RELATED
            .confirmationDialog("Pump Model", isPresented: $showPumpSelection) {
                Button("Medtronic") { state.addPump(.minimed) }
                Button("All Omnipod Types") { state.addPump(.omni) }
                Button("Dana(RS/-i)") { state.addPump(.dana) }
                Button("Medtrum Nano") { state.addPump(.medtrum) }
                Button("Tandem t:slim X2") { state.addPump(.tandem) }
                Button("Pump Simulator") { state.addPump(.simulator) }
            } message: { Text("Select Pump Model") }
            .sheet(isPresented: $state.shouldDisplayPumpSetupSheet) {
                if let pumpManager = state.provider.apsManager.pumpManager {
                    PumpConfig.PumpSettingsView(
                        pumpManager: pumpManager,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                } else {
                    PumpConfig.PumpSetupView(
                        pumpType: state.setupPumpType,
                        pumpInitialSettings: state.pumpInitialSettings,
                        bluetoothManager: state.provider.apsManager.bluetoothManager!,
                        completionDelegate: state,
                        setupDelegate: state
                    )
                }
            }
            // CGM RELATED
            .confirmationDialog("CGM Model", isPresented: $showCGMSelection) {
                cgmSelectionButtons
            } message: {
                Text("Select CGM Model")
            }
            .sheet(isPresented: $state.shouldDisplayCGMSetupSheet) {
                switch state.cgmCurrent.type {
                case .enlite,
                     .nightscout,
                     .none,
                     .simulator,
                     .xdrip:
                    CGMSettings.CustomCGMOptionsView(
                        resolver: self.resolver,
                        state: state.cgmStateModel,
                        cgmCurrent: state.cgmCurrent,
                        deleteCGM: state.deleteCGM
                    )
                case .plugin:
                    if let fetchGlucoseManager = state.fetchGlucoseManager,
                       let cgmManager = fetchGlucoseManager.cgmManager,
                       state.cgmCurrent.type == fetchGlucoseManager.cgmGlucoseSourceType,
                       state.cgmCurrent.id == fetchGlucoseManager.cgmGlucosePluginId
                    {
                        CGMSettings.CGMSettingsView(
                            cgmManager: cgmManager,
                            bluetoothManager: state.provider.apsManager.bluetoothManager!,
                            unit: state.settingsManager.settings.units,
                            completionDelegate: state
                        )
                    } else {
                        CGMSettings.CGMSetupView(
                            CGMType: state.cgmCurrent,
                            bluetoothManager: state.provider.apsManager.bluetoothManager!,
                            unit: state.settingsManager.settings.units,
                            completionDelegate: state,
                            setupDelegate: state,
                            pluginCGMManager: self.state.pluginCGMManager
                        )
                    }
                }
            }
        }

        @ViewBuilder func tabBar() -> some View {
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    let carbsRequiredBadge: String? = {
                        guard let carbsRequired = state.enactedAndNonEnactedDeterminations.first?.carbsRequired,
                              state.showCarbsRequiredBadge
                        else {
                            return nil
                        }
                        let carbsRequiredDecimal = Decimal(carbsRequired)
                        if carbsRequiredDecimal > state.settingsManager.settings.carbsRequiredThreshold {
                            let numberAsNSNumber = NSDecimalNumber(decimal: carbsRequiredDecimal)
                            return (Formatter.decimalFormatterWithTwoFractionDigits.string(from: numberAsNSNumber) ?? "") + " g"
                        }
                        return nil
                    }()

                    NavigationStack { mainView() }
                        .tabItem { Label("Main", systemImage: "chart.xyaxis.line") }
                        .badge(carbsRequiredBadge).tag(0)

                    NavigationStack { History.RootView(resolver: resolver) }
                        .tabItem { Label("History", systemImage: historySFSymbol) }.tag(1)

                    Spacer()

                    NavigationStack { Adjustments.RootView(resolver: resolver) }
                        .tabItem {
                            Label(
                                "Adjustments",
                                systemImage: "slider.horizontal.2.gobackward"
                            ) }.tag(2)

                    NavigationStack(path: self.$settingsPath) {
                        Settings.RootView(resolver: resolver) }
                        .environment(settingsSearchHighlight)
                        .tabItem { Label(
                            "Settings",
                            systemImage: "gear"
                        ) }.tag(3)
                }
                .tint(Color.tabBar)

                plusButton
            }.ignoresSafeArea(.keyboard, edges: .bottom).blur(radius: state.waitForSuggestion ? 8 : 0)
                .onChange(of: selectedTab) {
                    if !settingsPath.isEmpty {
                        settingsPath = NavigationPath()
                    }
                }
        }

        /// Center + button: tap pops the quick actions menu (long-press still
        /// works for muscle memory, with press scale/glow feedback).
        var plusButton: some View {
            ZStack {
                Circle()
                    .fill(Color.tabBar)
                    .frame(width: 52, height: 52)
                    .shadow(
                        color: Color.tabBar.opacity(plusButtonPressed ? 0.6 : 0.4),
                        radius: plusButtonPressed ? 14 : 8,
                        y: 4
                    )
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
            }
            .scaleEffect(plusButtonPressed ? 1.1 : 1)
            .padding(.vertical, 2)
            .padding(.horizontal, 24)
            .contentShape(Circle())
            .accessibilityLabel(String(localized: "Add treatment"))
            .onTapGesture {
                let impactLight = UIImpactFeedbackGenerator(style: .light)
                impactLight.impactOccurred()
                withAnimation(.easeOut(duration: 0.18)) { showQuickActions = true }
            }
            .onLongPressGesture(minimumDuration: 0.42) {
                let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                impactHeavy.impactOccurred()
                withAnimation(.easeOut(duration: 0.18)) { showQuickActions = true }
            } onPressingChanged: { pressing in
                withAnimation(.easeOut(duration: 0.12)) { plusButtonPressed = pressing }
            }
        }

        var body: some View {
            ZStack(alignment: .center) {
                tabBar()

                // Scrim + floating overlays for tile details and quick actions.
                if showQuickActions || activeTileDetail != nil {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeIn(duration: 0.14)) {
                                showQuickActions = false
                                activeTileDetail = nil
                            }
                        }
                }

                if let activeTileDetail {
                    VStack {
                        Spacer().frame(height: 120)
                        HomeTileDetailCard(detail: activeTileDetail) {
                            withAnimation(.easeIn(duration: 0.14)) { self.activeTileDetail = nil }
                        }
                        Spacer()
                    }
                }

                if showQuickActions {
                    VStack {
                        Spacer()
                        HomeQuickActionsCard(actions: quickActions) {
                            withAnimation(.easeIn(duration: 0.14)) { showQuickActions = false }
                        }
                        .padding(.bottom, 96)
                    }
                }

                if let dockToastText {
                    VStack {
                        HomeToastView(text: dockToastText)
                            .padding(.top, 8)
                        Spacer()
                    }
                }

                if state.waitForSuggestion {
                    CustomProgressView(text: String(localized: "Updating IOB...", comment: "Progress text when updating IOB"))
                }
            }
            .sheet(item: $activeEntryKind) { kind in
                HomeEntryDrawer(
                    kind: kind,
                    resolver: resolver,
                    homeState: state,
                    profileBasalRateString: profileBasalRateString,
                    onCommitted: { text in
                        if !text.isEmpty { showDockToast(text) }
                    }
                )
                .presentationDetents([.height(
                    kind == .carbs && state.settingsManager.settings.mealPhotoAnalysisEnabled ? 484 : 430
                )])
                .presentationDragIndicator(.visible)
            }
            .alert(
                String(localized: "Possible Unannounced Meal"),
                isPresented: Binding(
                    get: { state.unannouncedMealSuggestion != nil },
                    set: { if !$0 { state.unannouncedMealSuggestion = nil } }
                ),
                presenting: state.unannouncedMealSuggestion
            ) { _ in
                Button(String(localized: "Log Carbs")) {
                    state.unannouncedMealSuggestion = nil
                    activeEntryKind = .carbs
                }
                Button(String(localized: "Dismiss"), role: .cancel) {
                    state.unannouncedMealSuggestion = nil
                }
            } message: { suggestion in
                Text(
                    String(
                        localized: "Glucose rose \(riseString(suggestion.riseMgdl)) in the last \(suggestion.windowMinutes) min with no carbs logged. Did you eat something?"
                    )
                )
            }
            .sheet(isPresented: $showDockSheet) {
                HomeAdjustmentsSheetView(
                    overridePresets: Array(overridePresetChips),
                    tempTargetPresets: Array(tempTargetPresetChips),
                    units: state.units,
                    requireConfirmation: state.settingsManager.settings.requireAdjustmentsConfirmation,
                    activate: { activation in activateChip(activation) },
                    cancelOverride: {
                        Task {
                            guard let objectID = latestOverride.first?.objectID else { return }
                            await state.cancelOverride(withID: objectID)
                        }
                    },
                    cancelTempTarget: {
                        Task {
                            guard let objectID = latestTempTarget.first?.objectID else { return }
                            await state.cancelTempTarget(withID: objectID)
                        }
                    },
                    onManage: { selectedTab = 2 }
                )
                .presentationDetents([.fraction(0.6), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }
}

extension UIDevice {
    public enum DeviceSize: CGFloat {
        case smallDevice = 667 // Height for 4" iPhone SE
        case largeDevice = 852 // Height for 6.1" iPhone 15 Pro
    }

    @usableFromInline static func adjustPadding(
        min: CGFloat? = nil,
        max: CGFloat? = nil
    ) -> CGFloat? {
        if UIScreen.screenHeight > UIDevice.DeviceSize.smallDevice.rawValue {
            if UIScreen.screenHeight >= UIDevice.DeviceSize.largeDevice.rawValue {
                return max
            } else {
                return min != nil ?
                    (max != nil ? max! * (UIScreen.screenHeight / UIDevice.DeviceSize.largeDevice.rawValue) : nil) : nil
            }
        } else {
            return min
        }
    }
}

extension UIScreen {
    static var screenHeight: CGFloat {
        UIScreen.main.bounds.height
    }

    static var screenWidth: CGFloat {
        UIScreen.main.bounds.width
    }
}

/// Checks if the device is using a 24-hour time format.
func is24HourFormat() -> Bool {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    let dateString = formatter.string(from: Date())

    return !dateString.contains("AM") && !dateString.contains("PM")
}

/// Converts a duration in minutes to a formatted string (e.g., "1 h 30 m").
func formatHrMin(_ durationInMinutes: Int) -> String {
    let hours = durationInMinutes / 60
    let minutes = durationInMinutes % 60

    switch (hours, minutes) {
    case let (0, m):
        return "\(m)\u{00A0}" + String(localized: "m", comment: "Abbreviation for Minutes")
    case let (h, 0):
        return "\(h)\u{00A0}" + String(localized: "h", comment: "h")
    default:
        return hours.description + "\u{00A0}" + String(localized: "h", comment: "h") + "\u{00A0}" + minutes
            .description + "\u{00A0}" + String(localized: "m", comment: "Abbreviation for Minutes")
    }
}

// Helper function to convert a start and end hour to either 24-hour or AM/PM format
func formatTimeRange(start: String?, end: String?) -> String {
    guard let start = start, let end = end else {
        return ""
    }

    // Check if the format is 24-hour or AM/PM
    if is24HourFormat() {
        // Return the original 24-hour format
        return "\(start)-\(end)"
    } else {
        // Convert to AM/PM format using DateFormatter
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"

        if let startHour = Int(start), let endHour = Int(end) {
            let startDate = Calendar.current.date(bySettingHour: startHour, minute: 0, second: 0, of: Date()) ?? Date()
            let endDate = Calendar.current.date(bySettingHour: endHour, minute: 0, second: 0, of: Date()) ?? Date()

            // Customize the format to "2p" or "2a"
            formatter.dateFormat = "ha"
            let startFormatted = formatter.string(from: startDate).lowercased().replacingOccurrences(of: "m", with: "")
            let endFormatted = formatter.string(from: endDate).lowercased().replacingOccurrences(of: "m", with: "")

            return "\(startFormatted)-\(endFormatted)"
        } else {
            return ""
        }
    }
}
