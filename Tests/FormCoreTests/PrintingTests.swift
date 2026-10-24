import XCTest

@testable import FormCore

final class PrintingTests: XCTestCase {
  func testBinarySTLUsesMillimetersAndCompleteTriangleRecords() throws {
    let mesh = PrintMesh(triangles: [.init(.init(0, 0, 0), .init(20, 0, 0), .init(0, 20, 0))])
    let data = try mesh.binarySTL()
    XCTAssertEqual(data.count, 134)
    XCTAssertEqual(
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }, 1)
    XCTAssertEqual(
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 108, as: Float.self) }, 20)
  }
  func testBedFitAndP1SExclusion() throws {
    let printer = PrinterProfile()
    let good = PrintMesh(triangles: [.init(.init(-10, 0, 0), .init(10, 0, 0), .init(0, 20, 40))])
      .centered(on: printer)
    XCTAssertNoThrow(try good.validate(on: printer))
    XCTAssertEqual(good.bounds.minimum.z, 0)
    let tall = PrintMesh(triangles: [
      .init(.init(100, 100, 0), .init(110, 100, 0), .init(100, 110, 300))
    ])
    XCTAssertThrowsError(try tall.validate(on: printer))
    let excluded = PrintMesh(triangles: [.init(.init(0, 0, 0), .init(15, 0, 0), .init(0, 20, 1))])
    XCTAssertThrowsError(try excluded.validate(on: printer))
    let clear = PrintMesh(triangles: [
      .init(.init(13, 128, 0), .init(128, 13, 0), .init(128, 128, 20))
    ])
    XCTAssertNoThrow(
      try clear.validate(on: printer),
      "Bounding boxes must not reject geometry that clears the exclusion area")
  }
  func testToolpathHandlesRelativeExtrusionAndLayerChanges() {
    let text = """
      ; estimated printing time (normal mode) = 3m 20s
      ; filament used [g] = 1.25
      G90
      M83
      G1 X10 Y10 Z0.2
      G1 X20 Y10 E0.5
      G1 X20 Y20 E0.5
      G1 E-1
      G1 Z0.4
      G1 X10 Y20 E0.5
      """
    let preview = ToolpathPreview.parse(text)
    XCTAssertEqual(preview.segments.count, 3)
    XCTAssertEqual(preview.layers, [0.2, 0.4])
    XCTAssertEqual(preview.filamentGrams, "1.25")
    XCTAssertEqual(preview.estimatedTime, "3m 20s")
    XCTAssertTrue(ToolpathPreview.parse(text, limit: 1).truncated)
  }
  func testMQTTFramesHandleFragmentationAndConcatenation() throws {
    let first = MQTTReadOnly.frame(0x20, Data([0, 0]))
    let second = MQTTReadOnly.frame(0x30, Data(repeating: 65, count: 200))
    var buffer = Data(first.prefix(1))
    XCTAssertNil(try MQTTReadOnly.takeFrame(from: &buffer))
    buffer.append(first.dropFirst())
    buffer.append(second)
    let a = try XCTUnwrap(MQTTReadOnly.takeFrame(from: &buffer))
    XCTAssertEqual(a.0, 0x20)
    XCTAssertEqual(a.1, Data([0, 0]))
    let b = try XCTUnwrap(MQTTReadOnly.takeFrame(from: &buffer))
    XCTAssertEqual(b.0, 0x30)
    XCTAssertEqual(b.1.count, 200)
    XCTAssertTrue(buffer.isEmpty)
    XCTAssertEqual(MQTTReadOnly.connect(clientID: "test", password: "12345678").first, 0x10)
    XCTAssertEqual(MQTTReadOnly.subscribe(serial: "TEST123456").first, 0x82)
  }
  func testCircularToolpathsArePreviewedWithoutChangingGCode() {
    let path = ToolpathPreview.parse("M83\nG1 X20 Y10 Z0.2\nG3 X10 Y20 I-10 J0 E2\n")
    XCTAssertGreaterThan(path.segments.count, 20)
    XCTAssertEqual(path.segments.last?.to.x, 10)
    XCTAssertEqual(path.segments.last?.to.y, 20)
  }
  func testLibraryMigrationPreservesExistingMaterialsAndEquipment() throws {
    let old: [String: Any] = [
      "materials": try jsonObject(Material.presets),
      "equipment": try jsonObject([
        Equipment("Existing tool", width: 100, height: 200, format: "PDF")
      ]),
    ]
    let library = try JSONDecoder.form.decode(
      StudioLibrary.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertEqual(library.equipment.first?.name, "Existing tool")
    XCTAssertEqual(library.materials, Material.presets)
    XCTAssertEqual(library.filaments.count, 4)
    XCTAssertEqual(library.printers.first?.model, "Bambu Lab P1S")
    let text = String(data: try JSONEncoder.form.encode(library), encoding: .utf8)!
    XCTAssertFalse(text.contains("access_code"))
    XCTAssertFalse(text.contains("password"))
  }
  func testInvalidFilamentAndLayerSettingsAreRejected() {
    var filament = FilamentProfile(name: "Test")
    filament.nozzleTemperature = 999
    XCTAssertThrowsError(try filament.validate())
    var settings = PrintConfiguration()
    settings.layerHeight = 0.5
    XCTAssertThrowsError(try settings.validate(nozzle: 0.4))
    settings.layerHeight = 0.2
    XCTAssertNoThrow(try settings.validate(nozzle: 0.4))
    XCTAssertTrue(MCP.toolNames.contains("form_slice"))
    XCTAssertFalse(
      MCP.toolNames.contains(where: {
        $0.contains("start_print") || $0.contains("upload") || $0.contains("heat_printer")
      }))
  }
  func testP1SFilamentCompatibility() {
    var filament = FilamentProfile(name: "Test")
    XCTAssertNoThrow(try filament.validate(for: PrinterProfile()))
    filament.diameter = 2.85
    XCTAssertThrowsError(try filament.validate(for: PrinterProfile()))
    filament.diameter = 1.75
    filament.bedTemperature = 110
    XCTAssertThrowsError(try filament.validate(for: PrinterProfile()))
    filament.bedTemperature = 90
    filament.nozzleTemperature = 310
    XCTAssertThrowsError(try filament.validate(for: PrinterProfile()))
  }
}
