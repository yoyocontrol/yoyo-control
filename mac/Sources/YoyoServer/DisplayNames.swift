#if os(macOS)
import AppKit
import CoreGraphics
import Foundation

/// Display names as macOS shows them (`NSScreen.localizedName`: "Built-in Retina Display", "LG UltraFine", …), by
/// display id, for `/status`. AppKit is main-thread API, so this follows SystemPointer's cursor (DisplayPointer.swift):
/// the names are read on the main queue into a cache; a caller off the main thread asks for a refresh and waits up to
/// 100 ms only for an id it has not seen yet, else it takes the cache while the refresh runs behind it. No I/O: cheap
/// enough for the phone's 10 s `/status` poll and every stream's display lookup.
enum DisplayNames {
    private static let lock = NSLock()
    // Guarded by `lock`:
    nonisolated(unsafe) private static var names: [CGDirectDisplayID: String] = [:]
    nonisolated(unsafe) private static var refreshing = false

    /// The display's name, nil when macOS has none (or a meaningless one, see `clean`).
    static func name(_ id: CGDirectDisplayID) -> String? {
        if Thread.isMainThread {
            refresh()
        } else {
            lock.lock()
            let known = names[id] != nil
            let start = !refreshing
            if start { refreshing = true }
            lock.unlock()
            if start {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    refresh()
                    lock.lock(); refreshing = false; lock.unlock()
                    done.signal()
                }
                if !known { _ = done.wait(timeout: .now() + 0.1) }
            }
        }
        lock.lock(); defer { lock.unlock() }
        return names[id].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Main thread: every NSScreen's name by its `NSScreenNumber`.
    private static func refresh() {
        var fresh: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            fresh[number.uint32Value] = clean(screen.localizedName) ?? ""
        }
        lock.lock(); names = fresh; lock.unlock()
    }

    /// Trimmed; nil when empty or only a parenthesised suffix such as " (AirPlay)" (an empty product name plus the
    /// transport), which says nothing about the display.
    static func clean(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix("(") && name.hasSuffix(")") { return nil }
        return name
    }
}
#endif
