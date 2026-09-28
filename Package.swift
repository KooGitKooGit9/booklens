// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BookLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BookLens", targets: ["BookLens"]),
        .executable(name: "booklens-bench", targets: ["BookLensBench"]),
        .library(name: "BookLensCore", targets: ["BookLensCore"]),
    ],
    targets: [
        .target(
            name: "BookLensCore",
            linkerSettings: [
                .linkedFramework("Vision"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .executableTarget(
            name: "BookLens",
            dependencies: ["BookLensCore"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "BookLensBench",
            dependencies: ["BookLensCore"],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .testTarget(
            name: "BookLensCoreTests",
            dependencies: ["BookLensCore"]
        ),
    ]
)
