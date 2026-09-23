// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ControlBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ControlBar",
            path: "Sources/ControlBar",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
