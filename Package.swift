// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VSBMNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VSBMNative", targets: ["VSBMNative"]),
        .executable(name: "vsbm-selfcheck", targets: ["VSBMNativeSelfCheck"]),
        .library(name: "VSBMNativeCore", targets: ["VSBMNativeCore"]),
    ],
    targets: [
        .target(
            name: "VSBMNativeCore",
            path: "Sources/VSBMNativeCore"
        ),
        .executableTarget(
            name: "VSBMNative",
            dependencies: ["VSBMNativeCore"],
            path: "Sources/VSBMNative"
        ),
        .executableTarget(
            name: "VSBMNativeSelfCheck",
            dependencies: ["VSBMNativeCore"],
            path: "Sources/VSBMNativeSelfCheck"
        ),
    ]
)
