import Foundation
import Synchronization
import UIKit

/// What the app around the kits decides: their colours, what happens to an error, the language, how the Screen page is
/// presented, where settings are kept, this phone's id. One per app: set `YoyoHost.current` once at launch (or pass it to
/// `YoyoScreen.makePage(backend:host:)`, which sets it). Any thread may read it.
public struct YoyoHost: Sendable {
    /// The pages' colours.
    public var theme = YoyoTheme()
    /// Every error of the kits' requests goes here first (a 401: the credential no longer works). true = handled: the
    /// page says nothing more. Default: not handled (the page shows the error's text).
    public var handleError: @MainActor @Sendable (Error) -> Bool = { _ in false }
    /// Shows a short notice over `page` instead of the kits' own glass toast. nil: the kits' toast.
    public var toast: (@MainActor @Sendable (_ text: String, _ page: UIViewController) -> Void)?
    /// The language of the kits' strings: one of their localizations ("en", "zh-Hans"). nil: the system's choice for the
    /// app (an app with its own language switch passes its current language).
    public var language: String?
    /// The locale of dates, numbers and sizes in the kits' strings. nil: `Locale.current`.
    public var locale: Locale?
    /// How the Screen page's navigation controller is presented.
    public var presentation = YoyoPresentation.fullScreen
    /// The prefix of every defaults key and launch argument the kits read or write: `<namespace>Audio` (the speaker
    /// button), `<namespace>GestureCard2Shown`, `<namespace>DeviceId`, `-<namespace>Loupe YES`… Default "Yoyo".
    public var preferencesNamespace = "Yoyo"
    /// This phone's id as the computer knows it (≤ 128 characters): what tells this phone from the others in
    /// `controllerDevice`. nil: a random id made on first use and kept in `<namespace>DeviceId`.
    public var deviceId: String?
    /// What to call automation that drives the computer or puts things on its clipboard ("Copied by <name>"); nil: the
    /// generic words ("an agent").
    public var agentName: String?
    /// Where the kits' diagnostic lines go too (besides the system log, subsystem `ca.sarria.yoyocontrol`): the host's own
    /// debug log. `category` says whose (`screen-stop`: how long a Screen session's stop took on the main thread, step by
    /// step). Called on any thread; nil: the system log only.
    public var log: (@Sendable (_ category: String, _ line: String) -> Void)?

    public init() {}

    private static let state = Mutex(YoyoHost())

    /// The host in use.
    public static var current: YoyoHost {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// `<namespace><name>`: a defaults key / launch argument of the kits.
    package static func key(_ name: String) -> String { current.preferencesNamespace + name }
}

/// How the Screen page shows.
public enum YoyoPresentation: Sendable {
    /// Full screen over the app (`modalPresentationStyle = .fullScreen`).
    case fullScreen
    /// The host sets the navigation controller up itself (a custom transition, a sheet…) before presenting it.
    case custom(@MainActor @Sendable (UINavigationController) -> Void)
}

/// A page's first view controller that keeps some touches from a container's swipe back: the container neither hands
/// it those touches nor begins its swipe when this says no. The Screen page keeps the trackpad's and the picture's
/// touches (a host presenting it with a swipe-to-close transition asks it).
@MainActor
public protocol YoyoPageSwipeGate: AnyObject {
    func pageSwipeShouldReceive(_ touch: UITouch) -> Bool
    func pageSwipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool
}
