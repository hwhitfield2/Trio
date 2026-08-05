import MessageUI
import SwiftUI

/// Wraps `MFMessageComposeViewController` so a pre-filled iMessage/SMS can be presented from SwiftUI.
/// iOS requires the user to confirm sending — the message cannot be dispatched programmatically.
struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let messageBody: String
    var onFinish: (() -> Void)? = nil

    static var canSendText: Bool {
        MFMessageComposeViewController.canSendText()
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.recipients = recipients
        controller.body = messageBody
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_: MFMessageComposeViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        private let onFinish: (() -> Void)?

        init(onFinish: (() -> Void)?) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith _: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            onFinish?()
        }
    }
}
