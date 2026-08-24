// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoWiFiWire",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AutoWiFiWire", targets: ["AutoWiFiWire"]),
    ],
    targets: [
        .target(name: "AutoWiFiWire"),
        .testTarget(name: "AutoWiFiWireTests", dependencies: ["AutoWiFiWire"]),
    ]
)
