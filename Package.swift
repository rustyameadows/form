// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FORM",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Form", targets: ["FormApp"]),
    .executable(name: "form-mcp", targets: ["FormMCP"]),
    .library(name: "FormCore", targets: ["FormCore"]),
    .library(name: "FormGraphics", targets: ["FormGraphics"]),
  ],
  targets: [
    .target(name: "FormCore"),
    .target(name: "FormGraphics", dependencies: ["FormCore"]),
    .executableTarget(name: "FormApp", dependencies: ["FormCore", "FormGraphics"]),
    .executableTarget(name: "FormMCP", dependencies: ["FormCore"]),
    .testTarget(name: "FormCoreTests", dependencies: ["FormCore", "FormGraphics"]),
    .testTarget(name: "FormAppTests", dependencies: ["FormApp", "FormCore"]),
  ],
  swiftLanguageModes: [.v5]
)
