import CoreData
import SwiftUI
import Swinject

extension SiteTracker {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        @State private var showLogSheet = false
        @State private var logKind: SiteChangeKind = .site
        @State private var logLocation: SiteBodyLocation?
        @State private var logNote = ""
        @State private var logDate = Date()
        @State private var changeToEdit: SiteChangeStored?
        @State private var editedLocation: SiteBodyLocation?

        var body: some View {
            List {
                currentSection
                logSection
                historySection
                rotationSection
                remindersSection
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Site & Sensor Tracker")
            .navigationBarTitleDisplayMode(.automatic)
            .sheet(isPresented: $showLogSheet) {
                logChangeSheet
            }
            .sheet(item: $changeToEdit) { change in
                editLocationSheet(for: change)
            }
        }

        // MARK: - Current

        private var currentSection: some View {
            Section(header: Text("Current")) {
                HStack {
                    Image(systemName: "bandage.fill")
                        .foregroundStyle(Color.insulin)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pump Site")
                        if let location = state.currentSite?.location
                            .flatMap(SiteBodyLocation.init(rawValue:))
                        {
                            Text(location.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(state.ageString(since: state.currentSite?.date))
                        .foregroundStyle(state.siteAgeColor(since: state.currentSite?.date))
                }
                HStack {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .foregroundStyle(Color.loopGreen)
                    Text("CGM Sensor")
                    Spacer()
                    Text(state.ageString(since: state.currentSensor?.date))
                        .foregroundStyle(.secondary)
                }
            }
            .listRowBackground(Color.chart)
        }

        private var logSection: some View {
            Section {
                Button {
                    logKind = .site
                    logLocation = nil
                    logNote = ""
                    logDate = Date()
                    showLogSheet = true
                } label: {
                    Label("Log Site Change", systemImage: "plus.circle.fill")
                }
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - History

        private var historySection: some View {
            Section(header: Text("History")) {
                if state.siteChanges.isEmpty {
                    Text("No site or sensor changes recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.siteChanges) { change in
                        historyRow(change)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                editedLocation = change.location.flatMap(SiteBodyLocation.init(rawValue:))
                                changeToEdit = change
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    state.delete(change)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private func historyRow(_ change: SiteChangeStored) -> some View {
            HStack {
                Image(systemName: change.kind == SiteChangeKind.sensor.rawValue
                    ? "sensor.tag.radiowaves.forward.fill"
                    : "bandage.fill")
                    .foregroundStyle(change.kind == SiteChangeKind.sensor.rawValue ? Color.loopGreen : Color.insulin)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    HStack(spacing: 4) {
                        if let location = change.location.flatMap(SiteBodyLocation.init(rawValue:)) {
                            Text(location.displayName)
                        }
                        if let note = change.note, !note.isEmpty {
                            Text("· \(note)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(SiteChangeSource(rawValue: change.source ?? "")?.displayName ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // MARK: - Rotation

        private var rotationSection: some View {
            Section(
                header: Text("Rotation"),
                footer: Text("Based on the locations logged for site changes in the last 180 days.")
            ) {
                if state.rotationSummary.isEmpty {
                    Text("Log site changes with a body location to see your rotation.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(state.rotationSummary) { entry in
                        rotationRow(entry)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        @ViewBuilder private func rotationRow(_ entry: SiteRotationMath.Entry) -> some View {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.location.displayName)
                    if let lastUsed = entry.lastUsed {
                        Text("Last used \(lastUsed.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if SiteRotationMath.isHeavilyUsed(count: entry.count, total: state.locatedSiteChangeCount) {
                    Text("Heavily used")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if SiteRotationMath.isRested(lastUsed: entry.lastUsed, now: Date()) {
                    Text("Rested")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text("×\(entry.count)")
                    .foregroundStyle(.secondary)
            }
        }

        // MARK: - Reminders

        private var remindersSection: some View {
            Section(
                header: Text("Reminders"),
                footer: Text(
                    "Site changes are detected automatically from pump events (site change and rewind); sensor starts come from your CGM session data. These reminders cover site and cannula age only - pod expiry alerts remain handled by the pump."
                )
            ) {
                Toggle("Site Change Reminder", isOn: $state.siteReminderEnabled)
                if state.siteReminderEnabled {
                    Stepper(value: $state.siteReminderIntervalDays, in: 1 ... 10) {
                        HStack {
                            Text("Remind after")
                            Spacer()
                            Text("\(state.siteReminderIntervalDays) d")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Site Absorption Notices", isOn: $state.siteDegradationAlertsEnabled)
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Sheets

        private var logChangeSheet: some View {
            NavigationStack {
                Form {
                    Section {
                        Picker("Type", selection: $logKind) {
                            ForEach(SiteChangeKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        Picker("Location", selection: $logLocation) {
                            Text("Not Set").tag(nil as SiteBodyLocation?)
                            ForEach(SiteBodyLocation.allCases) { location in
                                Text(location.displayName).tag(location as SiteBodyLocation?)
                            }
                        }
                        DatePicker("Date", selection: $logDate, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        TextField("Note (optional)", text: $logNote)
                            .onChange(of: logNote) { _, newValue in
                                if newValue.count > 50 {
                                    logNote = String(newValue.prefix(50))
                                }
                            }
                    }
                }
                .navigationTitle("Log Change")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showLogSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let kind = logKind
                            let location = logLocation
                            let note = logNote
                            let date = logDate
                            showLogSheet = false
                            Task {
                                await state.logChange(kind: kind, location: location, note: note, date: date)
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }

        private func editLocationSheet(for change: SiteChangeStored) -> some View {
            NavigationStack {
                Form {
                    Section {
                        Picker("Location", selection: $editedLocation) {
                            Text("Not Set").tag(nil as SiteBodyLocation?)
                            ForEach(SiteBodyLocation.allCases) { location in
                                Text(location.displayName).tag(location as SiteBodyLocation?)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
                .navigationTitle("Edit Location")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { changeToEdit = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            state.updateLocation(of: change, to: editedLocation)
                            changeToEdit = nil
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}
