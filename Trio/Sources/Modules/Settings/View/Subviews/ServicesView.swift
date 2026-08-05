//
//  FeatureSettingsView.swift
//  Trio
//
//  Created by Deniz Cengiz on 26.07.24.
//
import Foundation
import HealthKit
import SwiftUI
import Swinject

struct ServicesView: BaseView {
    let resolver: Resolver

    @ObservedObject var state: Settings.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text("Connected Services").glassCaption(),
                content: {
                    SettingsIconRow(symbol: "cloud.fill", tint: Color.glassCyan, label: Text("Nightscout"))
                        .navigationLink(to: .nighscoutConfig, from: self)
                    SettingsIconRow(symbol: "water.waves", tint: .insulin, label: Text("Tidepool"))
                        .navigationLink(to: .tidepoolConfig, from: self)
                    SettingsIconRow(symbol: "message.fill", tint: .loopGreen, label: Text("Twilio SMS"))
                        .navigationLink(to: .twilioConfig, from: self)
                    if HKHealthStore.isHealthDataAvailable() {
                        SettingsIconRow(symbol: "heart.fill", tint: .loopRed, label: Text("Apple Health"))
                            .navigationLink(to: .healthkit, from: self)
                    }
                }
            )
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Services")
        .navigationBarTitleDisplayMode(.automatic)
    }
}
