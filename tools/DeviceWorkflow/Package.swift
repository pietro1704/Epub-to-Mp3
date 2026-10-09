// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "DeviceWorkflow",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "DeviceWorkflow", targets: ["DeviceWorkflow"]),
        .executable(name: "device-workflow", targets: ["DeviceWorkflowCLI"]),
    ],
    targets: [
        .target(name: "DeviceWorkflow"),
        .executableTarget(name: "DeviceWorkflowCLI", dependencies: ["DeviceWorkflow"]),
        .testTarget(name: "DeviceWorkflowTests", dependencies: ["DeviceWorkflow"]),
    ]
)
