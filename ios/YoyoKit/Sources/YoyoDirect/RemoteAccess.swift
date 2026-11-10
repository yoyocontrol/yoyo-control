import Foundation
import YoyoCore

/// Where Yoyo Control Pro's line runs: reaching the Mac over a local-network path of the link (its peer address
/// private, link-local or ULA: `YoyoLinkConnection.isLocalNetwork`) is free; any other path (the relay, a public or
/// punched address, Tailscale's 100.64/10) needs Pro.
public enum RemoteAccess {
    public static func allows(onLocalNetwork: Bool, pro: Bool) -> Bool {
        pro || onLocalNetwork
    }
}
