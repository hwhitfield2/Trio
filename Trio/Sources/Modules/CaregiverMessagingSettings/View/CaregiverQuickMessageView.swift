import MessageUI
import SwiftUI
import Swinject

/// Presented from the "Text Caregiver" glucose alert notification action. Shows the composed
/// status message and opens a pre-filled Messages sheet — one tap on Send delivers it.
struct CaregiverQuickMessageView: View {
    let resolver: Resolver

    @State private var message = ""
    @State private var recipients: [String] = []
    @State private var isPresentingComposer = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(header: Text("Message Preview")) {
                Text(message)
            }.listRowBackground(Color.chart)

            if !recipients.isEmpty {
                Section(header: Text("Recipients")) {
                    ForEach(recipients, id: \.self) { recipient in
                        Text(recipient)
                    }
                }.listRowBackground(Color.chart)
            }

            Section {
                Button {
                    isPresentingComposer = true
                } label: {
                    Label("Send via Messages", systemImage: "message.fill")
                }
                .disabled(!MessageComposeView.canSendText)
            } footer: {
                if MessageComposeView.canSendText {
                    Text("Review the pre-filled message in the Messages sheet and tap send to deliver it.")
                } else {
                    Text("This device is not able to send messages.")
                }
            }.listRowBackground(Color.chart)
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle("Text Caregiver")
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear {
            guard let manager = resolver.resolve(CaregiverMessagingManager.self) else { return }
            message = manager.statusMessage()
            recipients = manager.recipients
        }
        .sheet(isPresented: $isPresentingComposer) {
            MessageComposeView(recipients: recipients, messageBody: message) {
                dismiss()
            }
            .ignoresSafeArea()
        }
    }
}
