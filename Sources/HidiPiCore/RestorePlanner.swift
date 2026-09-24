/// Pre-flight planning for a restore: the pure half of macos.restore, extracted so the
/// resolution and tie-break rules are testable without touching any display.
import Foundation

/// One planned restore step: which live display, the captured state to replay, and the
/// best available mode for it.
public struct RestoreEntry: Sendable {
    public let display: UInt32   // CGDirectDisplayID
    public let target: DisplaySnapshot
    public let mode: ModeInfo

    init(display: UInt32, target: DisplaySnapshot, mode: ModeInfo) {
        self.display = display; self.target = target; self.mode = mode
    }
}

public enum RestorePlanner {
    /// Resolves every snapshot display by UUID against the online map and picks its best
    /// mode from the injected mode list. Throws before anything is touched when a display
    /// is missing, its mode is absent, or no live mode matches.
    /// Tie-break rule from the Python version: mode_id only breaks ties (it changes
    /// across reboots), so a mode_id match sorts first.
    public static func plan(_ state: DisplayState,
                            online: [String: UInt32],
                            modes: (UInt32) -> [ModeInfo]) throws -> [RestoreEntry] {
        var entries: [RestoreEntry] = []
        for saved in state.displays {
            guard let display = online[saved.uuid] else {
                throw HiDPIError("Display \(saved.uuid) from the snapshot is not connected; reconnect it and retry.")
            }
            guard let wanted = saved.mode else {
                throw HiDPIError("The snapshot is missing the original mode; cannot fully restore.")
            }
            let matches = modes(display).filter { Modes.modeMatches($0, wanted) }
            guard let best = matches.min(by: {
                let l = $0.modeID != wanted.modeID, r = $1.modeID != wanted.modeID
                return l != r ? !l : false
            }) else {
                throw HiDPIError("The original mode for display \(display) is currently unavailable: \(Modes.describe(wanted))")
            }
            entries.append(RestoreEntry(display: display, target: saved, mode: best))
        }
        return entries
    }
}
