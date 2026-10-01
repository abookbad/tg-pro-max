// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TGProMax", platforms: [.macOS(.v14)],
    products: [.executable(name: "TGProMax", targets: ["TGProMax"]), .executable(name: "SensorProbe", targets: ["SensorProbe"])],
    targets: [
        .target(name: "CSMC", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "CProc"),
        .target(name: "ThermalCore", dependencies: ["CSMC", "CProc"]),
        .executableTarget(name: "TGProMax", dependencies: ["ThermalCore"]),
        .executableTarget(name: "SensorProbe", dependencies: ["ThermalCore"]),
        .testTarget(name: "ThermalCoreTests", dependencies: ["ThermalCore", "CSMC"])
    ], swiftLanguageModes: [.v5]
)
