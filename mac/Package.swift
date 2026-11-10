// swift-tools-version: 5.10
import Foundation
import PackageDescription

// YoyoServer: capture (ScreenCaptureKit), input (CGEvent) and the HTTP-over-unix-socket server, as a library. Its
// target is the repository-root package's (`..`, the product embedders use): defined once, with the link listener
// (`YoyoLink`: the published build, or a local one, docs/LINK.md「构建」).
// yoyo-server: the service on its own (`ServiceHost`: `yoyo-server --socket <path> [--remote <home>] …`), no app
// around it — what a self-hosted setup or another app's helper runs. Open source, like the library.
//
// The product (Yoyo Control.app; not in the public tree, scripts/public): YoyoApp, the menu bar app around the
// service (the fixed socket, one instance, the service process it supervises), and yoyo-control, its executable (the
// menu bar app without arguments, the service with `--socket`), with Sparkle for its updates (build.sh embeds
// Sparkle.framework; release.sh publishes the appcast). Present only when Sources/YoyoApp is.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasApp = FileManager.default.fileExists(atPath: packageDir + "/Sources/YoyoApp")
let yoyoServer: Target.Dependency = .product(name: "YoyoServer", package: "YoyoKit")
let package = Package(
    name: "yoyo-control",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "yoyo-server", targets: ["yoyo-server"]),
    ] + (hasApp ? [
        .executable(name: "yoyo-control", targets: ["yoyo-control"]),
        .library(name: "YoyoApp", targets: ["YoyoApp"]),
    ] : []),
    dependencies: (hasApp ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")] : []) + [
        .package(name: "YoyoKit", path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "yoyo-server",
            dependencies: [yoyoServer],
            path: "Sources/yoyo-server"
        ),
        .testTarget(
            name: "YoyoServerTests",
            // the link tests' client (the root package has `YoyoLink`: its local build or the published one)
            dependencies: [yoyoServer, .product(name: "YoyoLink", package: "YoyoKit")],
            path: "Tests/YoyoServerTests"
        ),
    ] + (hasApp ? [
        .target(
            name: "YoyoApp",
            dependencies: [yoyoServer, .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/YoyoApp"
        ),
        .executableTarget(
            name: "yoyo-control",
            dependencies: [yoyoServer, "YoyoApp"],
            path: "Sources/yoyo-control"
        ),
        .testTarget(
            name: "YoyoAppTests",
            dependencies: ["YoyoApp"],
            path: "Tests/YoyoAppTests"
        ),
    ] : [])
)
