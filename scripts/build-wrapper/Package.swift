// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PikoBuild",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Piko",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/Piko",
            exclude: [
                "Info.plist",
                "reminders_menubar.entitlements",
                "reminders_menubar_appstore.entitlements",
                "Preview Content",
                "Resources/AppIcon.icns",
                "Resources/Assets.xcassets",
                "Resources/Colors.xcassets",
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings"
            ]
        )
    ]
)
