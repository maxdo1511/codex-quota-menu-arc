// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuotaMenu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexQuotaMenu", targets: ["CodexQuotaMenu"])
    ],
    targets: [
        .executableTarget(name: "CodexQuotaMenu")
    ]
)
