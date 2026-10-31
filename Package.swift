// swift-tools-version: 6.0
import PackageDescription
import Foundation

let occtRoot = ProcessInfo.processInfo.environment["LAB_OCCT_ROOT"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".local/engines/occt-8.0.1-form-gprop2").path
let occtLibraries = ["TKernel","TKMath","TKG2d","TKG3d","TKGeomBase","TKBRep","TKGeomAlgo","TKTopAlgo","TKPrim","TKBO","TKBool","TKFillet","TKOffset","TKMesh","TKShHealing","TKXSBase","TKDESTEP","TKLCAF","TKCAF","TKXCAF","TKCDF"]


let package = Package(
  name: "FORM",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "Form", targets: ["FormApp"]),
    .executable(name: "form-mcp", targets: ["FormMCP"]),
    .library(name: "FormCore", targets: ["FormCore"]),
    .library(name: "FormGraphics", targets: ["FormGraphics"]),
    .library(name: "FormGeometry", targets: ["FormGeometry"]),
    .library(name: "LabRendering", targets: ["LabRendering"]),
    .library(name: "FormMeshAssets", targets: ["FormMeshAssets"]),
    .library(name: "FormCADModeling", targets: ["FormCADModeling"]),
  ],
  targets: [
    .target(name: "CFormFigmaCompression", exclude: ["LICENSE", "UPSTREAM.json"], publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
    .target(name: "CFormClipper", exclude: ["LICENSE", "UPSTREAM.json"], publicHeadersPath: "include", cxxSettings: [.headerSearchPath("vendor")]),
    .target(name:"CFormMesher",exclude:["LICENSE","UPSTREAM.json"],publicHeadersPath:"include",cxxSettings:[.headerSearchPath("vendor")]),
    .target(name: "FormGeometry", dependencies: ["CFormMesher"]),
    .target(name: "LabRendering"),
    .target(name: "FormMeshAssets"),
    .target(name: "CFormCADKernel", exclude: ["LICENSE_LGPL_21.txt", "OCCT_LGPL_EXCEPTION.txt", "UPSTREAM.json"], publicHeadersPath: "include", cxxSettings: [.unsafeFlags(["-I" + occtRoot + "/include/opencascade"])], linkerSettings: occtLibraries.map { .linkedLibrary($0) } + [.unsafeFlags(["-L" + occtRoot + "/lib", "-Xlinker", "-rpath", "-Xlinker", occtRoot + "/lib", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .target(name: "FormCADKernel", dependencies: ["CFormCADKernel"]),
    .target(name: "FormCADModel"),
    .target(name: "FormCADModeling", dependencies: ["FormCADModel", "FormCADKernel"]),
    .target(name: "FormCore", dependencies: ["CFormClipper","CFormMesher","CFormFigmaCompression","FormMeshAssets","FormCADModel"], resources: [.process("Resources")]),
    .target(name: "FormGraphics", dependencies: ["FormCore", "FormGeometry"]),
    .executableTarget(name: "FormApp", dependencies: ["FormCore", "FormGraphics", "FormGeometry", "LabRendering", "FormMeshAssets", "FormCADModeling"]),
    .executableTarget(name: "FormMCP", dependencies: ["FormCore"]),
    .target(name: "FigmaTestSupport", path: "Tests/FigmaTestSupport"),
    .testTarget(name: "FormGeometryTests", dependencies: ["FormGeometry"]),
    .testTarget(name: "LabRenderingTests", dependencies: ["LabRendering"]),
    .testTarget(name: "FormMeshAssetsTests", dependencies: ["FormMeshAssets"]),
    .testTarget(name: "FormCADKernelTests", dependencies: ["FormCADKernel"], exclude:["Fixtures"]),
    .testTarget(name: "FormCADModelingTests", dependencies: ["FormCADModeling"]),
    .testTarget(name: "FormCoreTests", dependencies: ["FormCore", "FormGraphics", "FormGeometry", "LabRendering", "FigmaTestSupport"]),
    .testTarget(name: "FormAppTests", dependencies: ["FormApp", "FormCore", "FormGeometry", "LabRendering", "FigmaTestSupport"]),
  ],
  swiftLanguageModes: [.v5],
  cxxLanguageStandard: .cxx17
)
