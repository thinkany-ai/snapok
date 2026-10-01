// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Snapok",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Snapok", targets: ["Snapok"])
    ],
    targets: [
        .executableTarget(
            name: "Snapok",
            resources: [.copy("Resources/Logo.png"), .copy("Resources/AppIcon.png")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
