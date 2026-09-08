// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WAMKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WAMKit", targets: ["WAMKit"]),
        .executable(name: "WAMKitSwiftHost", targets: ["WAMKitSwiftHost"])
    ],
    targets: [
        .binaryTarget(name: "WAMKit", path: "build/WAMKit.xcframework"),
        .executableTarget(name: "WAMKitSwiftHost", dependencies: ["WAMKit"],
                          path: "examples/WAMKitSwiftHost")
    ]
)
