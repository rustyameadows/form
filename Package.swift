// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FORM",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Form", targets: ["FormApp"]),
    .executable(name: "form-mcp", targets: ["FormMCP"]),
    .library(name: "FormCore", targets: ["FormCore"]),
  ],
  targets: [
    .target(name: "FormCore"),
    .executableTarget(name: "FormApp", dependencies: ["FormCore"]),
    .executableTarget(name: "FormMCP", dependencies: ["FormCore"]),
    .testTarget(name: "FormCoreTests", dependencies: ["FormCore"]),
  ],
  swiftLanguageModes: [.v5]
)
