// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ServerPad",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ServerPad", targets: ["ServerPad"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0")
    ],
    targets: [
        .target(
            name: "ServerPad",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .testTarget(name: "ServerPadTests", dependencies: ["ServerPad"])
    ]
)

