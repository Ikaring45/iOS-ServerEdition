// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerPad",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ServerPad", targets: ["ServerPad"])],
    targets: [
        .target(name: "ServerPad"),
        .testTarget(name: "ServerPadTests", dependencies: ["ServerPad"])
    ]
)

