import Foundation
import LoopKit

/// Which insulin Trio doses against.
///
/// Trio never programs the pump's own insulin type — that lives on the pump and
/// is only ever read here. What this setting controls is the *insulin model*
/// oref doses against (`Preferences.curve`), which until now was derived
/// silently from whatever the pump reported and could change underneath the
/// user whenever the pump sent a status update.
///
/// `automatic` preserves that original behaviour. Any explicit choice pins the
/// model, so a pump that reports the wrong insulin — or reports none at all —
/// no longer decides how Trio models insulin activity.
enum InsulinTypeSelection: String, JSON, Identifiable, CaseIterable, Equatable {
    case automatic
    case apidra
    case humalog
    case novolog
    case fiasp
    case lyumjev

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return String(localized: "Automatic (from pump)", comment: "Insulin type is taken from the pump")
        case .apidra:
            return "Apidra"
        case .humalog:
            return "Humalog"
        case .novolog:
            return "NovoLog / NovoRapid"
        case .fiasp:
            return "Fiasp"
        case .lyumjev:
            return "Lyumjev"
        }
    }

    /// The oref insulin model this insulin doses against, or nil when the pump
    /// is left to decide.
    var curve: InsulinCurve? {
        switch self {
        case .automatic:
            return nil
        case .apidra,
             .humalog,
             .novolog:
            return .rapidActing
        case .fiasp,
             .lyumjev:
            return .ultraRapid
        }
    }

    /// The selection matching what the pump reports, so the UI can show what
    /// `automatic` currently resolves to. Falls back to `automatic` for an
    /// absent or unrecognised pump insulin type.
    init(pumpInsulinType: InsulinType?) {
        switch pumpInsulinType {
        case .apidra:
            self = .apidra
        case .humalog:
            self = .humalog
        case .novolog:
            self = .novolog
        case .fiasp:
            self = .fiasp
        case .lyumjev:
            self = .lyumjev
        default:
            self = .automatic
        }
    }
}
