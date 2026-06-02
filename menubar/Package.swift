// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CxpodMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CxpodMenuBar", targets: ["CxpodMenuBar"]),
    ],
    targets: [
        .executableTarget(
            name: "CxpodMenuBar",
            path: "Sources/CxpodMenuBar"
        ),
    ]
)
