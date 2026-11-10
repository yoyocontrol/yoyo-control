// swift-tools-version: 6.0
// The iOS kits (ios/YoyoKit, ios/README.md「YoyoKit」): Yoyo Control's iPhone app is built from them, and any other app
// can embed the Screen page over its own transport (a `YoyoBackend`). And, for macOS, the Mac's screen service as a
// library (`YoyoServer`, mac/README.md「Embedding the service」): another app builds its own service executable from it.
// At the repository root because SwiftPM resolves a remote package here. mac/ stays a package of its own (the menu bar
// app with Sparkle, its tests); relay/ is not Swift.
import Foundation
import PackageDescription

// uu Link (docs/LINK.md): the Rust core as YoyoLinkFFI.xcframework + the Swift target `YoyoLink`. The xcframework is
// a build output: `scripts/link-apple.sh build` puts it in link/target/apple/ (gitignored), and while it is there this
// package uses it and has the `YoyoLink` product. Otherwise the published build: the zipped xcframework of the public
// repository's release `link-apple-vX.Y.Z` (`linkRelease`, `scripts/link-apple.sh release`); with neither (nil), the
// package simply has no `YoyoLink`.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let linkLocal = FileManager.default.fileExists(atPath: packageDir + "/link/target/apple/YoyoLinkFFI.xcframework/Info.plist")
let linkRelease: (url: String, checksum: String)? = (
    url: "https://github.com/yoyocontrol/yoyo-control/releases/download/link-apple-v0.3.0/YoyoLinkFFI-0.3.0.xcframework.zip",
    checksum: "94456e5c1ffca2e5cc770da786956a8b871a4983196cc2096346b1b3f3cc9b3d")
// Yoyo Control Pro (StoreKit) is the product's, not the open-source kits': the public tree (scripts/public) has no
// ios/YoyoKit/Sources/YoyoPro, and then this package has no `YoyoPro`.
let hasPro = FileManager.default.fileExists(atPath: packageDir + "/ios/YoyoKit/Sources/YoyoPro")
let linkFFI: Target.Dependency? = linkLocal || linkRelease != nil ? "YoyoLinkFFI" : nil
/// With the link: YoyoDirect and the tests use the phone's side of it (`YoyoLinkClient`; their code checks
/// `canImport(YoyoLinkClient)`).
let linkClient: [Target.Dependency] = linkFFI == nil ? [] : ["YoyoLinkClient"]

// (split up: one big expression is too much for the type checker)
let baseProducts: [Product] = [
        /// The contract: the wire models, `YoyoBackend` (what the page asks of a computer), `YoyoHost` (what the app
        /// around it decides), events, errors.
        .library(name: "YoyoCore", targets: ["YoyoCore"]),
        /// The Screen page: decode, smooth playback, sound, gestures, keyboard, the preview row.
        .library(name: "YoyoScreen", targets: ["YoyoScreen"]),
        /// The clipboard: the shared clipboard state, its moves, the Clipboard page (the Screen page's keys use it).
        .library(name: "YoyoClipboard", targets: ["YoyoClipboard"]),
        /// Reaching a computer over more than one way: candidates raced happy-eyeballs style, the best one used, moved
        /// with the network (a `YoyoRouting` for any backend's own candidates and transport).
        .library(name: "YoyoConnect", targets: ["YoyoConnect"]),
        /// Pairing with a Yoyo Control Mac and reaching it over uu Link: one `YoyoBackend`.
        .library(name: "YoyoDirect", targets: ["YoyoDirect"]),
        /// macOS: the screen service (capture, input, sound, clipboard, the HTTP-over-unix-socket server) and
        /// `ServiceHost`, the process around it. With `YoyoLink` in the package, also the link listener
        /// (docs/LINK.md); no other dependencies (Sparkle is the menu bar app's, in mac/).
        .library(name: "YoyoServer", targets: ["YoyoServer"]),
    ]
let proProducts: [Product] = (hasPro ? [
        /// Yoyo Control Pro (StoreKit; the product's, absent from the public tree).
        .library(name: "YoyoPro", targets: ["YoyoPro"]),
    ] : [])
let linkProducts: [Product] = (linkFFI == nil ? [] : [
        /// uu Link: the UDP / QUIC phone ↔ computer transport (endpoint, sessions, control, RPC, datagram channels).
        .library(name: "YoyoLink", targets: ["YoyoLink"]),
        /// The phone's side of uu Link for the kits: one endpoint per app, dialing a computer's binding, the session as a
        /// `YoyoScreenLink` and an RPC transport (a link candidate of YoyoConnect for any backend).
        .library(name: "YoyoLinkClient", targets: ["YoyoLinkClient"]),
    ])
let baseTargets: [Target] = [
        .target(name: "YoyoCore", path: "ios/YoyoKit/Sources/YoyoCore", resources: [.process("Resources")]),
        .target(name: "YoyoClipboard", dependencies: ["YoyoCore"], path: "ios/YoyoKit/Sources/YoyoClipboard",
                resources: [.process("Resources")]),
        .target(name: "YoyoScreen", dependencies: ["YoyoCore", "YoyoClipboard"], path: "ios/YoyoKit/Sources/YoyoScreen",
                resources: [.process("Resources")]),
        .target(name: "YoyoConnect", dependencies: ["YoyoCore"], path: "ios/YoyoKit/Sources/YoyoConnect"),
        .target(name: "YoyoDirect", dependencies: ["YoyoCore", "YoyoConnect", "YoyoScreen"] + linkClient,
                path: "ios/YoyoKit/Sources/YoyoDirect", resources: [.process("Resources")]),
        // Swift 5 mode like mac/Package.swift (tools 5.10), where it is built and tested. Every file is inside
        // `#if os(macOS)`: an iOS build of the whole package (the kit's scheme, its tests) finds an empty module.
        // mac/Package.swift builds it from here too (the menu bar app, the tests): one definition of the target.
        // The link listener's files are inside `#if canImport(YoyoLink)`: without the link it is the service as before.
        .target(name: "YoyoServer", dependencies: linkFFI == nil ? [] : ["YoyoLink"], path: "mac/Sources/YoyoServer",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "YoyoKitTests",
            dependencies: ["YoyoCore", "YoyoClipboard", "YoyoConnect", "YoyoScreen", "YoyoDirect"]
                + (hasPro ? ["YoyoPro"] : []) + linkClient + (linkFFI == nil ? [] : ["YoyoLink"]),
            path: "ios/YoyoKit/Tests/YoyoKitTests"  // ProAccessTests.swift: not in the public tree either
        ),
    ]
let proTargets: [Target] = (hasPro ? [
        .target(name: "YoyoPro", dependencies: ["YoyoCore"], path: "ios/YoyoKit/Sources/YoyoPro",
                resources: [.process("Resources")]),
    ] : [])
let linkTargets: [Target] = (linkFFI.map { ffi in
        (linkLocal ? [.binaryTarget(name: "YoyoLinkFFI", path: "link/target/apple/YoyoLinkFFI.xcframework")]
            : linkRelease.map { [.binaryTarget(name: "YoyoLinkFFI", url: $0.url, checksum: $0.checksum)] } ?? []) + [
            .target(
                name: "YoyoLink",
                dependencies: [ffi],
                path: "ios/YoyoKit/Sources/YoyoLink",
                linkerSettings: [
                    // what the Rust static library needs (rustc --print native-static-libs)
                    .linkedFramework("Network"), .linkedFramework("SystemConfiguration"),
                    .linkedFramework("Security"), .linkedFramework("CoreFoundation"),
                    .linkedLibrary("iconv"), .linkedLibrary("objc"),
                ]
            ),
            .target(name: "YoyoLinkClient", dependencies: ["YoyoLink", "YoyoCore", "YoyoConnect"],
                    path: "ios/YoyoKit/Sources/YoyoLinkClient"),
        ]
    } ?? [])

let package = Package(
    name: "YoyoKit",
    defaultLocalization: "en",
    platforms: [.iOS("26.0"), .macOS(.v14)],  // `.v26` needs tools 6.2; macOS: YoyoServer only (the kits are iOS'),
    products: baseProducts + proProducts + linkProducts,
    dependencies: [],
    targets: baseTargets + proTargets + linkTargets
)
