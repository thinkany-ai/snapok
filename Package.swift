// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SnapAny",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SnapAny", targets: ["SnapAny"])
    ],
    targets: [
        .executableTarget(
            name: "SnapAny",
            resources: [.copy("Resources/Logo.png"), .copy("Resources/AppIcon.png")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
