import CoreData
import SwiftUI

extension History.RootView {
    // MARK: - Filter chips

    enum TimelineFilter: String, CaseIterable, Identifiable {
        case all
        case insulin
        case carbs
        case glucose
        case adjustments

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:
                return String(localized: "All", comment: "History timeline filter")
            case .insulin:
                return String(localized: "Insulin", comment: "History timeline filter")
            case .carbs:
                return String(localized: "Carbs", comment: "History timeline filter")
            case .glucose:
                return String(localized: "Glucose", comment: "History timeline filter")
            case .adjustments:
                return String(localized: "Adjustments", comment: "History timeline filter")
            }
        }

        /// Colored indicator dot shown on unselected chips.
        var dotColor: Color? {
            switch self {
            case .all:
                return nil
            case .insulin:
                return Color.insulin
            case .carbs:
                return Color.loopYellow
            case .glucose:
                return Color.loopGreen
            case .adjustments:
                return Color.purple
            }
        }

        /// Legacy mode equivalent, kept in sync so existing mode-driven behavior keeps working.
        var correspondingMode: History.Mode? {
            switch self {
            case .all:
                return nil
            case .insulin:
                return .treatments
            case .carbs:
                return .meals
            case .glucose:
                return .glucose
            case .adjustments:
                return .adjustments
            }
        }

        var emptyStateSymbol: String {
            switch self {
            case .all:
                return "clock.arrow.circlepath"
            case .insulin:
                return "syringe"
            case .carbs:
                return "fork.knife"
            case .glucose:
                return "drop.fill"
            case .adjustments:
                return "clock.arrow.2.circlepath"
            }
        }
    }

    // MARK: - Unified timeline model

    enum TimelineEntry: Identifiable {
        case pumpEvent(PumpEventStored)
        case glucose(GlucoseStored)
        case carbs(CarbEntryStored)
        case adjustment(AdjustmentItem)

        var id: NSManagedObjectID {
            switch self {
            case let .pumpEvent(item):
                return item.objectID
            case let .glucose(item):
                return item.objectID
            case let .carbs(item):
                return item.objectID
            case let .adjustment(item):
                return item.id
            }
        }

        var date: Date {
            switch self {
            case let .pumpEvent(item):
                return item.timestamp ?? .distantPast
            case let .glucose(item):
                return item.date ?? .distantPast
            case let .carbs(item):
                return item.date ?? .distantPast
            case let .adjustment(item):
                return item.startDate
            }
        }
    }

    struct TimelineHourGroup: Identifiable {
        let id: Date
        let entries: [TimelineEntry]
        let bolusTotal: Decimal
        let carbTotal: Decimal
    }

    private static let hourLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        return formatter
    }()

    /// Carb entries honoring the Show/Hide Future toggle, exactly like the legacy meals list.
    private var timelineCarbEntries: [CarbEntryStored] {
        carbEntryStored.filter { !showFutureEntries ? $0.date ?? Date() <= Date() : true }
    }

    var timelineEntries: [TimelineEntry] {
        var entries = [TimelineEntry]()
        if timelineFilter == .all || timelineFilter == .insulin {
            // filteredPumpEvents keeps honoring the 6-type treatment filter popover
            entries.append(contentsOf: filteredPumpEvents.map(TimelineEntry.pumpEvent))
        }
        if timelineFilter == .all || timelineFilter == .carbs {
            entries.append(contentsOf: timelineCarbEntries.map(TimelineEntry.carbs))
        }
        if timelineFilter == .all || timelineFilter == .glucose {
            entries.append(contentsOf: glucoseStored.map(TimelineEntry.glucose))
        }
        if timelineFilter == .all || timelineFilter == .adjustments {
            entries.append(contentsOf: combinedAdjustments.map(TimelineEntry.adjustment))
        }
        return entries.sorted { $0.date > $1.date }
    }

    var timelineHourGroups: [TimelineHourGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: timelineEntries) { entry -> Date in
            calendar.dateInterval(of: .hour, for: entry.date)?.start ?? entry.date
        }
        return grouped.map { hourStart, entries -> TimelineHourGroup in
            var bolusTotal: Decimal = 0
            var carbTotal: Decimal = 0
            for entry in entries {
                switch entry {
                case let .pumpEvent(item):
                    if let amount = item.bolus?.amount {
                        bolusTotal += amount.decimalValue
                    }
                case let .carbs(item):
                    if !item.isFPU {
                        carbTotal += Decimal(item.carbs)
                    }
                default:
                    break
                }
            }
            return TimelineHourGroup(
                id: hourStart,
                entries: entries.sorted { $0.date > $1.date },
                bolusTotal: bolusTotal,
                carbTotal: carbTotal
            )
        }
        .sorted { $0.id > $1.id }
    }

    // MARK: - Filter bar

    private var showsTreatmentTypeFilterButton: Bool {
        timelineFilter == .all || timelineFilter == .insulin
    }

    private var showsFutureEntriesButton: Bool {
        timelineFilter == .all || timelineFilter == .carbs
    }

    var timelineFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TimelineFilter.allCases) { filter in
                        timelineFilterChip(filter)
                    }
                }
                .padding(.horizontal)
            }

            if showsTreatmentTypeFilterButton || showsFutureEntriesButton {
                HStack {
                    if showsTreatmentTypeFilterButton {
                        filterTreatmentsButton
                    }
                    Spacer()
                    if showsFutureEntriesButton {
                        filterFutureEntriesButton
                    }
                }
                .font(.footnote)
                .padding(.horizontal)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func timelineFilterChip(_ filter: TimelineFilter) -> some View {
        let isSelected = timelineFilter == filter
        Button(
            action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    timelineFilter = filter
                }
                if let mode = filter.correspondingMode {
                    state.mode = mode
                }
            },
            label: {
                HStack(spacing: 6) {
                    if !isSelected, let dot = filter.dotColor {
                        Circle()
                            .fill(dot)
                            .frame(width: 6, height: 6)
                    }
                    Text(filter.title)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .foregroundStyle(
                    isSelected
                        ? (colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                        : Color.primary
                )
                .background(Capsule().fill(isSelected ? Color.tabBar : Color.chart))
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? Color.clear : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08),
                            lineWidth: 1
                        )
                )
            }
        )
        .buttonStyle(.plain)
    }

    // MARK: - Timeline list

    var timelineList: some View {
        List {
            if timelineHourGroups.isEmpty {
                Section {
                    ContentUnavailableView(
                        String(localized: "No data."),
                        systemImage: timelineFilter.emptyStateSymbol
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(timelineHourGroups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            timelineRow(for: entry)
                                .listRowBackground(Color.chart)
                        }
                    } header: {
                        timelineHourHeader(for: group)
                    }
                }
            }
        }
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }

    @ViewBuilder private func timelineHourHeader(for group: TimelineHourGroup) -> some View {
        HStack(spacing: 10) {
            Text(Self.hourLabelFormatter.string(from: group.id))
                .font(.subheadline.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(height: 1)
            if let summary = hourSummary(for: group) {
                Text(summary)
                    .font(.caption.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }

    private func hourSummary(for group: TimelineHourGroup) -> String? {
        var parts = [String]()
        if group.bolusTotal > 0 {
            let amount = Formatter.decimalFormatterWithTwoFractionDigits
                .string(from: group.bolusTotal as NSDecimalNumber) ?? "0"
            parts.append(amount + String(localized: " U", comment: "Insulin unit"))
        }
        if group.carbTotal > 0 {
            let grams = Formatter.decimalFormatterWithTwoFractionDigits
                .string(from: group.carbTotal as NSDecimalNumber) ?? "0"
            parts.append(grams + String(localized: " g", comment: "gram of carbs"))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rows

    @ViewBuilder func timelineRow(for entry: TimelineEntry) -> some View {
        switch entry {
        case let .pumpEvent(item):
            timelinePumpEventRow(item)
        case let .glucose(item):
            timelineGlucoseRow(item)
        case let .carbs(item):
            timelineCarbRow(item)
        case let .adjustment(item):
            timelineAdjustmentRow(item)
        }
    }

    /// Shared row scaffold: accent tick + icon + title/detail column + trailing amount/time column.
    private func timelineRowLayout(
        tint: Color,
        icon: String,
        iconColor: Color,
        time: Date,
        @ViewBuilder content: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3, height: 30)
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2, content: content)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                trailing()
                Text(Formatter.dateFormatter.string(from: time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
        .padding(.vertical, 2)
    }

    private func bolusTitle(isSMB: Bool, isExternal: Bool) -> String {
        if isSMB {
            return String(localized: "SMB")
        } else if isExternal {
            return String(localized: "External Bolus")
        } else {
            return String(localized: "Bolus")
        }
    }

    @ViewBuilder private func timelinePumpEventRow(_ item: PumpEventStored) -> some View {
        if let bolus = item.bolus, let amount = bolus.amount {
            timelineRowLayout(
                tint: Color.insulin,
                icon: "syringe.fill",
                iconColor: Color.insulin,
                time: item.timestamp ?? Date()
            ) {
                Text(bolusTitle(isSMB: bolus.isSMB, isExternal: bolus.isExternal))
                    .font(.subheadline.weight(.semibold))
                Text(bolus.isSMB ? String(localized: "Automatic") : String(localized: "Manual"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } trailing: {
                Text(
                    (Formatter.decimalFormatterWithThreeFractionDigits.string(from: amount) ?? "0") +
                        String(localized: " U", comment: "Insulin unit")
                )
                .font(.subheadline.weight(.bold))
                .fontDesign(.rounded)
            }
            .contextMenu {
                Button(
                    "Delete",
                    systemImage: "trash.fill",
                    role: .destructive,
                    action: { requestDelete(.insulin(item)) }
                ).tint(.red)
            }
            .swipeActions {
                Button(
                    "Delete",
                    systemImage: "trash.fill",
                    role: .none,
                    action: { requestDelete(.insulin(item)) }
                ).tint(.red)
            }
        } else if let tempBasal = item.tempBasal, let rate = tempBasal.rate {
            timelineRowLayout(
                tint: Color.insulin.opacity(0.4),
                icon: "drop.fill",
                iconColor: Color.insulin.opacity(0.5),
                time: item.timestamp ?? Date()
            ) {
                Text("Temp Basal")
                    .font(.subheadline.weight(.semibold))
                if tempBasal.duration > 0 {
                    Text("\(tempBasal.duration.string) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                Text(
                    (Formatter.decimalFormatterWithThreeFractionDigits.string(from: rate) ?? "0") +
                        String(localized: " U/hr", comment: "Unit insulin per hour")
                )
                .font(.subheadline.weight(.bold))
                .fontDesign(.rounded)
            }
        } else {
            timelineRowLayout(
                tint: Color.loopGray,
                icon: "pause.circle",
                iconColor: Color.loopGray,
                time: item.timestamp ?? Date()
            ) {
                Text(item.type ?? String(localized: "Pump Event"))
                    .font(.subheadline.weight(.semibold))
            } trailing: {
                EmptyView()
            }
        }
    }

    private func glucoseTrendColor(for glucose: GlucoseStored) -> Color {
        guard let direction = glucose.directionEnum else { return Color.loopGreen }
        switch direction {
        case .flat,
             .none:
            return Color.loopGreen
        case .fortyFiveDown,
             .fortyFiveUp,
             .singleDown,
             .singleUp:
            return Color.loopYellow
        case .doubleDown,
             .doubleUp,
             .tripleDown,
             .tripleUp:
            return Color.loopRed
        case .notComputable,
             .rateOutOfRange:
            return Color.loopGray
        }
    }

    @ViewBuilder private func timelineGlucoseRow(_ glucose: GlucoseStored) -> some View {
        let trendColor = glucoseTrendColor(for: glucose)
        timelineRowLayout(
            tint: glucose.isManual ? Color.loopRed : trendColor,
            icon: glucose.isManual ? "drop.fill" : "circle.fill",
            iconColor: glucose.isManual ? Color.red : trendColor,
            time: glucose.date ?? Date()
        ) {
            Text(String(localized: "Glucose"))
                .font(.subheadline.weight(.semibold))
            if glucose.isManual {
                Text(String(localized: "Manual"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.settingsManager.settings.smoothGlucose,
                      let smoothedGlucose = glucose.smoothedGlucose, smoothedGlucose != 0
            {
                let smoothedGlucoseForDisplay = state.units == .mgdL ? smoothedGlucose
                    .description : smoothedGlucose.decimalValue
                    .formattedAsMmolL

                (
                    Text("(") +
                        Text(Image(systemName: "sparkles")) +
                        Text(" ") +
                        Text("\(smoothedGlucoseForDisplay)") +
                        Text(")")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } trailing: {
            HStack(spacing: 4) {
                Text(formatGlucose(Decimal(glucose.glucose), isManual: glucose.isManual))
                    .font(.subheadline.weight(.bold))
                    .fontDesign(.rounded)
                if !glucose.isManual {
                    Text("\(glucose.directionEnum?.symbol ?? "--")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button(
                "Delete",
                systemImage: "trash.fill",
                role: .destructive,
                action: { requestDelete(.glucose(glucose)) }
            ).tint(.red)
        }
        .swipeActions {
            Button(
                "Delete",
                systemImage: "trash.fill",
                role: .none,
                action: { requestDelete(.glucose(glucose)) }
            ).tint(.red)
        }
    }

    @ViewBuilder private func timelineCarbRow(_ meal: CarbEntryStored) -> some View {
        timelineRowLayout(
            tint: meal.isFPU ? Color.orange.opacity(0.5) : Color.loopYellow,
            icon: "fork.knife",
            iconColor: meal.isFPU ? Color.orange.opacity(0.5) : Color.loopYellow,
            time: meal.date ?? Date()
        ) {
            Text(meal.isFPU ? String(localized: "Fat / Protein") : String(localized: "Carbs"))
                .font(.subheadline.weight(.semibold))
            if let note = meal.note, note != "" {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil")
                    Text(note)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } trailing: {
            Text(
                (Formatter.decimalFormatterWithTwoFractionDigits.string(for: meal.carbs) ?? "0") +
                    String(localized: " g", comment: "gram of carbs")
            )
            .font(.subheadline.weight(.bold))
            .fontDesign(.rounded)
        }
        .contextMenu {
            Button(
                "Delete",
                systemImage: "trash.fill",
                role: .destructive,
                action: { requestDelete(.carbs(meal)) }
            ).tint(.red)

            Button(
                "Edit",
                systemImage: "pencil",
                role: .none,
                action: {
                    state.carbEntryToEdit = meal
                    state.showCarbEntryEditor = true
                }
            )
            .tint(!state.settingsManager.settings.useFPUconversion && meal.isFPU ? Color(.systemGray4) : Color.blue)
            .disabled(!state.settingsManager.settings.useFPUconversion && meal.isFPU)
        }
        .swipeActions {
            Button(
                "Delete",
                systemImage: "trash.fill",
                role: .none,
                action: { requestDelete(.carbs(meal)) }
            ).tint(.red)

            Button(
                "Edit",
                systemImage: "pencil",
                role: .none,
                action: {
                    state.carbEntryToEdit = meal
                    state.showCarbEntryEditor = true
                }
            )
            .tint(!state.settingsManager.settings.useFPUconversion && meal.isFPU ? Color(.systemGray4) : Color.blue)
            .disabled(!state.settingsManager.settings.useFPUconversion && meal.isFPU)
        }
    }

    @ViewBuilder private func timelineAdjustmentRow(_ item: AdjustmentItem) -> some View {
        let isOverride = item.type == .override
        let targetDescription: String? = {
            guard let target = item.target, target != 0 else { return nil }
            return "\(state.units == .mgdL ? target : target.asMmolL) \(state.units.rawValue)"
        }()
        let formattedDates =
            "\(Formatter.dateFormatter.string(from: item.startDate)) - \(Formatter.dateFormatter.string(from: item.endDate))"

        timelineRowLayout(
            tint: isOverride ? Color.purple : Color.loopGreen,
            icon: isOverride ? "clock.arrow.2.circlepath" : "target",
            iconColor: isOverride ? Color.purple : Color.loopGreen,
            time: item.startDate
        ) {
            Text(item.name)
                .font(.subheadline.weight(.semibold))
            Text(targetDescription.map { "\($0) · \(formattedDates)" } ?? formattedDates)
                .font(.caption)
                .foregroundStyle(.secondary)
        } trailing: {
            EmptyView()
        }
    }
}
