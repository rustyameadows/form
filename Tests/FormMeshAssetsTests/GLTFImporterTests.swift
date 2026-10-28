import Foundation
import XCTest
import FormMeshAssets

final class GLTFImporterTests:XCTestCase {
  private func document(_ value:(json:[String:Any],binary:Data))throws->MeshAssetDocument {try GLTFImporter.importData(MeshAssetFixtures.glb(value.json,binary:value.binary))}
  private func changing(_ edit:(inout [String:Any],inout Data)->Void)->(json:[String:Any],binary:Data) {var f=MeshAssetFixtures.triangle();edit(&f.json,&f.binary);return f}
  private func rejects(_ fixture:(json:[String:Any],binary:Data),file:StaticString=#filePath,line:UInt=#line) {XCTAssertThrowsError(try document(fixture),file:file,line:line)}
  func testMetersHierarchyMaterialUVSourceAndCodableRoundtrip()throws {
    let f=MeshAssetFixtures.triangle(),source=MeshAssetFixtures.glb(f.json,binary:f.binary),d=try GLTFImporter.importData(source,fileName:"Device.glb")
    XCTAssertEqual(d.provenance.format,"glb");XCTAssertEqual(d.provenance.unit,.meter);XCTAssertEqual(d.boundsMM.size.x,40,accuracy:0.00001);XCTAssertEqual(d.boundsMM.size.y,30,accuracy:0.00001)
    XCTAssertEqual(d.nodes.count,2);XCTAssertEqual(d.nodes[0].children,[1]);XCTAssertEqual(d.meshes[0].primitives[0].uv0.count,3);XCTAssertEqual(d.meshes[0].primitives[0].normals[0],.init(0,0,1));XCTAssertEqual(d.materials[0].name,"Ivory")
    XCTAssertEqual(d.sourceData,source);XCTAssertEqual(d.provenance.sourceSHA256,MeshAssetHash.sha256(source));XCTAssertEqual(d.provenance.sourceByteCount,source.count)
    let copy=try JSONDecoder().decode(MeshAssetDocument.self,from:JSONEncoder().encode(d));XCTAssertEqual(copy,d);try MeshAssetGeometry.validate(copy)
  }
  func testSharedMeshesAndNestedTransformsUsePhysicalMillimeters()throws {
    let d=try document(MeshAssetFixtures.cube());XCTAssertEqual(d.meshes.count,1);XCTAssertEqual(d.instanceTriangleCount,24);XCTAssertEqual(d.nodes[1].worldTransform.matrix[12],100,accuracy:1e-9)
    XCTAssertEqual(d.boundsMM.minimum.x,-100,accuracy:1e-9);XCTAssertEqual(d.boundsMM.maximum.x,140,accuracy:0.00001);XCTAssertEqual(d.boundsMM.maximum.y,230,accuracy:0.00001)
    let flattened=try MeshAssetGeometry.flattenedPrimitives(d);XCTAssertEqual(flattened.count,2);XCTAssertNotEqual(flattened[0].id,flattened[1].id);XCTAssertEqual(flattened[0].positionsMM[0],.init(100,200,300))
  }
  func testInstancedPrimitiveBudgetRejectsSmallSourcesBeforeExpandedPartMetadata()throws {
    var fixture=MeshAssetFixtures.triangle(),meshes=fixture.json["meshes"] as! [[String:Any]],primitives=meshes[0]["primitives"] as! [[String:Any]]
    primitives=Array(repeating:primitives[0],count:3);meshes[0]["primitives"]=primitives;fixture.json["meshes"]=meshes
    fixture.json["nodes"]=Array(repeating:["mesh":0],count:4096);fixture.json["scenes"]=[["nodes":Array(0..<4096)]]
    XCTAssertThrowsError(try document(fixture)){error in XCTAssertTrue(error.localizedDescription.contains("Instanced primitives"))}
    var normalized=try document(MeshAssetFixtures.triangle()),copy=normalized.nodes[1]
    copy.id="duplicate";normalized.nodes.append(copy);normalized.sceneRoots.append(2)
    var limits=MeshImportLimits();limits.primitives=1
    XCTAssertThrowsError(try MeshAssetGeometry.validate(normalized,limits:limits))
  }
  func testExplicitUnitOverrideIsRecordedWithoutChangingSourceBytes()throws {
    let f=MeshAssetFixtures.triangle(),raw=MeshAssetFixtures.glb(f.json,binary:f.binary)
    let d=try GLTFImporter.importData(raw,options:.init(sourceUnit:.centimeter));XCTAssertEqual(d.provenance.unit,.centimeter);XCTAssertTrue(d.provenance.unitDeclaration.contains("override"));XCTAssertEqual(d.boundsMM.size.x,0.4,accuracy:1e-6);XCTAssertEqual(d.sourceData,raw)
  }
  func testExternalResourcesAreRetainedAndTraversalNetworkAndSymlinkEscapesReject()throws {
    var f=MeshAssetFixtures.triangle();f.json["buffers"]=[["byteLength":f.binary.count,"uri":"geometry.bin"]]
    let json=try JSONSerialization.data(withJSONObject:f.json),d=try GLTFImporter.importData(json,fileName:"device.gltf",externalResource:{uri in XCTAssertEqual(uri,"geometry.bin");return f.binary})
    XCTAssertEqual(d.externalResources.count,1);XCTAssertEqual(d.externalResources[0].data,f.binary);XCTAssertEqual(d.provenance.format,"gltf")
    for uri in ["../escape.bin","%2e%2e/escape.bin","/tmp/out.bin","https://example.com/model.bin","file:///tmp/a.bin","a\\b.bin","a/./b.bin","a//b.bin","a.bin?x=1"] {
      f.json["buffers"]=[["byteLength":f.binary.count,"uri":uri]];var called=false
      XCTAssertThrowsError(try GLTFImporter.importData(JSONSerialization.data(withJSONObject:f.json),externalResource:{_ in called=true;return f.binary}));XCTAssertFalse(called)
    }
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),inside=root.appendingPathComponent("inside"),outside=root.appendingPathComponent("outside.bin")
    try FileManager.default.createDirectory(at:inside,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
    try f.binary.write(to:outside);try FileManager.default.createSymbolicLink(at:inside.appendingPathComponent("linked.bin"),withDestinationURL:outside)
    f.json["buffers"]=[["byteLength":f.binary.count,"uri":"linked.bin"]];let source=inside.appendingPathComponent("model.gltf");try JSONSerialization.data(withJSONObject:f.json).write(to:source)
    XCTAssertThrowsError(try GLTFImporter.importFile(source))
  }
  func testDataURIBuffersAndInterleavedAccessors()throws {
    var f=MeshAssetFixtures.triangle();f.json["buffers"]=[["byteLength":f.binary.count,"uri":"data:application/octet-stream;base64,"+f.binary.base64EncodedString()]]
    let d=try GLTFImporter.importData(JSONSerialization.data(withJSONObject:f.json));XCTAssertEqual(d.triangleCount,1)
    var b=MeshAssetFixtures.Builder();let vertex:[Float]=[0,0,0,99, 0.04,0,0,99, 0,0.03,0,99]
    _=b.accessor(vertex,type:"VEC4",dimensions:4);b.views[0]["byteStride"]=16;b.accessors[0]["type"]="VEC3";b.meshes=[["primitives":[["attributes":["POSITION":0],"mode":4]]]]
    let read=try document((b.root(nodes:[["mesh":0]]),b.binary));XCTAssertEqual(read.boundsMM.size.x,40,accuracy:1e-5);XCTAssertTrue(read.meshes[0].primitives[0].generatedNormals)
  }
  func testSparseAccessorAppliesOnlyIncreasingBoundedIndices()throws {
    var b=MeshAssetFixtures.Builder();_=b.accessor([0,0,0,0,0,0,0,0,0],type:"VEC3",dimensions:3);_=b.indices([1,2]);_=b.accessor([0.04,0,0,0,0.03,0],type:"VEC3",dimensions:3)
    b.accessors[0]["sparse"]=["count":2,"indices":["bufferView":1,"componentType":5125],"values":["bufferView":2]];b.meshes=[["primitives":[["attributes":["POSITION":0]]]]]
    let root=b.root(nodes:[["mesh":0]]),d=try document((root,b.binary));XCTAssertEqual(d.boundsMM.size.x,40,accuracy:1e-5)
    var bad=root,access=bad["accessors"] as! [[String:Any]],sparse=access[0]["sparse"] as! [String:Any];sparse["count"]=4;access[0]["sparse"]=sparse;bad["accessors"]=access;rejects((bad,b.binary))
    var duplicate=b.binary;var two=UInt32(1).littleEndian;withUnsafeBytes(of:&two){duplicate.replaceSubrange(40..<44,with:$0)};rejects((root,duplicate))
  }
  func testInvalidAccessorOffsetsIndicesNaNsAndStrideRejectBeforePublishing()throws {
    rejects(changing {root,_ in var a=root["accessors"] as! [[String:Any]];a[0]["count"]=Int.max;root["accessors"]=a})
    rejects(changing {root,_ in var a=root["accessors"] as! [[String:Any]];a[0]["byteOffset"]=1;root["accessors"]=a})
    rejects(changing {root,_ in var v=root["bufferViews"] as! [[String:Any]];v[0]["byteStride"]=3;root["bufferViews"]=v})
    rejects(changing {root,_ in var v=root["bufferViews"] as! [[String:Any]];v[0]["byteLength"]=1;root["bufferViews"]=v})
    rejects(changing {_,binary in var x=Float.nan.bitPattern.littleEndian;withUnsafeBytes(of:&x){binary.replaceSubrange(0..<4,with:$0)}})
    rejects(changing {root,binary in let views=root["bufferViews"] as! [[String:Any]],offset=views.last!["byteOffset"] as! Int;var x=UInt32(99).littleEndian;withUnsafeBytes(of:&x){binary.replaceSubrange(offset..<offset+4,with:$0)}})
  }
  func testGLBHeaderChunkLengthsAndDuplicateChunksAreValidated()throws {
    let f=MeshAssetFixtures.triangle(),raw=MeshAssetFixtures.glb(f.json,binary:f.binary)
    for end in [0,4,12,19,raw.count-1] {XCTAssertThrowsError(try GLTFImporter.importData(raw.prefix(end)))}
    var wrong=raw;wrong[4]=1;XCTAssertThrowsError(try GLTFImporter.importData(wrong))
    wrong=raw;wrong[16]=0;XCTAssertThrowsError(try GLTFImporter.importData(wrong))
    wrong=raw;wrong[12]=1;XCTAssertThrowsError(try GLTFImporter.importData(wrong))
  }
  func testHierarchyCyclesMultipleParentsAndDepthBudgetCannotBeBypassedByNodeOrder()throws {
    rejects(changing {root,_ in root["nodes"]=[["children":[1]],["mesh":0,"children":[0]]];root.removeValue(forKey:"scenes");root.removeValue(forKey:"scene")})
    rejects(changing {root,_ in root["nodes"]=[["children":[1,2]],["children":[2]],["mesh":0]]})
    var f=MeshAssetFixtures.triangle();f.json["nodes"]=(0..<130).map{i->[String:Any] in i<129 ? ["children":[i+1]]:["mesh":0]};rejects(f)
    let first=try document(MeshAssetFixtures.triangle());XCTAssertEqual(first.nodes[1].inSelectedScene,true)
  }
  func testUnselectedScenesDoNotAffectBoundsButRemainInSourceHierarchy()throws {
    var f=MeshAssetFixtures.triangle();f.json["nodes"]=[["mesh":0],["mesh":0,"translation":[100,0,0]]];f.json["scenes"]=[["nodes":[0]],["nodes":[1]]];let d=try document(f)
    XCTAssertEqual(d.nodes.count,2);XCTAssertFalse(d.nodes[1].inSelectedScene);XCTAssertEqual(d.boundsMM.maximum.x,40,accuracy:1e-5)
  }
  func testRequiredCompressionSkinsAndMorphsFailWithActionableErrors()throws {
    for feature in ["KHR_draco_mesh_compression","EXT_meshopt_compression","KHR_mesh_quantization"] {rejects(changing{root,_ in root["extensionsRequired"]=[feature]})}
    rejects(changing{root,_ in root["skins"]=[[:]]})
    rejects(changing{root,_ in var meshes=root["meshes"] as! [[String:Any]],p=meshes[0]["primitives"] as! [[String:Any]];p[0]["targets"]=[["POSITION":0]];meshes[0]["primitives"]=p;root["meshes"]=meshes})
  }
  func testTriangleStripsFansGeneratedNormalsAndComplexityBudgets()throws {
    for mode in [5,6] {let f=changing{root,_ in var meshes=root["meshes"] as! [[String:Any]],p=meshes[0]["primitives"] as! [[String:Any]];p[0]["mode"]=mode;meshes[0]["primitives"]=p;root["meshes"]=meshes};let d=try document(f);XCTAssertEqual(d.triangleCount,1)}
    var limits=MeshImportLimits();limits.vertices=2
    let f=MeshAssetFixtures.triangle();XCTAssertThrowsError(try GLTFImporter.importData(MeshAssetFixtures.glb(f.json,binary:f.binary),options:.init(limits:limits)))
    limits=MeshImportLimits();limits.instanceVertices=10
    let cube=MeshAssetFixtures.cube();XCTAssertThrowsError(try GLTFImporter.importData(MeshAssetFixtures.glb(cube.json,binary:cube.binary),options:.init(limits:limits)))
  }
  func testTexturesPBRAndUVTransformAreRetainedWithOriginalPixels()throws {
    var f=MeshAssetFixtures.triangle();let image=MeshAssetFixtures.texture();f.json["images"]=[["uri":"data:image/png;base64,"+image.base64EncodedString()]];f.json["textures"]=[["source":0,"sampler":0]];f.json["samplers"]=[["wrapS":33071,"wrapT":33648]]
    f.json["extensionsRequired"]=["KHR_texture_transform","KHR_materials_unlit"]
    f.json["materials"]=[["name":"PBR fixture","doubleSided":true,"alphaMode":"MASK","alphaCutoff":0.3,"extensions":["KHR_materials_unlit":[:]],"pbrMetallicRoughness":["metallicFactor":0.4,"roughnessFactor":0.7,"baseColorTexture":["index":0,"extensions":["KHR_texture_transform":["offset":[0.1,0.2],"scale":[2,3],"rotation":0]]],"metallicRoughnessTexture":["index":0]],"normalTexture":["index":0,"scale":0.5]]]
    let d=try document(f),m=d.materials[0];XCTAssertEqual(d.images[0].data,image);XCTAssertEqual(d.images[0].width,16);XCTAssertEqual(m.normalTexture?.strength,0.5);XCTAssertNotNil(m.metallicRoughnessTexture);XCTAssertTrue(m.doubleSided);XCTAssertTrue(m.unlit);XCTAssertEqual(m.alphaMode,"MASK");XCTAssertEqual(d.textures[0].wrapS,33071)
    let uv=try XCTUnwrap(m.baseColorTexture).transformed(.init(0.5,0.5));XCTAssertEqual(uv.u,1.1,accuracy:1e-6);XCTAssertEqual(uv.v,1.7,accuracy:1e-6)
    XCTAssertTrue(d.provenance.warnings.contains{$0.contains("normal scale")})
    var limits=MeshImportLimits();limits.textureEdge=8;XCTAssertThrowsError(try GLTFImporter.importData(MeshAssetFixtures.glb(f.json,binary:f.binary),options:.init(limits:limits)))
    f.json["images"]=[["uri":"data:image/jpeg;base64,"+image.base64EncodedString()]];rejects(f)
  }
  func testMissingUVBindingsAndInvalidTextureImagesReject()throws {
    var f=MeshAssetFixtures.triangle();f.json["images"]=[["uri":"data:image/png;base64,"+Data([1,2,3]).base64EncodedString()]];f.json["textures"]=[["source":0]];rejects(f)
    f.json["images"]=[["uri":"data:image/png;base64,"+MeshAssetFixtures.texture().base64EncodedString()]];f.json["materials"]=[["pbrMetallicRoughness":["baseColorTexture":["index":0,"texCoord":1]]]];rejects(f)
  }
  func testClosedCubeTopologyMirroredWindingAndNonUniformNormalTransform()throws {
    let d=try document(MeshAssetFixtures.cube()),p=d.meshes[0].primitives[0],report=try MeshTopology.inspect(p)
    XCTAssertTrue(report.isClosedOrientedSurface);XCTAssertGreaterThan(report.signedVolumeMM3,0);XCTAssertEqual(report.signedVolumeMM3,24_000,accuracy:0.01);XCTAssertFalse(report.selfIntersectionsChecked)
    let matrix=MeshAssetTransform(matrix:[-2,0,0,0, 0,3,0,0, 0,0,4,0, 10,20,30,1]),mirrored=try MeshAssetGeometry.transformed(p,by:matrix),health=try MeshTopology.inspect(mirrored)
    XCTAssertTrue(health.isClosedOrientedSurface);XCTAssertEqual(health.signedVolumeMM3,report.signedVolumeMM3*24,accuracy:0.01)
    XCTAssertEqual(p.indices[1],mirrored.indices[2]);XCTAssertEqual(d.meshes[0].primitives[0],p)
    let n=matrix.normal(.init(1,1,0));XCTAssertLessThan(n.x,0);XCTAssertGreaterThan(n.y,0);XCTAssertEqual(n.x/n.y,-1.5,accuracy:1e-6)
  }
  func testNormalizedDocumentCannotSmuggleInvalidIndicesTextureDigestsOrCycles()throws {
    var d=try document(MeshAssetFixtures.triangle());d.meshes[0].primitives[0].indices[0]=999;XCTAssertThrowsError(try MeshAssetGeometry.validate(d))
    d=try document(MeshAssetFixtures.triangle());d.nodes[1].children=[0];XCTAssertThrowsError(try MeshAssetGeometry.validate(d))
    d=try document(MeshAssetFixtures.triangle());d.nodes[1].worldTransform.matrix=[1];XCTAssertThrowsError(try MeshAssetGeometry.validate(d))
  }
  func testNormalizedAffineHierarchyWorldCoordinatesAndClaimedBoundsMustAgree()throws {
    let source=try document(MeshAssetFixtures.triangle())
    var changed=source;changed.nodes[1].worldTransform.matrix[12]=100
    XCTAssertThrowsError(try MeshAssetGeometry.validate(changed))
    changed=source;changed.boundsMM.maximum.x+=1
    XCTAssertThrowsError(try MeshAssetGeometry.validate(changed))
    changed=source;changed.nodes[1].localTransform.matrix[12]=1e10;changed.nodes[1].worldTransform=changed.nodes[1].localTransform
    XCTAssertThrowsError(try MeshAssetGeometry.validate(changed))
    changed=source;changed.nodes[1].localTransform.matrix[0]=1e300;changed.nodes[1].worldTransform=changed.nodes[1].localTransform
    XCTAssertThrowsError(try MeshAssetGeometry.validate(changed))
    changed=source;changed.nodes[0].localTransform.matrix[12]=12;changed.nodes[0].worldTransform=changed.nodes[0].localTransform;changed.nodes[1].worldTransform=changed.nodes[0].worldTransform.followed(by:changed.nodes[1].localTransform);changed.boundsMM.minimum.x+=12;changed.boundsMM.maximum.x+=12
    XCTAssertNoThrow(try MeshAssetGeometry.validate(changed))
  }
  func testOriginalHighDetailJacketRetainsCurvedPartsHierarchyTexturesAndSeparatePatch()throws {
    let f=MeshAssetFixtures.jacket(),data=MeshAssetFixtures.glb(f.json,binary:f.binary),start=Date(),d=try GLTFImporter.importData(data,fileName:"LAB-synthetic-flight-jacket.glb")
    XCTAssertGreaterThan(d.triangleCount,100_000);XCTAssertEqual(d.meshes.count,9);XCTAssertEqual(d.nodes.count,10);XCTAssertEqual(d.materials.count,4);XCTAssertEqual(d.images.count,2);XCTAssertTrue(d.nodes.contains{$0.name=="Separate chest patch"})
    XCTAssertGreaterThan(d.boundsMM.size.x,1200);XCTAssertGreaterThan(d.boundsMM.size.y,600);XCTAssertTrue(d.meshes.allSatisfy{$0.primitives.allSatisfy{!$0.uv0.isEmpty}});try MeshAssetGeometry.validate(d)
    print("MESH_IMPORT_SYNTHETIC_JACKET",d.vertexCount,d.triangleCount,Date().timeIntervalSince(start),data.count)
  }
}
