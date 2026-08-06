import SwiftUI
import Swinject

extension MealSettings {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false
        @State private var displayPickerMaxCarbs: Bool = false
        @State private var displayPickerMaxFat: Bool = false
        @State private var displayPickerMaxProtein: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var conversionFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1

            return formatter
        }

        private var intFormater: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            return formatter
        }

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }

        /// Models offered in a picker: the fetched list, always including the
        /// current selection so a stored choice never falls out of the picker
        /// (e.g. before the list has loaded or while offline).
        private func modelPickerOptions(for selected: String) -> [AnthropicModelInfo] {
            var options = state.availableModels
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !options.contains(where: { $0.id == trimmed }) {
                options.append(AnthropicModelInfo(id: trimmed, displayName: trimmed))
            }
            return options
        }

        /// One model-picker row (shared layout for the photo and search models).
        private func modelPickerRow(
            title: String,
            selection: Binding<String>,
            defaultModelId: String
        ) -> some View {
            HStack {
                Image(systemName: "cpu")
                Picker(title, selection: selection) {
                    Text("Default (\(defaultModelId))").tag("")
                    ForEach(modelPickerOptions(for: selection.wrappedValue)) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        var body: some View {
            List {
                Section(
                    header: Text("Limits per Entry"),
                    content: {
                        VStack {
                            VStack {
                                HStack {
                                    Text("Max Carbs")

                                    Spacer()

                                    Group {
                                        Text(state.maxCarbs.description)
                                            .foregroundColor(!displayPickerMaxCarbs ? .primary : .accentColor)

                                        Text(" g").foregroundColor(.secondary)
                                    }
                                }
                                .onTapGesture {
                                    displayPickerMaxCarbs.toggle()
                                }
                            }.padding(.top)

                            if displayPickerMaxCarbs {
                                let setting = PickerSettingsProvider.shared.settings.maxCarbs
                                Picker(selection: $state.maxCarbs, label: Text("")) {
                                    ForEach(
                                        PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                        id: \.self
                                    ) { value in
                                        Text("\(value.description)").tag(value)
                                    }
                                }
                                .pickerStyle(WheelPickerStyle())
                                .frame(maxWidth: .infinity)
                            }

                            if state.useFPUconversion {
                                VStack {
                                    HStack {
                                        Text("Max Fat")

                                        Spacer()

                                        Group {
                                            Text(state.maxFat.description)
                                                .foregroundColor(!displayPickerMaxFat ? .primary : .accentColor)

                                            Text(" g").foregroundColor(.secondary)
                                        }
                                    }
                                    .onTapGesture {
                                        displayPickerMaxFat.toggle()
                                    }
                                }
                                .padding(.top)

                                if displayPickerMaxFat {
                                    let setting = PickerSettingsProvider.shared.settings.maxFat
                                    Picker(selection: $state.maxFat, label: Text("")) {
                                        ForEach(
                                            PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                            id: \.self
                                        ) { value in
                                            Text("\(value.description)").tag(value)
                                        }
                                    }
                                    .pickerStyle(WheelPickerStyle())
                                    .frame(maxWidth: .infinity)
                                }

                                VStack {
                                    HStack {
                                        Text("Max Protein")

                                        Spacer()

                                        Group {
                                            Text(state.maxProtein.description)
                                                .foregroundColor(!displayPickerMaxProtein ? .primary : .accentColor)

                                            Text(" g").foregroundColor(.secondary)
                                        }
                                    }
                                    .onTapGesture {
                                        displayPickerMaxProtein.toggle()
                                    }
                                }
                                .padding(.top)

                                if displayPickerMaxProtein {
                                    let setting = PickerSettingsProvider.shared.settings.maxProtein
                                    Picker(selection: $state.maxProtein, label: Text("")) {
                                        ForEach(
                                            PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                            id: \.self
                                        ) { value in
                                            Text("\(value.description)").tag(value)
                                        }
                                    }
                                    .pickerStyle(WheelPickerStyle())
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            HStack(alignment: .center) {
                                Text(
                                    "Set limits for each type of macro per meal entry."
                                )
                                .lineLimit(nil)
                                .font(.footnote)
                                .foregroundColor(.secondary)

                                Spacer()
                                Button(
                                    action: {
                                        hintLabel = String(localized: "Limits per Entry")
                                        selectedVerboseHint =
                                            AnyView(
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text("Max Carbs:").bold()
                                                    Text("Enter the largest carb value allowed per meal entry")
                                                    Text("Max Fat:").bold()
                                                    Text("Enter the largest fat value allowed per meal entry")
                                                    Text("Max Protein:").bold()
                                                    Text("Enter the largest protein value allowed per meal entry")
                                                }
                                            )
                                        shouldDisplayHint.toggle()
                                    },
                                    label: {
                                        HStack {
                                            Image(systemName: "questionmark.circle")
                                        }
                                    }
                                ).buttonStyle(BorderlessButtonStyle())
                            }.padding(.top)
                        }.padding(.bottom)
                    }
                ).listRowBackground(Color.chart)

                SettingInputSection(
                    decimalValue: $state.maxMealAbsorptionTime,
                    booleanValue: $booleanPlaceholder,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Maximum Meal Absorption Time")
                        }
                    ),
                    units: state.units,
                    type: .decimal("maxMealAbsorptionTime"),
                    label: String(localized: "Max Meal Absorption Time"),
                    miniHint: String(
                        localized: "The maximum duration for tracking carb entries in estimating Carbs on Board (COB)"
                    ),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: 6 hours").bold()
                        Text(
                            "Carb entries will be fully decayed by the number of hours specified as Max Meal Absorption Time. Meals that are high in fat and/or protein can have long lasting effects on glucose levels. To allow such late meal effects to be considered by the carb decay model, a longer Max Meal Absorption Time than the default 6 hours can be set."
                        )
                        Text(
                            "If carb entries decay too slowly, it is possible to set a lower than default setting. But this should typically be adressed by tuning ISF and CR settings instead, which in combination determines the rate of carb decay."
                        )
                        Text(
                            "Min 4 hours, max 10 hours."
                        )
                    }
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.useFPUconversion,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable Fat and Protein Entries")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Fat and Protein Entries"),
                    miniHint: String(localized: "Add fat and protein macros to meal entries."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        VStack(spacing: 10) {
                            Text(
                                "Enabling this setting allows you to log fat and protein, which are then converted into future carb equivalents using the Warsaw Method."
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Warsaw Method:").bold()
                                Text(
                                    "The Warsaw Method helps account for the delayed glucose spikes caused by fat and protein in meals. It uses Fat-Protein Units (FPU) to calculate the carb effect from fat and protein. The system spreads insulin delivery over several hours to mimic natural insulin release, helping to manage post-meal glucose spikes."
                                )
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("Fat Conversion").bold()
                                Text("𝑭 = fat(g) × 90%")
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("Protein Conversion").bold()
                                Text("𝑷 = protein(g) × 40%")
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("FPU Conversion").bold()
                                Text("𝑭 + 𝑷 = g CHO")
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    "You can personalize the conversion calculation by adjusting the following settings that will appear when this option is enabled:"
                                )
                                Text("• Fat and Protein Delay")
                                Text("• Spread Interval")
                                Text("• Fat and Protein Percentage")
                            }
                        }
                    },
                    headerText: String(localized: "Fat and Protein")
                )
                if state.useFPUconversion {
                    SettingInputSection(
                        decimalValue: $state.delay,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Fat and Protein Delay")
                            }
                        ),
                        units: state.units,
                        type: .decimal("delay"),
                        label: String(localized: "Fat and Protein Delay"),
                        miniHint: String(localized: "Delay between fat & protein entry and first FPU entry."),
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 60 min").bold()
                            Text(
                                "The Fat and Protein Delay setting defines the time between when you log fat and protein and when the system starts delivering insulin for the Fat-Protein Unit Carb Equivalents (FPUs)."
                            )
                            Text(
                                "This delay accounts for the slower absorption of fat and protein, as calculated by the Warsaw Method, ensuring insulin delivery is properly timed to manage glucose spikes caused by high-fat, high-protein meals."
                            )
                        }
                    )

                    SettingInputSection(
                        decimalValue: $state.minuteInterval,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Spread Interval")
                            }
                        ),
                        units: state.units,
                        type: .decimal("minuteInterval"),
                        label: String(localized: "Spread Interval"),
                        miniHint: String(localized: "Time interval between FPUs."),
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 30 minutes").bold()
                            Text(
                                "This determines how many minutes will be between individual Fat-Protein Unit Carb Equivalent (FPU) entries from a single Fat and/or Protein bolus calculator entry."
                            )
                            Text(
                                "Entries are capped at 33 grams each, with up to three entries, for a max total of 99 grams."
                            )
                        }
                    )

                    SettingInputSection(
                        decimalValue: $state.individualAdjustmentFactor,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Fat and Protein Percentage")
                            }
                        ),
                        units: state.units,
                        type: .decimal("individualAdjustmentFactor"),
                        label: String(localized: "Fat and Protein Percentage"),
                        miniHint: String(localized: "Adjust the Warsaw Method FPU Conversion rate."),
                        verboseHint: VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 50%").bold()
                            VStack(spacing: 10) {
                                Text("This setting changes how much effect the fat and protein entry has on FPUs.")
                                VStack(alignment: .center, spacing: 5) {
                                    Text("50% is half effect:").bold()
                                    Text("(Fat × 45%) + (Protein × 20%)")
                                    Text("100% is full effect:").bold()
                                    Text("(Fat × 90%) + (Protein × 40%)")
                                    Text("110% makes fat-to-carbs ratio essentially equal:").bold()
                                    Text("(Fat × 99%) + (Protein x 44%)")
                                }
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    "Tip: You may find that your normal carb ratio needs to increase to a larger number when you begin adding fat and protein entries. For this reason, it is best to start with a factor of about 50%."
                                )
                            }
                        }
                    )
                }
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.mealPhotoAnalysisEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable AI Meal Photo Analysis")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable AI Meal Photo Analysis"),
                    miniHint: String(
                        localized: "Estimate carbs by photographing your meal or searching for a dish by name, from the bolus calculator and the carbs quick entry."
                    ),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "Adds a camera button to the bolus calculator and Scan Meal / Search Food shortcuts to the carbs quick entry. Take a photo of your meal with a common object (soda can, credit card, fork) placed next to it as a size reference, or describe a dish in text (e.g. a restaurant meal), and AI will identify the components, judge whether the meal is homemade or from a restaurant, and estimate carbs, fat, protein, and how quickly the carbs will absorb."
                        )
                        Text(
                            "The photo or description is sent to Anthropic's Claude API for analysis, which requires your own API key and an internet connection."
                        )
                        Text(
                            "AI estimates can be wrong. Always review the suggested values before logging them or bolusing."
                        ).bold()
                    },
                    headerText: String(localized: "AI Meal Photo Analysis & Food Search")
                )

                if state.mealPhotoAnalysisEnabled {
                    Section {
                        HStack {
                            Image(systemName: "key")
                            SecureField("Anthropic API Key", text: $state.mealPhotoApiKey)
                                .textContentType(.password)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                            if !state.mealPhotoApiKey.isEmpty {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }

                        if !state.mealPhotoApiKey.isEmpty {
                            HStack {
                                modelPickerRow(
                                    title: String(localized: "Photo Model"),
                                    selection: $state.mealAnalysisModelId,
                                    defaultModelId: MealPhotoAnalysis.Config.defaultModel
                                )

                                if state.isLoadingModels {
                                    ProgressView()
                                } else {
                                    Button {
                                        Task { await state.loadAvailableModels() }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Reload available models")
                                }
                            }

                            modelPickerRow(
                                title: String(localized: "Search Model"),
                                selection: $state.foodSearchModelId,
                                defaultModelId: MealPhotoAnalysis.Config.defaultFoodSearchModel
                            )
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(
                                "Create an API key at console.anthropic.com. The key is stored securely in the iOS keychain and is only used to analyze your meal photos and food searches."
                            )
                            Text(
                                "Photo Model analyzes meal photos; Search Model answers text food searches and defaults to a faster model so lookups stay quick. The lists show the models your API key can access."
                            )
                            if let error = state.modelsLoadError {
                                Text("Could not load models: \(error)")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.unannouncedMealDetectionEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Unannounced Meal Detection")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Unannounced Meal Detection"),
                    miniHint: String(localized: "Prompt to log carbs when glucose rises like a meal but nothing was logged."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: ON").bold()
                        Text(
                            "When glucose rises quickly while no carbs are on board and no meal was logged recently, Trio prompts you to log the meal - as an alert while the app is open, or as a notification otherwise. Tapping the notification opens the meal entry."
                        )
                        Text(
                            "This only ever reminds you to log; it never logs carbs or doses insulin by itself. Prompts are limited to once per hour, and notifications additionally respect the Carbs notification setting."
                        )
                    },
                    headerText: String(localized: "Unannounced Meals")
                )
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            // Loads the model list on appear and after API key edits (debounced so
            // typing a key does not fire a request per keystroke).
            .task(id: state.mealPhotoAnalysisEnabled ? state.mealPhotoApiKey : "") {
                guard state.mealPhotoAnalysisEnabled else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await state.loadAvailableModels()
            }
            .onAppear(perform: configureView)
            .navigationBarTitle("Meal Settings")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }
    }
}
