// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoSwitcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AutoSwitcher", targets: ["AutoSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "AutoSwitcher",
            path: "Sources/AutoSwitcher",
            exclude: [
                // Info.plist and icon assets are pulled into the .app bundle
                // by build.sh; SPM shouldn't bake them in as module resources.
                "Resources/Info.plist",
                "Resources/AppIcon.iconset"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
