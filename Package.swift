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
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "9.30.0")
    ],
    targets: [
        .executableTarget(
            name: "Snapok",
            dependencies: [.product(name: "Sentry", package: "sentry-cocoa")],
            resources: [.copy("Resources/Logo.png"), .copy("Resources/AppIcon.png")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
