import CoreData
import SwiftUI
import Swinject

/// Entry kinds the + drawer supports (from the Trio Prototype design).
enum HomeEntryKind: String, Identifiable {
    case carbs
    case bolus
    case glucose
    case basal

    var id: String { rawValue }
}

extension Home.StateModel {
    /// Mirrors History.StateModel.addManualGlucose: values are stored in mg/dL.
    func addManualGlucose(displayValue: Decimal) {
        let glucose = units == .mmolL ? displayValue.asMgdL : displayValue
        let glucoseAsInt = Int(glucose)
        glucoseStorage.addManualGlucose(glucose: glucoseAsInt)
    }
}

/// Prototype-style quick entry drawer: ± stepper, quick amounts, contextual note,
/// colored commit CTA. Carbs and bolus commits drive the full Treatments state
/// model, so every safety flow is identical to the Treatments screen: biometric
/// unlock, max-limit clamps, the low-glucose confirmation, and the stale-glucose
/// guard. Glucose and temp-basal commits use the same calls History and the
/// ManualTempBasal screen make.
struct HomeEntryDrawer: View {
    let kind: HomeEntryKind
    let resolver: Resolver
    let homeState: Home.StateModel
    let profileBasalRateString: String?
    let onCommitted: (String) -> Void

    @State private var treatments = Treatments.StateModel()
    @State private var amount: Decimal = 0
    @State private var showLowGlucoseConfirm = false
    @State private var showMealPhotoSheet = false
    @State private var showFoodSearchSheet = false
    /// True once an AI meal scan or food search result has been applied: the commit
    /// then keeps the fat/protein/note the analysis set instead of zeroing them.
    @State private var aiAnalysisApplied = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var isEvaluatingBolus = false
    @State private var ctaEvaluationTask: Task<Void, Never>?
    /// The bolus amount captured when the CTA was tapped: the gate decision and
    /// the delivered amount always refer to this exact value, never the live
    /// stepper value (which stays locked during evaluation anyway).
    @State private var pendingBolusAmount: Decimal?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    // MARK: - Per-kind configuration

    private var title: String {
        switch kind {
        case .carbs: return String(localized: "Add Carbs")
        case .bolus: return String(localized: "Bolus")
        case .glucose: return String(localized: "Manual Glucose")
        case .basal: return String(localized: "Manual Temp Basal")
        }
    }

    private var unitLabel: String {
        switch kind {
        case .carbs: return String(localized: "g", comment: "Units for carbs")
        case .bolus: return String(localized: "U", comment: "Insulin unit")
        case .glucose: return homeState.units.rawValue
        case .basal: return String(localized: "U/hr", comment: "Unit per hour with space")
            .trimmingCharacters(in: .whitespaces)
        }
    }

    private var accentColor: Color {
        switch kind {
        case .carbs: return .loopYellow
        case .bolus: return .insulin
        case .glucose: return .loopGreen
        case .basal: return .glassCyan
        }
    }

    private var step: Decimal {
        switch kind {
        case .carbs: return 5
        case .bolus: return 0.5
        case .glucose: return homeState.units == .mmolL ? Decimal(string: "0.2")! : 5
        case .basal: return Decimal(string: "0.25")!
        }
    }

    /// Quick amounts in display units.
    private var quickAmounts: [Decimal] {
        switch kind {
        case .carbs: return [10, 20, 45, 60]
        case .bolus: return [Decimal(string: "0.5")!, 1, 2, 3]
        case .glucose:
            let mgdl: [Decimal] = [70, 100, 140, 180]
            return homeState.units == .mmolL ? mgdl.map(\.asMmolL) : mgdl
        case .basal: return [0, Decimal(string: "0.5")!, 1, Decimal(string: "1.5")!]
        }
    }

    private var ctaLabel: String {
        if kind == .bolus, bolusLimitExceeded {
            return String(localized: "Max Bolus of \(treatments.maxBolus.description) U Exceeded")
        }
        if kind == .bolus, treatments.isBolusInProgress {
            return String(localized: "Bolus in Progress")
        }
        if kind == .carbs, carbLimitExceeded {
            return String(localized: "Max Carbs of \(treatments.maxCarbs.description) g Exceeded")
        }
        switch kind {
        case .carbs: return String(localized: "Save Carbs")
        case .bolus: return String(localized: "Deliver Bolus")
        case .glucose: return String(localized: "Save Reading")
        case .basal: return String(localized: "Set for 30 min")
        }
    }

    // MARK: - Limits (mirroring the Treatments screen and History glucose sheet)

    private var bolusLimitExceeded: Bool { kind == .bolus && amount > treatments.maxBolus }
    private var carbLimitExceeded: Bool { kind == .carbs && amount > treatments.maxCarbs }

    private var glucoseLimits: ClosedRange<Decimal> {
        homeState.units == .mmolL ? Decimal(14).asMmolL ... Decimal(720).asMmolL : 14 ... 720
    }

    private var glucoseOutOfRange: Bool {
        kind == .glucose && !glucoseLimits.contains(amount)
    }

    private var maxBasalRate: Decimal { homeState.maxBasal }

    private var commitDisabled: Bool {
        if treatments.isAwaitingDeterminationResult || treatments.addButtonPressed || isEvaluatingBolus { return true }
        switch kind {
        case .carbs: return amount <= 0 || carbLimitExceeded
        case .bolus: return amount <= 0 || bolusLimitExceeded || treatments.isBolusInProgress
        case .glucose: return glucoseOutOfRange
        case .basal: return amount < 0 || amount > maxBasalRate
        }
    }

    // MARK: - Value formatting

    private var amountString: String {
        switch kind {
        case .carbs:
            return (Formatter.integerFormatter.string(from: amount as NSNumber) ?? "0")
        case .bolus:
            return Formatter.decimalFormatterWithTwoFractionDigits.string(from: amount as NSNumber) ?? "0"
        case .glucose:
            return homeState.units == .mmolL
                ? (Formatter.decimalFormatterWithOneFractionDigit.string(from: amount as NSNumber) ?? "0")
                : (Formatter.integerFormatter.string(from: amount as NSNumber) ?? "0")
        case .basal:
            return Formatter.decimalFormatterWithTwoFractionDigits.string(from: amount as NSNumber) ?? "0"
        }
    }

    private func quickLabel(_ value: Decimal) -> String {
        switch kind {
        case .carbs: return "\(value) " + unitLabel
        case .bolus: return "\(value) " + unitLabel
        case .glucose:
            return homeState.units == .mmolL
                ? (Formatter.decimalFormatterWithOneFractionDigit.string(from: value as NSNumber) ?? "")
                : (Formatter.integerFormatter.string(from: value as NSNumber) ?? "")
        case .basal: return "\(value)"
        }
    }

    // MARK: - Contextual note (real data, no placeholders)

    private var suggestionString: String? {
        guard treatments.insulinCalculated > 0 else { return nil }
        return Formatter.decimalFormatterWithTwoFractionDigits
            .string(from: treatments.insulinCalculated as NSNumber)
    }

    private var iobString: String {
        Formatter.decimalFormatterWithTwoFractionDigits.string(from: treatments.iob as NSNumber) ?? "0"
    }

    private var noteText: String {
        switch kind {
        case .carbs:
            if aiAnalysisApplied, !treatments.note.isEmpty, amount > 0, let suggestion = suggestionString {
                if let hours = treatments.mealAbsorptionHours, hours > BaseCarbsStorage.standardAbsorptionHours {
                    return String(
                        localized: "\(treatments.note) · spread over \(hours.description) h · suggests \(suggestion) U."
                    )
                }
                return String(localized: "\(treatments.note) · Bolus calculator suggests \(suggestion) U.")
            }
            if amount > 0, let suggestion = suggestionString {
                return String(localized: "Bolus calculator suggests \(suggestion) U for this entry.")
            }
            return String(localized: "Saved to history and counted toward COB.")
        case .bolus:
            if let suggestion = suggestionString {
                return String(localized: "Recommended \(suggestion) U · IOB \(iobString) U")
            }
            return String(localized: "IOB \(iobString) U")
        case .glucose:
            let lower = quickLabel(glucoseLimits.lowerBound)
            let upper = quickLabel(glucoseLimits.upperBound)
            return String(localized: "Used by the bolus calculator · \(lower)–\(upper) \(homeState.units.rawValue)")
        case .basal:
            if let profileBasalRateString {
                return String(localized: "Profile basal is \(profileBasalRateString) · overrides the loop for 30 minutes.")
            }
            return String(localized: "Overrides the loop for 30 minutes.")
        }
    }

    /// Same rule as TreatmentsRootView.bolusWarning (pump bolus only). The gate
    /// decision passes the captured amount so it can never diverge from the dose.
    private func bolusWarningEvaluation(for bolusAmount: Decimal) -> (shouldConfirm: Bool, message: String) {
        guard kind == .bolus, bolusAmount > 0 else { return (false, "") }
        let isGlucoseVeryLow = treatments.currentBG < 54
        let isForecastVeryLow = treatments.minPredBG < 54
        let message = isGlucoseVeryLow
            ? String(localized: "Glucose is very low.")
            : isForecastVeryLow ? String(localized: "Glucose forecast is very low.") : ""
        let shouldConfirm = treatments.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)
        return (shouldConfirm, message)
    }

    private var bolusWarning: (shouldConfirm: Bool, message: String) {
        bolusWarningEvaluation(for: amount)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 14)

                stepperRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)

                quickAmountsRow
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)

                if showsAIRow {
                    aiEntryRow
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }

                Text(noteText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                if !bolusWarning.message.isEmpty {
                    Text(bolusWarning.message)
                        .font(.subheadline)
                        .foregroundStyle(Color.loopRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                commitButton
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Spacer(minLength: 0)
            }
            .blur(radius: treatments.isAwaitingDeterminationResult ? 5 : 0)

            if treatments.isAwaitingDeterminationResult {
                CustomProgressView(text: ProgressText.updatingIOB.displayName)
            }
        }
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear {
            // Same wiring order as TreatmentsRootView.configureView: isActive must
            // be set before the resolver so subscribe() runs. This drawer is not a
            // router modal, so completing a treatment must not drive hideModal().
            if treatments.resolver == nil {
                treatments.isActive = true
                treatments.isPresentedAsRouterModal = false
                treatments.resolver = resolver
            }
            Task { @MainActor in
                treatments.insulinCalculated = await treatments.calculateInsulin()
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            ctaEvaluationTask?.cancel()
            treatments.isActive = false
            treatments.addButtonPressed = false
            treatments.cleanupTreatmentState()
        }
        .onChange(of: amount) {
            // Mirror the edited value into the model and refresh the simulation,
            // matching TreatmentsRootView: carbs are debounced (handleDebouncedInput),
            // the bolus amount re-simulates the forecast so the low-glucose gate
            // sees bolus-aware minPredBG.
            switch kind {
            case .carbs:
                debounceTask?.cancel()
                let carbs = amount
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    treatments.carbs = carbs
                    await treatments.updateForecasts()
                    treatments.insulinCalculated = await treatments.calculateInsulin()
                }
            case .bolus:
                debounceTask?.cancel()
                let bolus = amount
                debounceTask = Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    treatments.amount = bolus
                    await treatments.updateForecasts()
                }
            case .basal,
                 .glucose:
                break
            }
        }
        .onChange(of: treatments.isAwaitingDeterminationResult) { wasAwaiting, isAwaiting in
            // Treatment finished (determination arrived or bolus failed): close
            // unless the failure alert needs to stay up. Never claim success for a
            // failed bolus — pump errors surface through the app's alert banner.
            if wasAwaiting, !isAwaiting, treatments.addButtonPressed, !treatments.showDeterminationFailureAlert {
                if kind == .bolus, !treatments.lastBolusFailed {
                    onCommitted(String(localized: "Bolus started"))
                }
                dismiss()
            }
        }
        .alert("Error while processing Treatment", isPresented: Bindable(treatments).showDeterminationFailureAlert) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("\(treatments.determinationFailureMessage)")
        }
        .confirmationDialog(
            bolusWarning.message + " " +
                String(localized: "Bolus \((pendingBolusAmount ?? amount).description) U?"),
            isPresented: $showLowGlucoseConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) { pendingBolusAmount = nil }
            Button(String(localized: "Ignore Warning and Enact Bolus"), role: .destructive) {
                if let pendingBolusAmount {
                    commitBolus(pendingBolusAmount)
                }
                pendingBolusAmount = nil
            }
        }
        .sheet(isPresented: $showMealPhotoSheet) {
            MealPhotoAnalysisView(state: treatments, onApplied: syncAppliedAnalysis)
        }
        .sheet(isPresented: $showFoodSearchSheet) {
            FoodSearchView(state: treatments, onApplied: syncAppliedAnalysis)
        }
    }

    /// Mirrors an accepted AI meal scan / food search result into the drawer's
    /// stepper. applyMealPhotoAnalysis already clamped the values and set
    /// fat/protein/note on the treatments model; commit keeps them.
    private func syncAppliedAnalysis() {
        aiAnalysisApplied = true
        amount = treatments.carbs
    }

    /// The full editor uses its own StateModel, so everything entered here —
    /// the stepper amount and any applied AI scan/search values — must be handed
    /// over explicitly or "Full Editor" silently starts from zero.
    private func handOffToFullEditor() {
        var pending = Treatments.PendingEntry()
        switch kind {
        case .carbs:
            pending.carbs = amount
            if aiAnalysisApplied {
                pending.fat = treatments.fat
                pending.protein = treatments.protein
                pending.note = treatments.note
                pending.mealAbsorptionHours = treatments.mealAbsorptionHours
                pending.useFattyMealCorrectionFactor = treatments.useFattyMealCorrectionFactor
            }
        case .bolus:
            pending.bolusAmount = amount
        case .basal,
             .glucose:
            break
        }
        Treatments.pendingEntry = pending.isEmpty ? nil : pending
    }

    private var header: some View {
        ZStack {
            Text(title)
                .font(.system(size: 20, weight: .bold))

            HStack {
                if kind == .carbs || kind == .bolus {
                    Button {
                        handOffToFullEditor()
                        dismiss()
                        homeState.showModal(for: .treatmentView)
                    } label: {
                        Text("Full Editor")
                            .font(.subheadline)
                            .foregroundStyle(Color.tabBar)
                    }
                    .buttonStyle(.plain)
                } else if kind == .basal {
                    Button {
                        dismiss()
                        homeState.showModal(for: .manualTempBasal)
                    } label: {
                        Text("All Options")
                            .font(.subheadline)
                            .foregroundStyle(Color.tabBar)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// While a bolus gate evaluation or a commit is in flight, the amount must not
    /// change: the gate decision and the delivered dose stay one and the same.
    private var controlsLocked: Bool {
        isEvaluatingBolus || treatments.addButtonPressed || treatments.isAwaitingDeterminationResult
    }

    private var stepperRow: some View {
        HStack(spacing: 22) {
            stepperButton(systemName: "minus", enabled: amount - step >= 0 && !controlsLocked) {
                // Action-time guard: .disabled only applies on the next render, so a
                // same-run-loop second touch could otherwise slip past the lock.
                guard !controlsLocked else { return }
                amount = max(0, amount - step)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(amountString)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(unitLabel)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 140)

            stepperButton(systemName: "plus", enabled: !plusDisabled && !controlsLocked) {
                guard !controlsLocked else { return }
                amount += step
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var plusDisabled: Bool {
        switch kind {
        case .basal: return amount + step > maxBasalRate
        case .glucose: return amount + step > glucoseLimits.upperBound
        default: return false
        }
    }

    private func stepperButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(enabled ? .primary : Color.secondary.opacity(0.4))
                .frame(width: 54, height: 54)
                .glassCard(radius: 16, opacity: 0.7)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Whether the AI scan/search row is shown: carbs entry only, and only when the
    /// meal photo analysis feature (which also provides the API key) is enabled.
    private var showsAIRow: Bool {
        kind == .carbs && treatments.mealPhotoAnalysisEnabled
    }

    /// Scan Meal (camera) and Search Food (text lookup) shortcuts for the carbs entry.
    private var aiEntryRow: some View {
        HStack(spacing: 8) {
            Button {
                guard !controlsLocked else { return }
                showMealPhotoSheet = true
            } label: {
                Label(String(localized: "Scan Meal"), systemImage: "camera.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .glassCard(radius: GlassDesign.tileRadius, opacity: 0.7)
            }
            .buttonStyle(.plain)
            .disabled(controlsLocked)

            Button {
                guard !controlsLocked else { return }
                showFoodSearchSheet = true
            } label: {
                Label(String(localized: "Search Food"), systemImage: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .glassCard(radius: GlassDesign.tileRadius, opacity: 0.7)
            }
            .buttonStyle(.plain)
            .disabled(controlsLocked)
        }
    }

    private var quickAmountsRow: some View {
        HStack(spacing: 8) {
            ForEach(quickAmounts, id: \.self) { value in
                Button {
                    guard !controlsLocked else { return }
                    amount = value
                } label: {
                    Text(quickLabel(value))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .glassCard(radius: GlassDesign.tileRadius, opacity: 0.7)
                }
                .buttonStyle(.plain)
                .disabled(controlsLocked)
            }
        }
    }

    private var commitButton: some View {
        Button {
            if kind == .bolus {
                // Re-simulate with the pending bolus before deciding the gate so a
                // stale forecast can never skip the low-glucose confirmation
                // (parity with the Treatments screen, where the simulation runs on
                // every amount change). The amount is captured here: the gate and
                // the delivery always use this value, and if the drawer is
                // dismissed or another commit started meanwhile, nothing enacts.
                isEvaluatingBolus = true
                debounceTask?.cancel()
                let evaluatedAmount = amount
                ctaEvaluationTask = Task { @MainActor in
                    treatments.amount = evaluatedAmount
                    await treatments.updateForecasts()
                    isEvaluatingBolus = false
                    guard !Task.isCancelled, treatments.isActive, !treatments.addButtonPressed else { return }
                    if bolusWarningEvaluation(for: evaluatedAmount).shouldConfirm {
                        pendingBolusAmount = evaluatedAmount
                        showLowGlucoseConfirm = true
                    } else {
                        commitBolus(evaluatedAmount)
                    }
                }
            } else {
                commit()
            }
        } label: {
            Text(ctaLabel)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(
                    commitDisabled ? Color.secondary : (colorScheme == .dark ? Color.bgDarkerDarkBlue : Color.white)
                )
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    bolusLimitExceeded || carbLimitExceeded
                        ? Color.loopRed.opacity(0.85)
                        : commitDisabled ? Color.primary.opacity(0.12) : accentColor
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(commitDisabled)
    }

    // MARK: - Commit paths

    /// Pump bolus via invokeTreatmentsTask: biometric unlock, min(amount, maxBolus)
    /// clamp, stale-glucose guard, progress + auto-dismiss. Takes the exact amount
    /// the low-glucose gate evaluated, never the live stepper value.
    private func commitBolus(_ bolusAmount: Decimal) {
        // Locks the drawer's controls by construction before invokeTreatmentsTask
        // re-asserts it asynchronously.
        treatments.addButtonPressed = true
        treatments.carbs = 0
        treatments.externalInsulin = false
        treatments.amount = bolusAmount
        treatments.invokeTreatmentsTask()
    }

    private func commit() {
        switch kind {
        case .carbs:
            // Same path the Treatments screen action button uses: saveMeal clamps
            // to maxCarbs, persists, and runs determineBasalSync. An applied AI
            // scan/search keeps the fat, protein, and meal-name note it set.
            debounceTask?.cancel()
            treatments.carbs = amount
            treatments.amount = 0
            if !aiAnalysisApplied {
                treatments.fat = 0
                treatments.protein = 0
            }
            treatments.invokeTreatmentsTask()
            onCommitted(String(localized: "Logging \(amountString) g carbs"))
            dismiss()
        case .bolus:
            // Bolus commits must go through commitBolus(_:) with the amount that
            // was captured at gate-evaluation time.
            commitBolus(amount)
        case .glucose:
            homeState.addManualGlucose(displayValue: amount)
            onCommitted(String(localized: "Glucose \(amountString) \(homeState.units.rawValue) saved"))
            dismiss()
        case .basal:
            // Same call the ManualTempBasal screen enact button makes, fixed 30 min.
            let rate = min(amount, maxBasalRate)
            Task {
                await homeState.apsManager.enactTempBasal(
                    rate: Double(truncating: rate as NSNumber),
                    duration: 30 * 60
                )
            }
            onCommitted(String(localized: "Setting temp basal \(amountString) U/hr for 30 min"))
            dismiss()
        }
    }
}
