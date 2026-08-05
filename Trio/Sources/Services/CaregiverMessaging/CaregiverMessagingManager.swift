import CoreData
import Foundation
import Swinject

/// Builds caregiver-friendly status texts from the latest glucose and treatment data.
///
/// iOS does not allow apps to send iMessages without user interaction, so this manager only
/// composes the message content. Delivery happens either through a pre-filled
/// `MFMessageComposeViewController` (user confirms with one tap) or through the
/// `CaregiverMessageIntent` App Intent combined with the Shortcuts "Send Message" action,
/// which can run unattended in a personal automation.
protocol CaregiverMessagingManager {
    var isEnabled: Bool { get }
    var recipients: [String] { get }
    @MainActor func statusMessage() -> String
}

enum CaregiverMessage {
    struct Input {
        var glucoseValue: Int?
        var trendSymbol: String?
        var deltaValue: Int?
        var readingDate: Date?
        var iob: Double?
        var cob: Double?
        var alarm: GlucoseAlarm?
        var units: GlucoseUnits = .mgdL
        var includeIOBAndCOB: Bool = true
    }

    static func compose(from input: Input) -> String {
        guard let glucoseValue = input.glucoseValue else {
            return String(
                localized: "Trio: No recent glucose reading is available.",
                comment: "Caregiver message when no recent glucose data exists"
            )
        }

        let lead: String
        switch input.alarm {
        case .low:
            lead = String(localized: "Trio LOW glucose alert:", comment: "Caregiver message lead for a low glucose alarm")
        case .high:
            lead = String(localized: "Trio HIGH glucose alert:", comment: "Caregiver message lead for a high glucose alarm")
        case .none:
            lead = String(localized: "Trio update:", comment: "Caregiver message lead without an active alarm")
        }

        var parts: [String] = [lead, glucoseValue.formatted(for: input.units) + " " + input.units.rawValue]

        if let trendSymbol = input.trendSymbol {
            parts.append(trendSymbol)
        }

        if let delta = input.deltaValue {
            parts.append(deltaText(delta, units: input.units))
        }

        if let readingDate = input.readingDate {
            parts.append(
                String(
                    format: String(localized: "(as of %@)", comment: "Caregiver message reading timestamp"),
                    timeFormatter.string(from: readingDate)
                )
            )
        }

        var message = parts.joined(separator: " ")

        if input.includeIOBAndCOB {
            var details: [String] = []
            if let iob = input.iob {
                details.append(
                    String(
                        format: String(localized: "IOB: %@ U", comment: "Caregiver message insulin on board"),
                        insulinFormatter.string(from: iob as NSNumber) ?? "\(iob)"
                    )
                )
            }
            if let cob = input.cob {
                details.append(
                    String(
                        format: String(localized: "COB: %@ g", comment: "Caregiver message carbs on board"),
                        carbsFormatter.string(from: cob as NSNumber) ?? "\(cob)"
                    )
                )
            }
            if !details.isEmpty {
                message += ". " + details.joined(separator: ", ")
            }
        }

        return message
    }

    /// Splits the raw recipients setting (comma, semicolon or newline separated) into a clean list.
    static func recipients(from rawList: String) -> [String] {
        rawList
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func deltaText(_ delta: Int, units: GlucoseUnits) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = units == .mmolL ? 1 : 0
        formatter.positivePrefix = "+"
        let value: NSNumber = units == .mmolL ? delta.asMmolL as NSDecimalNumber : delta as NSNumber
        return formatter.string(from: value) ?? "\(delta)"
    }

    private static let insulinFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let carbsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

final class BaseCaregiverMessagingManager: CaregiverMessagingManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var iobService: IOBService!

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    var isEnabled: Bool {
        settingsManager.settings.caregiverMessagingEnabled
    }

    var recipients: [String] {
        CaregiverMessage.recipients(from: settingsManager.settings.caregiverRecipients)
    }

    @MainActor func statusMessage() -> String {
        let settings = settingsManager.settings
        var input = CaregiverMessage.Input(
            units: settings.units,
            includeIOBAndCOB: settings.caregiverMessagesIncludeIOBCOB
        )

        do {
            let readings = try CoreDataStack.shared.fetchEntities(
                ofType: GlucoseStored.self,
                onContext: viewContext,
                predicate: NSPredicate.predicateFor30MinAgo,
                key: "date",
                ascending: false,
                fetchLimit: 2
            ) as? [GlucoseStored] ?? []

            if let lastReading = readings.first {
                input.glucoseValue = Int(lastReading.glucose)
                input.trendSymbol = lastReading.directionEnum?.symbol
                input.readingDate = lastReading.date
                if let previousReading = readings.dropFirst().first {
                    input.deltaValue = Int(lastReading.glucose - previousReading.glucose)
                }
            }

            let determinations = try CoreDataStack.shared.fetchEntities(
                ofType: OrefDetermination.self,
                onContext: viewContext,
                predicate: NSPredicate.enactedDetermination,
                key: "deliverAt",
                ascending: false,
                fetchLimit: 1
            ) as? [OrefDetermination] ?? []

            input.iob = Double(truncating: (iobService.currentIOB ?? 0.0) as NSNumber)
            input.cob = Double(truncating: (determinations.first?.cob ?? 0) as NSNumber)
        } catch {
            debugPrint(
                "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to fetch data for caregiver message: \(error)"
            )
        }

        input.alarm = glucoseStorage.alarm
        return CaregiverMessage.compose(from: input)
    }
}
