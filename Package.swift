// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "WifiAnalyzer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wifi-analyzer", targets: ["wifi-analyzer"]),
        .executable(name: "wifi-analyzer-menu", targets: ["WifiAnalyzerMenu"])
    ],
    targets: [
        .target(name: "WifiAnalyzerCore", resources: [.copy("Resources/report.html")]),
        .executableTarget(name: "wifi-analyzer", dependencies: ["WifiAnalyzerCore"]),
        .executableTarget(name: "WifiAnalyzerMenu", dependencies: ["WifiAnalyzerCore"], linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "WifiAnalyzerCoreTests", dependencies: ["WifiAnalyzerCore"]),
        .testTarget(name: "WifiAnalyzerMenuTests", dependencies: ["WifiAnalyzerMenu"])
    ]
)
