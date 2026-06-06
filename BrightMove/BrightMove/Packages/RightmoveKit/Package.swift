// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RightmoveKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RightmoveKit", targets: ["RightmoveKit"]),
        .library(name: "PropertyStore", targets: ["PropertyStore"]),
        .executable(name: "rmparse", targets: ["rmparse"]),
        .executable(name: "netcheck", targets: ["netcheck"]),
    ],
    targets: [
        .target(name: "RightmoveKit"),
        .target(name: "PropertyStore", dependencies: ["RightmoveKit"]),
        .executableTarget(name: "rmparse", dependencies: ["RightmoveKit"]),
        .executableTarget(name: "netcheck", dependencies: ["RightmoveKit"]),
        .testTarget(
            name: "RightmoveKitTests",
            dependencies: ["RightmoveKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "PropertyStoreTests",
            dependencies: ["PropertyStore"]
        ),
    ]
)
