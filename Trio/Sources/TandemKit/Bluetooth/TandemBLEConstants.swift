import CoreBluetooth
import Foundation

/// BLE service and characteristic UUIDs for the Tandem t:slim X2 and Mobi pumps.
///
/// Reference: pumpx2 `ServiceUUID` / `CharacteristicUUID`
/// (jwoglom/pumpx2, messages/.../bluetooth/).
enum TandemBLE {
    /// Tandem Diabetes Care's assigned 16-bit service id (0xFDFB).
    static let pumpServiceUUID = CBUUID(string: "FDFB")

    static let deviceInformationServiceUUID = CBUUID(string: "180A")
    static let genericAttributeServiceUUID = CBUUID(string: "1801")

    /// Read-only pump state request/response traffic.
    static let currentStatusCharacteristicUUID = CBUUID(string: "7B83FFF6-9F77-4E5C-8064-AAE2C24838B9")
    /// Unsolicited qualifying event notifications.
    static let qualifyingEventsCharacteristicUUID = CBUUID(string: "7B83FFF7-9F77-4E5C-8064-AAE2C24838B9")
    /// Streamed history log entries.
    static let historyLogCharacteristicUUID = CBUUID(string: "7B83FFF8-9F77-4E5C-8064-AAE2C24838B9")
    /// Pairing / authentication handshake traffic.
    static let authorizationCharacteristicUUID = CBUUID(string: "7B83FFF9-9F77-4E5C-8064-AAE2C24838B9")
    /// Signed control (insulin-affecting) request/response traffic.
    static let controlCharacteristicUUID = CBUUID(string: "7B83FFFC-9F77-4E5C-8064-AAE2C24838B9")
    /// Streamed responses to control requests.
    static let controlStreamCharacteristicUUID = CBUUID(string: "7B83FFFD-9F77-4E5C-8064-AAE2C24838B9")

    /// Device Information Service characteristics used to identify the pump model.
    static let manufacturerNameCharacteristicUUID = CBUUID(string: "2A29")
    static let modelNumberCharacteristicUUID = CBUUID(string: "2A24")
    static let serialNumberCharacteristicUUID = CBUUID(string: "2A25")
    static let softwareRevisionCharacteristicUUID = CBUUID(string: "2A28")

    /// Characteristics that must have notifications enabled after connecting,
    /// before any message exchange (per pumpx2 `CharacteristicUUID.ENABLED_NOTIFICATIONS`).
    static let notifiedCharacteristicUUIDs: [CBUUID] = [
        currentStatusCharacteristicUUID,
        qualifyingEventsCharacteristicUUID,
        historyLogCharacteristicUUID,
        authorizationCharacteristicUUID,
        controlCharacteristicUUID,
        controlStreamCharacteristicUUID
    ]
}
