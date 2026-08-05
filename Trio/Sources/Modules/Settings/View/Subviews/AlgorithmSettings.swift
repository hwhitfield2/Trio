//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct AlgorithmSettings: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Oref Algorithm").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "dial.max.fill", tint: .loopGreen, label: Text("Autosens"))
                        .navigationLink(to: .autosensSettings, from: self)
                    SettingsIconRow(symbol: "bolt.fill", tint: .insulin, label: Text("Super Micro Bolus (SMB)"))
                        .navigationLink(to: .smbSettings, from: self)
                    SettingsIconRow(symbol: "function", tint: Color.glassCyan, label: Text("Dynamic Settings"))
                        .navigationLink(to: .dynamicISF, from: self)
                    SettingsIconRow(symbol: "scope", tint: .loopYellow, label: Text("Target Behavior"))
                        .navigationLink(to: .targetBehavior, from: self)
                    SettingsIconRow(symbol: "ellipsis.circle", tint: .zt, label: Text("Additionals"))
                        .navigationLink(to: .algorithmAdvancedSettings, from: self)
                }
            ).listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Algorithm Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
