import Foundation
import XCTest
import FormMeshAssets

final class STLImporterTests:XCTestCase {
  func binary()->Data {
    var data=Data(repeating:0,count:80),count=UInt32(1).littleEndian
    withUnsafeBytes(of:&count){data.append(contentsOf:$0)}
    for f:Float in [0,0,1, 0,0,0, 2,0,0, 0,3,0] {var n=f.bitPattern.littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}}
    data.append(contentsOf:[0,0]);return data
  }
  func testBinarySTLRequiresExplicitUnitsAndPreservesSourceAndUnknownOrientation()throws {
    let source=binary();XCTAssertThrowsError(try STLImporter.importData(source))
    let d=try STLImporter.importData(source,options:.init(sourceUnit:.inch));XCTAssertEqual(d.sourceData,source);XCTAssertEqual(d.boundsMM.size.x,50.8,accuracy:1e-8);XCTAssertEqual(d.boundsMM.size.y,76.2,accuracy:1e-8);XCTAssertEqual(d.triangleCount,1);XCTAssertTrue(d.provenance.coordinateConvention.contains("unverified"));XCTAssertTrue(d.provenance.unitDeclaration.contains("Explicit"));try MeshAssetGeometry.validate(d)
  }
  func testASCIISTLGrammarAndFiniteValuesAreValidated()throws {
    let text="""
    solid authored fixture
    facet normal 0 0 1
      outer loop
        vertex 0 0 0
        vertex 2 0 0
        vertex 0 3 0
      endloop
    endfacet
    endsolid authored fixture
    """
    let d=try STLImporter.importData(Data(text.utf8),options:.init(sourceUnit:.millimeter));XCTAssertEqual(d.provenance.format,"stl-ascii");XCTAssertEqual(d.boundsMM.size.x,2);XCTAssertEqual(d.triangleCount,1)
    for bad in [text.replacingOccurrences(of:"vertex 2",with:"vertex nan"),text.replacingOccurrences(of:"endloop",with:"vertex 0 0 0"),text.replacingOccurrences(of:"endsolid authored fixture",with:""),text+"\nfacet normal 0 0 1"] {XCTAssertThrowsError(try STLImporter.importData(Data(bad.utf8),options:.init(sourceUnit:.millimeter)))}
  }
  func testMalformedBinaryAndComplexityLimitsReject()throws {
    var source=binary();source[80]=255;XCTAssertThrowsError(try STLImporter.importData(source,options:.init(sourceUnit:.millimeter)))
    source=binary();var n=Float.infinity.bitPattern.littleEndian;withUnsafeBytes(of:&n){source.replaceSubrange(96..<100,with:$0)};XCTAssertThrowsError(try STLImporter.importData(source,options:.init(sourceUnit:.millimeter)))
    var limits=MeshImportLimits();limits.vertices=2;XCTAssertThrowsError(try STLImporter.importData(binary(),options:.init(sourceUnit:.millimeter,limits:limits)))
  }
}
