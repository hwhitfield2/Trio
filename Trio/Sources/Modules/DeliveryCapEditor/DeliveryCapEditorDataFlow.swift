enum DeliveryCapEditor {
    enum Config {}
}

protocol DeliveryCapEditorProvider {}
extension DeliveryCapEditor {
    final class Provider: BaseProvider, DeliveryCapEditorProvider {}
}
