let cgmOptions: [CGMOption] = [
    CGMOption(name: "Dexcom G5", predicate: { $0.type == .plugin && $0.displayName.contains("G5") }),
    CGMOption(name: "Dexcom G6 / ONE", predicate: { $0.type == .plugin && $0.displayName.contains("G6") }),
    CGMOption(name: "Dexcom G7 / ONE+", predicate: { $0.type == .plugin && $0.displayName.contains("G7") }),
    CGMOption(name: "Dexcom Share", predicate: { $0.type == .plugin && $0.displayName.contains("Dexcom Share") }),
    CGMOption(name: "FreeStyle Libre", predicate: { $0.type == .plugin && $0.displayName == "FreeStyle Libre" }),
    // Matches the LibreLoop plugin when it has been added to the build (Libre 3 / 3+ direct).
    CGMOption(name: "FreeStyle Libre 3", predicate: { $0.type == .plugin && $0.displayName == "FreeStyle Libre 3" }),
    CGMOption(
        name: "FreeStyle Libre Demo",
        predicate: { $0.type == .plugin && $0.displayName == "FreeStyle Libre Demo" }
    ),
    CGMOption(name: "FreeStyle Lingo", predicate: { $0.type == .lingo }),
    CGMOption(name: "Glucose Simulator", predicate: { $0.type == .simulator }),
    CGMOption(name: "Medtronic Enlite", predicate: { $0.type == .enlite }),
    CGMOption(name: "Nightscout as CGM", predicate: { $0.type == .nightscout }),
    CGMOption(name: "xDrip4iOS", predicate: { $0.type == .xdrip })
]
