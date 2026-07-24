// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ZScribeMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZScribeCore", targets: ["ZScribeCore"]),
        .executable(name: "ZScribeMac", targets: ["ZScribeMac"]),
        .executable(name: "ZScribeCoreChecks", targets: ["ZScribeCoreChecks"])
    ],
    targets: [
        .target(
            name: "ZScribeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ZScribeMac",
            dependencies: ["ZScribeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ZScribeCoreChecks",
            dependencies: ["ZScribeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
