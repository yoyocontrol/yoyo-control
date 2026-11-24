import Foundation

/// A terminal on the computer (docs/PROTOCOL.md「终端」): its output and its end come as `events`; what is typed goes
/// out with `send`. The terminal itself lives on the computer: closing this (or losing the connection) only detaches,
/// and `YoyoBackend.openTerminal(session:since:…)` attaches again.
public protocol YoyoTerminalChannel: AnyObject, Sendable {
    /// What the computer says, in order: `.attached` first, then output, then the end (`.exited`, `.detached`) or
    /// `.lost` (the connection went; attach again). Finishes after the last.
    var events: AsyncStream<YoyoTerminalEvent> { get }
    /// Bytes typed (as the terminal would send them: UTF-8, control codes, escape sequences).
    func send(_ bytes: Data)
    /// The phone's terminal size changed.
    func resize(cols: Int, rows: Int)
    /// Detaches (the terminal goes on on the computer).
    func close()
}

public enum YoyoTerminalEvent: Sendable, Equatable {
    /// Attached to terminal `session`: the output that follows starts at byte `offset` of all it wrote. `reset`: the
    /// phone's copy can't be continued (a new copy of a terminal that had output): clear the screen first.
    case attached(session: String, offset: UInt64, reset: Bool)
    case output(Data)
    /// Its shell exited (`code`: its status, or 128 + the signal).
    case exited(code: Int)
    /// It goes on, not here: `replaced` (another phone or page took it), `killed` (ended), `off` (terminals were
    /// turned off on the computer).
    case detached(reason: String)
    /// The connection to the computer went: attach again from the last byte seen.
    case lost
}

/// A terminal open on the computer (`GET /term/sessions`).
public struct YoyoTerminalInfo: Sendable, Identifiable, Equatable {
    public var id: String
    public var createdAt: Date
    /// The program in its foreground now (`zsh`, `vim`, `claude`), when known.
    public var command: String?
    /// A phone (or page) is attached to it now.
    public var attached: Bool
    /// The device that opened it.
    public var deviceName: String?

    public init(id: String, createdAt: Date, command: String?, attached: Bool, deviceName: String?) {
        self.id = id
        self.createdAt = createdAt
        self.command = command
        self.attached = attached
        self.deviceName = deviceName
    }

    /// From a `GET /term/sessions` entry.
    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        createdAt = Date(timeIntervalSince1970: (json["createdAt"] as? Double ?? 0) / 1000)
        command = json["command"] as? String
        attached = json["attached"] as? Bool ?? false
        deviceName = (json["device"] as? [String: Any])?["name"] as? String
    }
}

/// Why a terminal can't open.
public enum YoyoTerminalError: Error, Equatable, Sendable {
    /// Terminals are turned off on the computer (on a Mac: Allow Terminals in Yoyo Control's menu).
    case off
    /// That terminal is gone (its shell exited).
    case gone
    /// The computer has as many open as it takes.
    case tooMany
}
