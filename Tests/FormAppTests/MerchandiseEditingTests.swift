import AppKit
import Metal
import FormGeometry
import XCTest

@testable import FormApp
@testable import FormCore
@testable import FormGraphics

@MainActor final class MerchandiseEditingTests: XCTestCase {
  private func project() throws -> Project {
    _ = NSApplication.shared
    return try Samples.merchandiseCollection()
  }
  private func node(_ scene: TableSceneController, _ id: UUID) throws -> MeshNode {
    try XCTUnwrap(
      scene.objectRoot.childNode(withName: "object:\(id.uuidString)", recursively: false))
  }
  private func scene(_ p: Project) -> TableSceneController {
    let scene = TableSceneController()
    scene.sync(
      p, selection: [], isolated: [], showGrid: false, studio: true, preset: "Daylight",
      assets: FileManager.default.temporaryDirectory, textureLimit: 768)
    return scene
  }
  private func vertices(_ geometry: MeshGeometry) throws -> [Vector3] {
    let s = try XCTUnwrap(geometry.sources(for: .vertex).first)
    return s.data.withUnsafeBytes { raw in
      (0..<s.vectorCount).map { i in
        func component(_ index: Int) -> Double {
          let offset = s.dataOffset + i * s.dataStride + index * s.bytesPerComponent
          return s.bytesPerComponent == 4
            ? Double(raw.loadUnaligned(fromByteOffset: offset, as: Float.self))
            : raw.loadUnaligned(fromByteOffset: offset, as: Double.self)
        }
        return .init(component(0), component(1), component(2))
      }
    }
  }
  func testActualCapArtworkVerticesFollowCrownAndDoNotUseAFloatingPlane() throws {
    var p = try project()
    let capIndex = p.objects.firstIndex { $0.recipeID == "curvedCap" }!
    p.objects[capIndex].rotation = 0
    let cap = p.objects[capIndex]
    let ink = p.objects.first { $0.name == "Cap / conforming NASA front art" }!
    let scene = scene(p)
    let root = try node(scene, ink.id)
    let mesh = try XCTUnwrap(
      root.childNode(withName: "Conforming direct artwork / physical arc-mm UV", recursively: true)?
        .geometry)
    XCTAssertGreaterThan(mesh.sources(for: .vertex).first!.vectorCount, 700)
    let placement = p.textilePlacement(ink)
    let points = try vertices(mesh)
    for v in points {
      let x = v.x * 100 + placement.position.x - cap.position.x
      let z = v.z * 100 + placement.position.z - cap.position.z
      let y = v.y * 100 + placement.position.y - cap.position.y
      XCTAssertEqual(hypot(x, z), cap["width"] / 2 + ink["height"], accuracy: 0.001)
      XCTAssertGreaterThan(y, 0)
      XCTAssertLessThan(y, cap["height"] * 0.72)
    }
    XCTAssertNil(root.childNodes.first { $0.geometry is MeshPlane })
  }
  func testHostMoveFlipAndMetadataReuseMeshesButCapDimensionsAndTrimColorsInvalidate() throws {
    var p = try project()
    var scene = scene(p)
    func sync() {
      scene.sync(
        p, selection: [], isolated: [], showGrid: false, studio: true, preset: "Daylight",
        assets: FileManager.default.temporaryDirectory, textureLimit: 768)
    }
    let capIndex = p.objects.firstIndex { $0.recipeID == "curvedCap" }!
    let teeIndex = p.objects.firstIndex { $0.recipeID == "crewTee" }!
    let printIndex = p.objects.firstIndex { $0.name == "Cap / conforming NASA front art" }!
    let printID = p.objects[printIndex].id
    let original = try node(scene, printID)
    let builds = scene.geometryBuilds
    p.objects[capIndex].position.x += 150
    p.objects[capIndex].rotation = 35
    sync()
    XCTAssertEqual(scene.geometryBuilds, builds)
    XCTAssertTrue(try node(scene, printID) === original)
    p.objects[teeIndex].textile!.laidFaceDown = true
    sync()
    XCTAssertEqual(scene.geometryBuilds, builds)
    let back = p.objects.first { $0.name == "Tee / independent back signature" }!
    let backNode = try node(scene, back.id)
    XCTAssertGreaterThan(backNode.simdWorldOrientation.act(SIMD3<Float>(0, 1, 0)).y, 0.99)
    p.objects[capIndex].parameters["width"] = 220
    sync()
    XCTAssertGreaterThan(scene.geometryBuilds, builds)
    XCTAssertFalse(try node(scene, printID) === original)
    let after = scene.geometryBuilds
    var trim = p.material("merch-rib")
    trim.color = "#BD573B"
    p.materials.append(trim)
    sync()
    XCTAssertEqual(scene.geometryBuilds, after + 1)
  }
  func testNewOpenGarmentsAndArtworkCannotBecomeSilentFDMPrintSolids() throws {
    let p = try project()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: directory), seedLibrary: false)
    store.engine.project = p
    defer {
      store.engine.project = nil
      try? FileManager.default.removeItem(at: directory)
    }
    for o in p.objects where MerchandiseBlanks.recipeIDs.contains(o.recipeID) {
      XCTAssertThrowsError(
        try PrintMeshBuilder.mesh(
          object: o, project: p, assets: FileManager.default.temporaryDirectory,
          configuration: .init()))
      if MerchandiseBlanks.garmentIDs.contains(o.recipeID) {
        let path = directory.appendingPathComponent(o.recipeID + "-must-not-be-blank.svg")
        XCTAssertThrowsError(
          try store.exportArtwork(object: o, arguments: ["format": "svg", "path": path.path]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
      }
    }
  }
  func testNativeBlankToggleAutosavesAndPhysicalSourcePDFKeepsDimensionsWithoutMutation()
    async throws
  {
    let p = try project()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = StudioStore(repository: try ProjectRepository(root: root), seedLibrary: false)
    defer {
      store.engine.project = nil
      try? FileManager.default.removeItem(at: root)
    }
    store.engine.project = p
    store.showingHome = false
    let tee = p.objects.first { $0.recipeID == "crewTee" }!
    let front = p.objects.first { $0.name == "Tee / field-division direct art" }!
    let source = p.editableArtwork(front)!
    var spec = tee.textile!
    spec.laidFaceDown = true
    store.update(tee, ["textile": try jsonObject(spec)])
    XCTAssertTrue(store.saving)
    let deadline = Date().addingTimeInterval(5)
    while store.saving && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertFalse(store.saving)
    let disk = try store.repository.load(p.id)
    XCTAssertEqual(disk.objects.first { $0.id == tee.id }!.textile?.laidFaceDown, true)
    let before = store.project!
    let path = root.appendingPathComponent("physical-region.pdf")
    _ = try store.exportArtwork(object: front, arguments: ["format": "pdf", "path": path.path])
    let pdf = try XCTUnwrap(
      CGPDFDocument(CGDataProvider(data: try Data(contentsOf: path) as CFData)!))
    let box = pdf.page(at: 1)!.getBoxRect(.mediaBox)
    XCTAssertEqual(box.width, front["width"] * 72 / 25.4, accuracy: 0.02)
    XCTAssertEqual(box.height, front["depth"] * 72 / 25.4, accuracy: 0.02)
    let svgPath = root.appendingPathComponent("physical-region.svg")
    let pngPath = root.appendingPathComponent("physical-region.png")
    _ = try store.exportArtwork(object: front, arguments: ["format": "svg", "path": svgPath.path])
    _ = try store.exportArtwork(
      object: front, arguments: ["format": "png", "path": pngPath.path, "dpi": 72.0])
    let svg = try String(contentsOf: svgPath, encoding: .utf8)
    let xml = try XMLDocument(xmlString: svg, options: [])
    let element = try XCTUnwrap(xml.rootElement())
    let svgWidth = Double(
      element.attribute(forName: "width")!.stringValue!.replacingOccurrences(of: "mm", with: ""))
    let svgHeight = Double(
      element.attribute(forName: "height")!.stringValue!.replacingOccurrences(of: "mm", with: ""))
    XCTAssertEqual(svgWidth, 240)
    XCTAssertEqual(svgHeight, 200)
    let rep = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: pngPath)))
    XCTAssertEqual(rep.pixelsWide, Int((240 * 72.0 / 25.4).rounded()))
    XCTAssertEqual(rep.pixelsHigh, Int((200 * 72.0 / 25.4).rounded()))
    if let dir = ProcessInfo.processInfo.environment["FORM_MERCH34_PROOF_DIR"] {
      let folder = URL(fileURLWithPath: dir)
      for (file, name) in [
        (path, "tee-direct-print-240x200.pdf"), (svgPath, "tee-direct-print-240x200.svg"),
        (pngPath, "tee-direct-print-240x200.png"),
      ] { try Data(contentsOf: file).write(to: folder.appendingPathComponent(name)) }
    }
    XCTAssertEqual(store.project, before)
    XCTAssertEqual(store.project!.editableArtwork(front), source)
    store.undo()
    XCTAssertEqual(store.project!.objects, p.objects)
  }
  func testNativeRenderedMerchandiseCollectionAndSeparateBlankFaces() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Native merchandise proof requires Metal.")
    }
    let p = try project()
    let folder = ProcessInfo.processInfo.environment["FORM_MERCH34_PROOF_DIR"].map {
      URL(fileURLWithPath: $0)
    }
    if let folder {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let full = scene(p)
    let fullImage=try await full.snapshot(size:.init(width:1500,height:1100))
    let png=try XCTUnwrap(fullImage.pngData())
    XCTAssertGreaterThan(png.count, 20000)
    if let folder {
      try png.write(to: folder.appendingPathComponent("orbital-merchandise-collection.png"))
    }
    for recipe in ["crewTee", "curvedCap", "canvasTote"] {
      let host = p.objects.first { $0.recipeID == recipe }!
      for back in recipe == "curvedCap" ? [false] : [false, true] {
        var q = p
        q.objects.removeAll { $0.id != host.id && $0.textile?.attachment?.garmentID != host.id }
        for i in q.objects.indices {
          if q.objects[i].id == host.id {
            q.objects[i].position = .init()
            q.objects[i].textile?.laidFaceDown = back
          }
          if let id = q.objects[i].artworkSourceID {
            q.objects[i].artwork = p.objects.first { $0.id == id }!.artwork
            q.objects[i].artworkSourceID = nil
          }
        }
        let s = scene(q)
        s.camera.target = .init(
          0, recipe == "curvedCap" ? 0.7 : 0.1, recipe == "canvasTote" ? -0.5 : 0)
        s.camera.distance = recipe == "crewTee" ? 15 : recipe == "canvasTote" ? 11 : 4.8
        s.camera.elevation = recipe == "curvedCap" ? 0.28 : 1.05
        s.camera.azimuth = recipe == "curvedCap" ? 0.25 : 0.06
        s.updateCamera()
        let image=try await s.snapshot(size:.init(width:1200,height:1000))
        let data=try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 15000)
        if let folder {
          try data.write(
            to: folder.appendingPathComponent(recipe + (back ? "-back" : "-front") + ".png"))
        }
      }
    }
  }
  func testActualTeeMeshUsesTheDeclaredFrontAndBackSurfaces() throws {
    let p = try project()
    let tee = p.objects.first { $0.recipeID == "crewTee" }!
    let mesh = MerchandiseGeometry.tee(
      tee, project: p, assets: FileManager.default.temporaryDirectory, limit: 256)
    let body = try XCTUnwrap(
      mesh.childNode(withName: "Jersey body and short sleeves / open crew neck", recursively: true))
    let box = body.geometry!.boundingBox
    let a = body.convertPosition(.init(0, 0, box.min.z), to: mesh)
    let b = body.convertPosition(.init(0, 0, box.max.z), to: mesh)
    XCTAssertEqual(min(a.y, b.y) * 100, 4, accuracy: 0.001)
    XCTAssertEqual(max(a.y, b.y) * 100, tee["loft"], accuracy: 0.001)
    let back = try XCTUnwrap(p.objects.first { $0.name == "Tee / independent back signature" })
    var q = p
    q.objects[q.objects.firstIndex { $0.id == tee.id }!].textile!.laidFaceDown = true
    XCTAssertGreaterThan(q.textilePlacement(back).position.y + back["height"], tee["loft"])
  }

  func testCapRenderedUVQuadrantsStayUprightAndReadableFromOutside() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("Native cap UV proof requires Metal.")
    }
    var p = try project()
    let host = p.objects.first { $0.recipeID == "curvedCap" }!
    var ink = p.objects.first { $0.name == "Cap / conforming NASA front art" }!
    ink.artworkSourceID = nil
    ink.artworkFit = nil
    ink.artwork = Artwork(
      background: "#FFFFFF",
      elements: [
        ArtworkElement(kind: "rectangle", x: 0, y: 0, width: 48, height: 15, color: "#FF0000"),
        ArtworkElement(kind: "rectangle", x: 48, y: 0, width: 48, height: 15, color: "#00FF00"),
        ArtworkElement(kind: "rectangle", x: 0, y: 15, width: 48, height: 15, color: "#0000FF"),
        ArtworkElement(kind: "rectangle", x: 48, y: 15, width: 48, height: 15, color: "#FFFF00"),
      ], bleed: 0)
    p.objects = [host, ink]
    let s = scene(p)
    s.camera.target = .init(host.position.x / 100, 0.65, host.position.z / 100)
    s.camera.distance = 4.8
    s.camera.elevation = 0.12
    s.camera.azimuth = 0
    s.camera.viewportAspect = 900.0 / 700
    s.updateCamera()
    let image = try await s.snapshot(size: .init(width: 900, height: 700))
    let rep = try XCTUnwrap(NSBitmapImageRep(data: image.pngData()!))
    let view = TableSceneView(frame: .init(x: 0, y: 0, width: 900, height: 700))
    view.controller=s;s.view=view
    let zone = MerchandiseBlanks.zones(host).first { $0.id == .front }!
    func color(_ u: Double, _ v: Double) -> NSColor {
      let local = MerchandiseBlanks.sample(host, zone: zone, u: u, v: v, clearance: ink["height"])
        .point
      let a = host.rotation * Double.pi / 180
      let world = MeshVector3(
        (host.position.x + local.x * cos(a) + local.z * sin(a)) / 100,
        (host.position.y + local.y) / 100,
        (host.position.z - local.x * sin(a) + local.z * cos(a)) / 100)
      let projected = view.projectPoint(world)
      let x = max(0, min(899, Int(projected.x)))
      let y = max(0, min(699, 699 - Int(projected.y)))
      return rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    let topLeft = color(-24, -7.5)
    let topRight = color(24, -7.5)
    let bottomLeft = color(-24, 7.5)
    let bottomRight = color(24, 7.5)
    XCTAssertGreaterThan(topLeft.redComponent, topLeft.blueComponent + 0.3)
    XCTAssertGreaterThan(topRight.greenComponent, topRight.redComponent + 0.3)
    XCTAssertGreaterThan(bottomLeft.blueComponent, bottomLeft.greenComponent + 0.3)
    XCTAssertGreaterThan(bottomRight.redComponent, 0.6)
    XCTAssertGreaterThan(bottomRight.greenComponent, 0.6)
    XCTAssertLessThan(bottomRight.blueComponent, 0.4)
    if let dir = ProcessInfo.processInfo.environment["FORM_MERCH34_PROOF_DIR"] {
      try image.pngData()!.write(
        to: URL(fileURLWithPath: dir).appendingPathComponent("cap-physical-uv-quadrants.png"))
    }
  }

  func testNewNativeRecipeSymbolsAndDefaultDirectArtworkAreVisible() throws {
    _ = NSApplication.shared
    for recipe in MerchandiseBlanks.recipes {
      XCTAssertNotNil(NSImage(systemSymbolName: recipe.symbol, accessibilityDescription: nil))
    }
    var p = Project(name: "Native direct-art creation")
    let o = try p.makeObject(recipeID: "textilePrint")
    p.objects = [o]
    XCTAssertEqual(o.materialID, "merch-ink")
    XCTAssertEqual(o.artwork?.elements.first?.text, "ARTWORK")
    let node = GeometryFactory.object(
      o, project: p, assets: FileManager.default.temporaryDirectory, textureLimit: 256)
    XCTAssertGreaterThan(node.boundingBox.max.x - node.boundingBox.min.x, 0.5)
  }

}
