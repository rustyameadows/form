import AppKit
import CoreText
import CryptoKit
import FormCore
import FormGraphics
import PDFKit
import XCTest

@MainActor final class ColorProfileTests: XCTestCase {
  private let generic = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
  }
  private func pdf() throws -> Data {
    let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 288, height: 144)
    let c = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
    for index in 0..<2 {
      var trim = box.insetBy(dx: 9, dy: 9)
      c.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size),
        kCGPDFContextTrimBox: Data(bytes: &trim, count: MemoryLayout<CGRect>.size)] as CFDictionary)
      c.setFillColor(NSColor(srgbRed: 0.8, green: 0.15, blue: 0.05, alpha: 1).cgColor)
      c.fill(CGRect(x: 10, y: 10, width: 60, height: 50))
      c.setStrokeColor(NSColor.blue.cgColor); c.setLineWidth(1.2); c.strokeEllipse(in: CGRect(x: 80, y: 10, width: 40, height: 50))
      let colors = [NSColor.red.cgColor, NSColor.green.cgColor] as CFArray
      let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
      c.saveGState(); c.clip(to: CGRect(x: 140, y: 10, width: 100, height: 50))
      c.drawLinearGradient(gradient, start: CGPoint(x: 140, y: 10), end: CGPoint(x: 240, y: 60), options: [])
      c.restoreGState()
      let bitmap = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      bitmap.setFillColor(NSColor.cyan.cgColor); bitmap.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
      c.draw(bitmap.makeImage()!, in: CGRect(x: 250, y: 10, width: 25, height: 25))
      c.textPosition = CGPoint(x: 10, y: 100)
      let font = CTFontCreateWithName("Georgia" as CFString, 14, nil)
      let text = NSAttributedString(string: "Color \(index + 1) · İzmir · Straße · Ελληνικά", attributes: [.font: font, .foregroundColor: NSColor.systemIndigo])
      CTLineDraw(CTLineCreateWithAttributedString(text), c)
      c.endPDFPage(); box = CGRect(x: 0, y: 0, width: 360, height: 180)
    }
    c.closePDF(); return data as Data
  }
  private func document(_ data: Data) throws -> CGPDFDocument {
    try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
  }
  private func content(_ page: CGPDFPage) throws -> String {
    var stream: CGPDFStreamRef?
    XCTAssertTrue(CGPDFDictionaryGetStream(page.dictionary!, "Contents", &stream))
    var format = CGPDFDataFormat.raw
    return String(data: CGPDFStreamCopyData(try XCTUnwrap(stream), &format)! as Data, encoding: .isoLatin1)!
  }
  func testPortableProfilesAndCorruptBytePreflight() throws {
    let profile = try ICCOutputProfile(url: generic), folder = try directory()
    XCTAssertEqual(profile.reference.model, "CMYK"); XCTAssertEqual(profile.space.numberOfComponents, 4)
    try profile.store(in: folder); try profile.store(in: folder)
    let restored = try ICCOutputProfile(reference: profile.reference, assets: folder)
    XCTAssertEqual(restored.data, profile.data); XCTAssertEqual(restored.reference, profile.reference)
    let url = folder.appendingPathComponent(profile.reference.asset)
    try Data("corrupt".utf8).write(to: url)
    XCTAssertThrowsError(try ICCOutputProfile(reference: profile.reference, assets: folder))
    try FileManager.default.removeItem(at: url)
    XCTAssertThrowsError(try ICCOutputProfile(reference: profile.reference, assets: folder))
    XCTAssertThrowsError(try ICCOutputProfile(data: Data(repeating: 0, count: 300), name: "Invalid"))
    var invalid = profile.reference; invalid.asset = "../profile.icc"
    XCTAssertThrowsError(try invalid.validate())
  }
  func testSourceColorsAndRenderDefinitionSurviveProfileMetadata() throws {
    var artwork = Artwork(background: "#DDAACC", elements: [.init(kind: "rectangle", x: 0, y: 0, width: 30, height: 20, color: "#CC2610")])
    let before = artwork
    artwork.outputColorProfile = try ICCOutputProfile(url: generic).reference
    try validateArtwork(artwork)
    XCTAssertEqual(artwork.renderDefinition, before.renderDefinition)
    XCTAssertEqual(artwork.elements, before.elements); XCTAssertEqual(artwork.background, before.background)
    XCTAssertEqual(try JSONDecoder.form.decode(Artwork.self, from: JSONEncoder.form.encode(artwork)), artwork)
    XCTAssertEqual(try artwork.exporting([artwork.elements[0].id]).artwork.outputColorProfile, artwork.outputColorProfile)
  }
  func testRealCMYKConversionPreservesPathsFontsImagesAndPhysicalPages() throws {
    let source = try pdf(), profile = try ICCOutputProfile(url: generic)
    let result = try ProfiledPDF.convert(source, profile: profile)
    let original = try document(source), converted = try document(result)
    XCTAssertEqual(try XCTUnwrap(PDFDocument(data: result)?.string), try XCTUnwrap(PDFDocument(data: source)?.string),
      "Profile conversion must preserve selectable Unicode text, not replace it with raster glyphs.")
    XCTAssertEqual(converted.numberOfPages, 2)
    for index in 1...2 {
      let a = original.page(at: index)!, b = converted.page(at: index)!
      XCTAssertEqual(a.getBoxRect(.mediaBox), b.getBoxRect(.mediaBox))
      XCTAssertEqual(a.getBoxRect(.trimBox), b.getBoxRect(.trimBox))
      let commands = try content(b)
      XCTAssertNotNil(commands.range(of: #"\bre\s+f\b"#, options: .regularExpression), commands)
      XCTAssertTrue(commands.contains("BT"), commands)
      XCTAssertTrue(commands.contains(" sh"), commands)
      XCTAssertTrue(commands.contains(" Do"), commands)
      // Four numeric color components precede sc, rather than three RGB values.
      XCTAssertNotNil(commands.range(of: #"(?:[0-9.]+\s+){4}sc"#, options: .regularExpression), commands)
      XCTAssertFalse(commands.contains("0.8 0.15 0.05 sc"))
      var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, image: CGPDFStreamRef?
      XCTAssertTrue(CGPDFDictionaryGetDictionary(b.dictionary!, "Resources", &resources))
      XCTAssertTrue(CGPDFDictionaryGetDictionary(resources!, "XObject", &images))
      XCTAssertTrue(CGPDFDictionaryGetStream(images!, "Im1", &image))
      var colors: CGPDFArrayRef?, icc: CGPDFStreamRef?
      XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(CGPDFStreamGetDictionary(image!)), "ColorSpace", &colors))
      XCTAssertTrue(CGPDFArrayGetStream(colors!, 1, &icc))
      var channels: CGPDFInteger = 0
      XCTAssertTrue(CGPDFDictionaryGetInteger(try XCTUnwrap(CGPDFStreamGetDictionary(icc!)), "N", &channels))
      XCTAssertEqual(channels, 4, "Embedded image samples are converted, not merely tagged with an output condition.")
    }
    let raw = String(data: result, encoding: .isoLatin1)!
    XCTAssertTrue(raw.contains("/N 4")); XCTAssertTrue(raw.contains("/Font")); XCTAssertTrue(raw.contains("/FontFile"))
    XCTAssertTrue(raw.contains("/Shading")); XCTAssertTrue(raw.contains("/Subtype /Image"))
    XCTAssertTrue(raw.contains("FORM-ICC-" + profile.reference.sha256))
    let proof = ProcessInfo.processInfo.environment["FORM_COLOR_PROOF_DIR"]
    if let proof { try result.write(to: URL(fileURLWithPath: proof).appendingPathComponent("profiled-color.pdf")) }
  }
  func testRGBOutputKeepsThreeComponentsAndProfileIntent() throws {
    let data = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
    let profile = try ICCOutputProfile(data: data, name: "Display P3 study")
    let result = try ProfiledPDF.convert(pdf(), profile: profile)
    let raw = String(data: result, encoding: .isoLatin1)!
    XCTAssertEqual(profile.reference.model, "RGB"); XCTAssertTrue(raw.contains("/N 3"))
    XCTAssertTrue(raw.contains("FORM-ICC-" + profile.reference.sha256))
  }
  func testColorSyncConvertsActualComponentsAndInstalledListIsUnique() throws {
    let profile = try ICCOutputProfile(url: generic)
    let color = try profile.convert(NSColor(srgbRed: 0.8, green: 0.15, blue: 0.05, alpha: 0.6).cgColor)
    XCTAssertEqual(color.numberOfComponents, 5); XCTAssertEqual(color.alpha, 0.6, accuracy: 0.0001)
    XCTAssertTrue(color.components!.allSatisfy(\.isFinite))
    let list = ICCOutputProfile.installed()
    XCTAssertTrue(list.contains { $0.model == "CMYK" }); XCTAssertTrue(list.contains { $0.name.contains("sRGB") })
    XCTAssertEqual(Set(list.map(\.sha256)).count, list.count)
    XCTAssertTrue(list.allSatisfy { ["RGB", "CMYK"].contains($0.model) })
  }
}
