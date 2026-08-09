//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import SwiftUI
import Swinject

struct TherapySettingsView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Basic Settings").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "ruler", tint: Color.tabBar, label: Text("Units and Limits"))
                        .navigationLink(to: .unitsAndLimits, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Basic Insulin Rates & Targets").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "target", tint: .loopGreen, label: Text("Glucose Targets"))
                        .navigationLink(to: .targetsEditor, from: self)
                    SettingsIconRow(symbol: "drop.fill", tint: .insulin, label: Text("Basal Rates"))
                        .navigationLink(to: .basalProfileEditor, from: self)
                    SettingsIconRow(symbol: "fork.knife", tint: .loopYellow, label: Text("Carb Ratios"))
                        .navigationLink(to: .crEditor, from: self)
                    SettingsIconRow(
                        symbol: "chart.line.downtrend.xyaxis",
                        tint: .zt,
                        label: Text("Insulin Sensitivities")
                    )
                    .navigationLink(to: .isfEditor, from: self)
                }
            )
            .listRowBackground(Color.chart)

            Section(
                header: Text("Guidance").glassCaption(),
                content: {
                    SettingsIconRow(
                        symbol: "function",
                        tint: .purple,
                        label: Text("ISF & CR Calculator")
                    )
                    .navigationLink(to: .therapyRatioCalculator, from: self)
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Therapy Settings")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
