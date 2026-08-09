//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct FeatureSettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Trio Features").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "plus.forwardslash.minus", tint: .insulin, label: Text("Bolus Calculator"))
                        .navigationLink(to: .bolusCalculatorConfig, from: self)
                    SettingsIconRow(symbol: "fork.knife", tint: .loopYellow, label: Text("Meal Settings"))
                        .navigationLink(to: .mealSettings, from: self)
                    SettingsIconRow(symbol: "square.2.layers.3d.fill", tint: Color.glassCyan, label: Text("Shortcuts"))
                        .navigationLink(to: .shortcutsConfig, from: self)
                    SettingsIconRow(
                        symbol: "antenna.radiowaves.left.and.right",
                        tint: Color.tabBar,
                        label: Text("Remote Control")
                    )
                    .navigationLink(to: .remoteControlConfig, from: self)
                    SettingsIconRow(symbol: "doc.text.fill", tint: .tabBar, label: Text("Clinic Report (AGP)"))
                        .navigationLink(to: .clinicReport, from: self)
                    SettingsIconRow(symbol: "chart.line.text.clipboard", tint: .purple, label: Text("Insights"))
                        .navigationLink(to: .insights, from: self)
                    SettingsIconRow(symbol: "book.fill", tint: .orange, label: Text("Food Library"))
                        .navigationLink(to: .foodLibrary, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Trio Personalization").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "paintbrush.fill", tint: .uam, label: Text("User Interface"))
                        .navigationLink(to: .userInterfaceSettings, from: self)
                    SettingsIconRow(symbol: "square.grid.2x2.fill", tint: .zt, label: Text("App Icons"))
                        .navigationLink(to: .iconConfig, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Anonymized Data Sharing").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "waveform.path.ecg", tint: .loopGreen, label: Text("App Diagnostics"))
                        .navigationLink(to: .appDiagnostics, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Feature Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
