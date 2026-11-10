#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Whether the focused element of this session takes typing (`GET /focus`): the phone asks after its clicks, and brings
/// up its keyboard when a text field, text area, editable web content or a terminal has the focus. Through the
/// Accessibility API (the permission input needs too): the focused app's focused element. The system-wide element
/// can't answer in a session switched away with Fast User Switching (-25204), so the focused app is then the owner of
/// the frontmost normal window (asked afresh each time: NSWorkspace's idea of it goes stale in a helper). Electron apps
/// and Chromium browsers build their accessibility tree only when asked, once per process: Electron by
/// `AXManualAccessibility` (other apps refuse it), the browsers (Chrome, Edge, Brave, Arc…: by bundle id) by
/// `AXEnhancedUserInterface` (set on no other app: it upsets their window animations). Building the tree takes a few
/// seconds, so the first clicks in a browser after it started (or the helper did) may come back "not editable".
public enum FocusProbe {
    public struct Answer: Equatable, Sendable {
        public var editable: Bool
        /// The focused element's role (`AXTextField`…), nil when there is none or it can't be read.
        public var role: String?

        public var json: [String: Any] { ["editable": editable, "role": role ?? NSNull()] }
    }

    /// Apps already asked to build their accessibility tree.
    nonisolated(unsafe) private static var enabled: Set<pid_t> = []
    private static let lock = NSLock()

    /// A hung app must not hold the phone's request.
    static let messagingTimeout: Float = 0.3

    public static func current() -> Answer {
        guard AXIsProcessTrusted() else { return Answer(editable: false, role: nil) }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let app = element(system, kAXFocusedApplicationAttribute) ?? frontmostWindowOwner().map(AXUIElementCreateApplication) else {
            return Answer(editable: false, role: nil)
        }
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        enableAccessibility(app)
        guard let focused = element(app, kAXFocusedUIElementAttribute) ?? element(system, kAXFocusedUIElementAttribute) else {
            return Answer(editable: false, role: nil)
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)
        let role: String? = copy(focused, kAXRoleAttribute)
        let subrole: String? = copy(focused, kAXSubroleAttribute)
        let enabled: Bool? = copy(focused, kAXEnabledAttribute)
        var settable: DarwinBoolean = false
        let valueSettable = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        let hasSelection = raw(focused, kAXSelectedTextRangeAttribute).map { CFGetTypeID($0) == AXValueGetTypeID() } ?? false
        return Answer(editable: isEditable(role: role, subrole: subrole, enabled: enabled, valueSettable: valueSettable,
                                           hasSelectedRange: hasSelection),
                      role: role)
    }

    /// The pid of the app taking keyboard input (the same choice as `current()`: the system-wide focused app, else
    /// the owner of the frontmost normal window); nil without Accessibility.
    static func focusedPID() -> pid_t? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        if let app = element(system, kAXFocusedApplicationAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(app, &pid) == .success, pid > 0 { return pid }
        }
        return frontmostWindowOwner()
    }

    /// Text roles take typing (unless disabled); anything else does when its value can be set and it has a text
    /// selection (a caret), like an editable web element exposed under another role.
    public static func isEditable(role: String?, subrole: String?, enabled: Bool?, valueSettable: Bool, hasSelectedRange: Bool) -> Bool {
        if enabled == false { return false }
        if let role, textRoles.contains(role) { return true }
        if let subrole, subrole == "AXSearchField" || subrole == (kAXSecureTextFieldSubrole as String) { return true }
        return valueSettable && hasSelectedRange
    }

    static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]

    /// The app owning the frontmost normal (layer 0) window on screen, not this process.
    private static func frontmostWindowOwner() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let me = getpid()
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me else { continue }
            return pid
        }
        return nil
    }

    /// Electron and the Chromium browsers build their tree for the focused app once asked.
    static func enableAccessibility(_ app: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == .success else { return }
        lock.lock()
        let fresh = enabled.insert(pid).inserted
        lock.unlock()
        guard fresh else { return }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, isChromiumBrowser(id) {
            AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Browsers built on Chromium, which ignore `AXManualAccessibility` (Electron's) and build their tree for
    /// `AXEnhancedUserInterface`.
    public static func isChromiumBrowser(_ bundleID: String) -> Bool {
        chromiumBrowsers.contains(bundleID) || chromiumBrowsers.contains { bundleID.hasPrefix($0 + ".") }
    }

    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
    ]

    private static func raw(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        raw(element, attribute) as? T
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = raw(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
#endif
