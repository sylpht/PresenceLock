import AppKit
import CoreGraphics

/// Power, display sleep and fast user switching have independent wake notifications.
/// A wake clears only its own reason for suspension.
struct WorkspaceSessionState {
    private var computerSleeping = false
    private var displaysSleeping = false
    private var sessionSwitchedOut = false

    mutating func receive(_ notification: Notification.Name) {
        switch notification {
        case NSWorkspace.willSleepNotification: computerSleeping = true
        case NSWorkspace.didWakeNotification: computerSleeping = false
        case NSWorkspace.screensDidSleepNotification: displaysSleeping = true
        case NSWorkspace.screensDidWakeNotification: displaysSleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionSwitchedOut = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionSwitchedOut = false
        default: break
        }
    }

    func canMonitor(consoleIsUsable: Bool) -> Bool {
        consoleIsUsable && !computerSleeping && !displaysSleeping && !sessionSwitchedOut
    }

    static var consoleIsUsable: Bool {
        var displays: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displays) == .success, displays > 0,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return sessionAllowsMonitoring(session)
    }

    static func sessionAllowsMonitoring(_ session: [String: Any]) -> Bool {
        guard session[kCGSessionOnConsoleKey] as? Bool == true,
              session[kCGSessionLoginDoneKey] as? Bool == true else { return false }
        // WindowServer normally omits this additional property when unlocked.
        guard let locked = session["CGSSessionScreenIsLocked"] else { return true }
        return locked as? Bool == false
    }

}
