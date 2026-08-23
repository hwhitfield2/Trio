import Foundation

extension TrioRemoteControl {
    func handleMealCommand(_ payload: CommandPayload) async throws {
        guard payload.carbs != nil || payload.fat != nil || payload.protein != nil else {
            await logError("Command rejected: meal data is incomplete or invalid.", payload: payload)
            return
        }

        let carbsDecimal = payload.carbs != nil ? Decimal(payload.carbs!) : nil
        let fatDecimal = payload.fat != nil ? Decimal(payload.fat!) : nil
        let proteinDecimal = payload.protein != nil ? Decimal(payload.protein!) : nil

        let settings = await TrioApp.resolver.resolve(SettingsManager.self)?.settings
        let maxCarbs = settings?.maxCarbs ?? Decimal(0)
        let maxFat = settings?.maxFat ?? Decimal(0)
        let maxProtein = settings?.maxProtein ?? Decimal(0)

        if let carbs = carbsDecimal, carbs > maxCarbs {
            await logError(
                "Command rejected: carbs amount (\(carbs)g) exceeds the maximum allowed (\(maxCarbs)g).",
                payload: payload
            )
            return
        }
        if let fat = fatDecimal, fat > maxFat {
            await logError("Command rejected: fat amount (\(fat)g) exceeds the maximum allowed (\(maxFat)g).", payload: payload)
            return
        }
        if let protein = proteinDecimal, protein > maxProtein {
            await logError(
                "Command rejected: protein amount (\(protein)g) exceeds the maximum allowed (\(maxProtein)g).",
                payload: payload
            )
            return
        }

        let payloadDate = Date(timeIntervalSince1970: payload.timestamp)
        let taskContext = CoreDataStack.shared.newTaskContext()
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self, onContext: taskContext, predicate: NSPredicate(
                format: "date > %@",
                payloadDate as NSDate
            ), key: "date", ascending: false
        )

        await taskContext.perform {
            guard let recentCarbEntries = results as? [CarbEntryStored] else { return }
            if !recentCarbEntries.isEmpty {
                Task {
                    await self.logError(
                        "Command rejected: newer carb entries have been logged since the command was sent.",
                        payload: payload
                    )
                    return
                }
            }
        }

        let actualDate = payload.scheduledTime.map { Date(timeIntervalSince1970: $0) }

        // A follower's AI food search sends the meal name along; cap it the way
        // the local note field is capped so remote entries can't flood history.
        let trimmedNote = payload.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = trimmedNote.isEmpty ? "Remote meal command" : String(trimmedNote.prefix(25))

        // Clamp a remote absorption estimate to the same window carb storage
        // spreads over (extendedAbsorptionSplit clamps to 4-10 h itself, but a
        // wild value should not be persisted either). Values at or below the
        // standard absorption change nothing and are dropped.
        let absorptionHours: Decimal? = payload.absorptionHours.flatMap { hours in
            guard hours.isFinite, Decimal(hours) > BaseCarbsStorage.standardAbsorptionHours else { return nil }
            return min(Decimal(hours), 10)
        }

        let needsFpuID = fatDecimal ?? 0 > 0 || proteinDecimal ?? 0 > 0 ||
            (absorptionHours ?? 0) > BaseCarbsStorage.standardAbsorptionHours

        let mealEntry = CarbsEntry(
            id: UUID().uuidString, createdAt: Date(), actualDate: actualDate,
            carbs: carbsDecimal ?? 0, fat: fatDecimal, protein: proteinDecimal,
            note: note, enteredBy: CarbsEntry.local, isFPU: false,
            fpuID: needsFpuID ? UUID().uuidString : nil,
            absorptionHours: absorptionHours
        )

        try await carbsStorage.storeCarbs([mealEntry], areFetchedFromRemote: false)

        if payload.bolusAmount == nil {
            await logSuccess(
                "Remote command processed successfully. \(payload.humanReadableDescription())",
                payload: payload,
                customNotificationMessage: "Meal logged"
            )
        }
    }
}
