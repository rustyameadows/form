import Foundation
import CryptoKit
import CFormCADKernel

public struct CADPoint2: Codable, Equatable, Sendable {
  public var x: Double, y: Double
  public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}
public struct CADPoint3: Codable, Equatable, Sendable {
  public var x: Double, y: Double, z: Double
  public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
  fileprivate var c: FCADPoint { .init(x: x, y: y, z: z) }
  fileprivate init(_ p: FCADPoint) { self.init(p.x, p.y, p.z) }
  public static func + (a: Self, b: Self) -> Self { .init(a.x+b.x,a.y+b.y,a.z+b.z) }
  public static func * (a: Self, b: Double) -> Self { .init(a.x*b,a.y*b,a.z*b) }
}
/// Explicit right-handed local plane in document millimeters. u/v are unit axes.
public struct CADPlane: Codable, Equatable, Sendable {
  public var origin: CADPoint3, u: CADPoint3, v: CADPoint3
  public init(origin: CADPoint3 = .init(), u: CADPoint3, v: CADPoint3) { self.origin=origin;self.u=u;self.v=v }
  public static let xy = Self(u:.init(1,0,0),v:.init(0,1,0))
  public static let xz = Self(u:.init(1,0,0),v:.init(0,0,-1))
  public static let yz = Self(u:.init(0,1,0),v:.init(0,0,1))
  public var normal: CADPoint3 { .init(u.y*v.z-u.z*v.y,u.z*v.x-u.x*v.z,u.x*v.y-u.y*v.x) }
  public func point(_ p: CADPoint2) -> CADPoint3 { origin + u*p.x + v*p.y }
  fileprivate func validate() throws {
    func norm(_ p:CADPoint3)->Double {p.x*p.x+p.y*p.y+p.z*p.z}
    let dot=u.x*v.x+u.y*v.y+u.z*v.z
    guard abs(norm(u)-1)<1e-10,abs(norm(v)-1)<1e-10,abs(dot)<1e-10 else {throw CADKernelError(.invalidInput,"A CAD plane requires orthonormal unit u/v axes.")}
  }
}
public struct CADCurveSegment: Sendable {
  public enum Kind: Int32, Sendable { case line=0,quadraticBezier=1,cubicBezier=2,circularArc=3 }
  public var kind:Kind,start:CADPoint3,control1:CADPoint3,control2:CADPoint3,end:CADPoint3
  public init(_ kind:Kind,start:CADPoint3,control1:CADPoint3 = .init(),control2:CADPoint3 = .init(),end:CADPoint3){self.kind=kind;self.start=start;self.control1=control1;self.control2=control2;self.end=end}
  fileprivate var c:FCADCurveSegment {.init(kind:kind.rawValue,start:start.c,control1:control1.c,control2:control2.c,end:end.c)}
}
public struct CADShapeInfo: Codable, Equatable, Sendable {
  public var minimum: CADPoint3, maximum: CADPoint3
  public var volumeMM3: Double, areaMM2: Double, maximumToleranceMM: Double
  public var solids: Int, shells: Int, faces: Int, edges: Int, vertices: Int
  public var valid: Bool, closed: Bool, shapeType: Int
  public var size: CADPoint3 { .init(maximum.x-minimum.x,maximum.y-minimum.y,maximum.z-minimum.z) }
  fileprivate init(_ i: FCADShapeInfo) {
    minimum = .init(i.minimum);maximum = .init(i.maximum);volumeMM3=i.volume;areaMM2=i.area;maximumToleranceMM=i.maximum_tolerance
    solids=Int(i.solids);shells=Int(i.shells);faces=Int(i.faces);edges=Int(i.edges);vertices=Int(i.vertices)
    valid=i.valid != 0;closed=i.closed != 0;shapeType=Int(i.shape_type)
  }
}
public struct CADFaceInfo: Codable, Equatable, Sendable {
  /// 1-based and valid only for this exact B-rep revision; not a persistent face name.
  public var index: UInt32, surfaceType: Int32, areaMM2: Double, center: CADPoint3, minimum: CADPoint3, maximum: CADPoint3
  fileprivate init(_ i:FCADFaceInfo){index=i.index;surfaceType=i.surface_type;areaMM2=i.area;center = .init(i.center);minimum = .init(i.minimum);maximum = .init(i.maximum)}
}
public struct CADEdgeInfo: Codable, Equatable, Sendable {
  public var index: UInt32, curveType: Int32, lengthMM: Double, start: CADPoint3, end: CADPoint3, center: CADPoint3
  fileprivate init(_ i:FCADEdgeInfo){index=i.index;curveType=i.curve_type;lengthMM=i.length;start = .init(i.start);end = .init(i.end);center = .init(i.center)}
}
public struct CADMesh: Codable, Equatable, Sendable {
  public var positions: [CADPoint3], normals: [CADPoint3], textureCoordinates: [CADPoint2], indices: [UInt32], faceIndices: [UInt32]
  public var triangleCount: Int { indices.count/3 }
  public init(positions:[CADPoint3],normals:[CADPoint3],textureCoordinates:[CADPoint2],indices:[UInt32],faceIndices:[UInt32]){self.positions=positions;self.normals=normals;self.textureCoordinates=textureCoordinates;self.indices=indices;self.faceIndices=faceIndices}
}
public struct CADTessellation: Codable, Equatable, Sendable {
  public var linearDeflectionMM: Double, angularDeflectionRadians: Double
  public init(linearDeflectionMM:Double,angularDeflectionRadians:Double){self.linearDeflectionMM=linearDeflectionMM;self.angularDeflectionRadians=angularDeflectionRadians}
  public static let preview=Self(linearDeflectionMM:0.2,angularDeflectionRadians:0.35)
  public static let inspection=Self(linearDeflectionMM:0.05,angularDeflectionRadians:0.15)
  public static let fabrication=Self(linearDeflectionMM:0.02,angularDeflectionRadians:0.1)
}
public struct CADClearance: Codable, Equatable, Sendable { public var distanceMM:Double, interferenceVolumeMM3:Double }
public enum CADBoolean: Int32, Codable, Sendable { case union=0, subtract=1, intersection=2 }
public struct CADKernelError: LocalizedError, Sendable {
  public enum Code: Int32, Codable, Sendable { case invalidInput=1,operationFailed=2,invalidTopology=3,limitExceeded=4,ioFailed=5,cancelled=6 }
  public let code: Code
  public let message: String
  public init(_ code:Code,_ message:String){self.code=code;self.message=message}
  public var errorDescription:String? {message}
  fileprivate init(_ failure:FCADFailure,status:FCADStatus) {
    code=Code(rawValue:Int32(status.rawValue)) ?? .operationFailed
    var message=failure.message
    self.message=withUnsafePointer(to:&message){$0.withMemoryRebound(to:CChar.self,capacity:1024){String(cString:$0)}}
  }
}
private final class CADShapeStorage: @unchecked Sendable {
  let pointer: OpaquePointer
  private static let releaseQueue=DispatchQueue(label:"studio.lab.cad.release",qos:.utility)
  init(_ pointer:OpaquePointer){self.pointer=pointer}
  deinit {let address=UInt(bitPattern:pointer);Self.releaseQueue.async {if let pointer=OpaquePointer(bitPattern:address){fcad_shape_release(pointer)}}}
}
/// Immutable, ephemeral runtime handle. Durable IDs/feature history belong to the
/// product graph; serialize exact source through B-rep/STEP, never this handle.
public struct CADShape: Sendable {
  public let id: UUID
  public let info: CADShapeInfo
  private let storage:CADShapeStorage
  fileprivate var pointer:OpaquePointer {storage.pointer}
  fileprivate init(_ pointer:OpaquePointer,info:CADShapeInfo){id=UUID();self.info=info;storage=CADShapeStorage(pointer)}
}
private final class CADCancellation: @unchecked Sendable {
  let pointer:OpaquePointer
  init(){pointer=fcad_context_create()!}
  func cancel(){fcad_context_cancel(pointer)}
  deinit{fcad_context_release(pointer)}
}

/// Serial exact-geometry worker. No method runs on MainActor. Independent actors
/// also share a C-side kernel gate because STEP configuration is process-global.
public actor CADKernel {
  private var stepAssemblies:[String:CADSTEPAssembly]=[:],stepAssemblyOrder:[String]=[],stepAssemblyBytes=0
  public nonisolated static var version:String {String(cString:fcad_version())}
  private nonisolated static let bundledResources:Void = {
    guard let root=Bundle.main.resourceURL?.appendingPathComponent("OCCT",isDirectory:true),FileManager.default.fileExists(atPath:root.appendingPathComponent("XSTEPResource").path) else{return}
    let defaults=["CSF_OCCTResourcePath":"","CSF_SHMessage":"SHMessage","CSF_XSMessage":"XSMessage","CSF_StandardDefaults":"StdResource","CSF_PluginDefaults":"StdResource","CSF_XCAFDefaults":"StdResource","CSF_TObjDefaults":"StdResource","CSF_StandardLiteDefaults":"StdResource","CSF_IGESDefaults":"XSTEPResource","CSF_STEPDefaults":"XSTEPResource","CSF_XmlOcafResource":"XmlOcafResource","CSF_MIGRATION_TYPES":"StdResource/MigrationSheet.txt"]
    for (key,path) in defaults{setenv(key,path.isEmpty ? root.path:root.appendingPathComponent(path).path,1)}
  }()
  public init(){_ = Self.bundledResources}
  private func operation<T>(_ body:(OpaquePointer)throws->T) async throws ->T {
    let cancellation=CADCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation();let result=try body(cancellation.pointer);try Task.checkCancellation();return result
    } onCancel:{cancellation.cancel()}
  }
  private func checked(_ status:FCADStatus,_ failure:FCADFailure)throws {
    guard status==FCAD_OK else {throw CADKernelError(failure,status:status)}
  }
  private func result(_ context:OpaquePointer,_ build:(UnsafeMutablePointer<OpaquePointer?>,UnsafeMutablePointer<FCADFailure>)->FCADStatus)throws->CADShape {
    var pointer:OpaquePointer?,failure=FCADFailure();let status=build(&pointer,&failure)
    if status != FCAD_OK {if let pointer {fcad_shape_release(pointer)};throw CADKernelError(failure,status:status)}
    guard let pointer else {throw CADKernelError(.operationFailed,"The CAD kernel returned no exact result.")}
    var info=FCADShapeInfo();let inspected=fcad_info(context,pointer,&info,&failure)
    if inspected != FCAD_OK {fcad_shape_release(pointer);throw CADKernelError(failure,status:inspected)}
    return CADShape(pointer,info:.init(info))
  }
  public func box(width:Double,height:Double,depth:Double) async throws ->CADShape {try await operation {c in try result(c){fcad_box(c,width,height,depth,$0,$1)}}}
  public func cylinder(radius:Double,height:Double) async throws ->CADShape {try await operation {c in try result(c){fcad_cylinder(c,radius,height,$0,$1)}}}
  public func cone(bottomRadius:Double,topRadius:Double,height:Double) async throws ->CADShape {try await operation {c in try result(c){fcad_cone(c,bottomRadius,topRadius,height,$0,$1)}}}
  public func sphere(radius:Double) async throws ->CADShape {try await operation {c in try result(c){fcad_sphere(c,radius,$0,$1)}}}
  public func torus(majorRadius:Double,minorRadius:Double) async throws ->CADShape {try await operation {c in try result(c){fcad_torus(c,majorRadius,minorRadius,$0,$1)}}}
  public func profile(outer:[CADPoint2],holes:[[CADPoint2]]=[],plane:CADPlane = .xy) async throws ->CADShape {
    try await operation {c in
      try plane.validate();let rings=[outer]+holes,points=rings.flatMap{$0.map{plane.point($0).c}},sizes=rings.map{UInt32($0.count)}
      return try points.withUnsafeBufferPointer {p in try sizes.withUnsafeBufferPointer {s in try result(c){fcad_profile(c,p.baseAddress,p.count,s.baseAddress,s.count,plane.normal.c,$0,$1)}}}
    }
  }
  public func circleProfile(radius:Double,plane:CADPlane = .xz) async throws ->CADShape {try await operation {c in try plane.validate();return try result(c){fcad_circle_profile(c,plane.origin.c,plane.normal.c,plane.u.c,radius,$0,$1)}}}
  public func curveProfile(_ segments:[CADCurveSegment]) async throws ->CADShape {try await operation {c in let segments=segments.map(\.c);return try segments.withUnsafeBufferPointer {s in try result(c){fcad_curve_profile(c,s.baseAddress,s.count,$0,$1)}}}}
  public func extrude(_ profile:CADShape,vector:CADPoint3) async throws ->CADShape {try await operation {c in try result(c){fcad_extrude(c,profile.pointer,vector.c,$0,$1)}}}
  public func revolve(_ profile:CADShape,axisOrigin:CADPoint3 = .init(),axisDirection:CADPoint3 = .init(0,1,0),radians:Double = 2 * .pi) async throws ->CADShape {try await operation {c in try result(c){fcad_revolve(c,profile.pointer,axisOrigin.c,axisDirection.c,radians,$0,$1)}}}
  public func boolean(_ kind:CADBoolean,_ left:CADShape,_ right:CADShape) async throws ->CADShape {try await operation {c in try result(c){fcad_boolean(c,kind.rawValue,left.pointer,right.pointer,$0,$1)}}}
  public func fillet(_ shape:CADShape,edges:[UInt32]=[],radius:Double) async throws ->CADShape {try await operation {c in try edges.withUnsafeBufferPointer {ids in try result(c){fcad_fillet(c,shape.pointer,ids.baseAddress,ids.count,radius,$0,$1)}}}}
  public func chamfer(_ shape:CADShape,edges:[UInt32]=[],distance:Double) async throws ->CADShape {try await operation {c in try edges.withUnsafeBufferPointer {ids in try result(c){fcad_chamfer(c,shape.pointer,ids.baseAddress,ids.count,distance,$0,$1)}}}}
  public func shell(_ shape:CADShape,removingFaces:[UInt32],thickness:Double) async throws ->CADShape {try await operation {c in try removingFaces.withUnsafeBufferPointer {ids in try result(c){fcad_shell(c,shape.pointer,ids.baseAddress,ids.count,thickness,$0,$1)}}}}
  public func offsetProfile(_ profile:CADShape,distance:Double) async throws->CADShape {try await operation{c in try result(c){fcad_offset_profile(c,profile.pointer,distance,$0,$1)}}}
  public func sweep(_ profile:CADShape,path:[CADPoint3]) async throws ->CADShape {try await operation {c in let points=path.map(\.c);return try points.withUnsafeBufferPointer {p in try result(c){fcad_sweep(c,profile.pointer,p.baseAddress,p.count,$0,$1)}}}}
  public func loft(_ profiles:[CADShape],ruled:Bool=false) async throws ->CADShape {try await operation {c in let pointers=profiles.map{Optional($0.pointer)};return try pointers.withUnsafeBufferPointer {p in try result(c){fcad_loft(c,p.baseAddress,p.count,ruled ? 1:0,$0,$1)}}}}
  public func transform(_ shape:CADShape,rowMajorMatrix:[Double]) async throws ->CADShape {
    guard rowMajorMatrix.count==16 else {throw CADKernelError(.invalidInput,"An affine transform needs exactly 16 row-major numbers.")}
    return try await operation {c in try rowMajorMatrix.withUnsafeBufferPointer {m in try result(c){fcad_transform(c,shape.pointer,m.baseAddress,$0,$1)}}}
  }
  public func translated(_ shape:CADShape,by offset:CADPoint3) async throws ->CADShape {try await transform(shape,rowMajorMatrix:[1,0,0,offset.x,0,1,0,offset.y,0,0,1,offset.z,0,0,0,1])}
  public func compound(_ shapes:[CADShape]) async throws ->CADShape {try await operation {c in let pointers=shapes.map{Optional($0.pointer)};return try pointers.withUnsafeBufferPointer {p in try result(c){fcad_compound(c,p.baseAddress,p.count,$0,$1)}}}}
  public func inspect(_ shape:CADShape) async throws ->CADShapeInfo {try await operation {c in var info=FCADShapeInfo(),failure=FCADFailure();try checked(fcad_info(c,shape.pointer,&info,&failure),failure);return .init(info)}}
  public func faces(_ shape:CADShape) async throws ->[CADFaceInfo] {try await operation {c in try (1...max(1,shape.info.faces)).compactMap {index in guard shape.info.faces>0 else{return nil};var info=FCADFaceInfo(),failure=FCADFailure();try checked(fcad_face_info(c,shape.pointer,UInt32(index),&info,&failure),failure);return CADFaceInfo(info)}}}
  public func edges(_ shape:CADShape) async throws ->[CADEdgeInfo] {try await operation {c in try (1...max(1,shape.info.edges)).compactMap {index in guard shape.info.edges>0 else{return nil};var info=FCADEdgeInfo(),failure=FCADFailure();try checked(fcad_edge_info(c,shape.pointer,UInt32(index),&info,&failure),failure);return CADEdgeInfo(info)}}}
  public func clearance(_ left:CADShape,_ right:CADShape) async throws ->CADClearance {try await operation {c in var distance=0.0,volume=0.0,failure=FCADFailure();try checked(fcad_clearance(c,left.pointer,right.pointer,&distance,&volume,&failure),failure);return .init(distanceMM:distance,interferenceVolumeMM3:volume)}}
  public func tessellate(_ shape:CADShape,quality:CADTessellation = .inspection) async throws ->CADMesh {
    try await operation {c in
      var mesh=FCADMesh(),failure=FCADFailure();defer{fcad_mesh_release(&mesh)}
      try checked(fcad_tessellate(c,shape.pointer,quality.linearDeflectionMM,quality.angularDeflectionRadians,&mesh,&failure),failure)
      let n=Int(mesh.vertex_count),triangles=Int(mesh.triangle_count)
      guard n>0,n<=6_000_000,triangles<=2_000_000,mesh.index_count==triangles*3,let p=mesh.positions,let normal=mesh.normals,let uv=mesh.uvs,let indices=mesh.indices,let faceIndices=mesh.face_indices else {throw CADKernelError(.invalidTopology,"The kernel returned invalid bounded mesh buffers.")}
      return CADMesh(positions:(0..<n).map{.init(p[$0*3],p[$0*3+1],p[$0*3+2])},normals:(0..<n).map{.init(normal[$0*3],normal[$0*3+1],normal[$0*3+2])},textureCoordinates:(0..<n).map{.init(uv[$0*2],uv[$0*2+1])},indices:Array(UnsafeBufferPointer(start:indices,count:triangles*3)),faceIndices:Array(UnsafeBufferPointer(start:faceIndices,count:triangles)))
    }
  }
  public func readBRep(from url:URL) async throws ->CADShape {try await operation {c in try url.path.withCString {path in try result(c){fcad_read_brep(c,path,$0,$1)}}}}
  public func readSTEP(from url:URL,partPath:String,verifiedSourceSHA256:String?=nil) async throws->CADShape {
    let assembly=try await readSTEPAssembly(from:url,verifiedSourceSHA256:verifiedSourceSHA256);guard let part=assembly.parts[partPath] else{throw CADKernelError(.invalidInput,"The STEP occurrence path is unavailable in this pinned source.")};return part
  }
  public func readSTEPAssembly(from url:URL,verifiedSourceSHA256:String?=nil) async throws->CADSTEPAssembly {
    let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);guard values.isRegularFile==true,let size=values.fileSize,size>0,size<=256*1024*1024 else{throw CADKernelError(.limitExceeded,"STEP source must be a regular file up to 256 MiB.")}
    try Task.checkCancellation()
    // Only the feature evaluator supplies this after hashing its immutable stage.
    if let verifiedSourceSHA256,let cached=stepAssemblies[verifiedSourceSHA256]{stepAssemblyOrder.removeAll{$0==verifiedSourceSHA256};stepAssemblyOrder.append(verifiedSourceSHA256);return cached}
    let sourceHash=SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
    if let verifiedSourceSHA256,verifiedSourceSHA256 != sourceHash{throw CADKernelError(.invalidInput,"STEP source changed after its pinned digest was verified.")}
    if let cached=stepAssemblies[sourceHash]{stepAssemblyOrder.removeAll{$0==sourceHash};stepAssemblyOrder.append(sourceHash);return cached}
    let assembly:CADSTEPAssembly=try await operation{context in
      var document:OpaquePointer?,failure=FCADFailure();let status=url.path.withCString{fcad_read_step_document(context,$0,&document,&failure)};try checked(status,failure)
      guard let document else{throw CADKernelError(.operationFailed,"The STEP assembly transfer returned no document.")};defer{fcad_step_document_release(document)}
      func text<T>(_ raw:T)->String{withUnsafeBytes(of:raw){String(cString:$0.baseAddress!.assumingMemoryBound(to:CChar.self))}}
      func doubles<T>(_ raw:T)->[Double]{withUnsafeBytes(of:raw){Array($0.bindMemory(to:Double.self))}}
      let count=fcad_step_node_count(document);guard count>0,count<=4096 else{throw CADKernelError(.limitExceeded,"STEP assembly exceeds bounded occurrence count.")}
      var nodes:[CADSTEPOccurrence]=[],parts:[String:CADShape]=[:]
      for index in 0..<count {
        var raw=FCADSTEPNodeInfo();try checked(fcad_step_node_info(context,document,index,&raw,&failure),failure)
        let path=text(raw.path),name=text(raw.name),definitionKey=text(raw.definition_key)
        var colors=[FCADFaceColor](repeating:FCADFaceColor(),count:Int(raw.face_color_count))
        try colors.withUnsafeMutableBufferPointer{try checked(fcad_step_face_colors(context,document,index,$0.baseAddress,$0.count,&failure),failure)}
        let colorMap=colors.map{CADSTEPFaceColor(faceIndex:$0.face_index,rgba:doubles($0.rgba))}
        nodes.append(.init(path:path,definitionKey:definitionKey,name:name,parentIndex:raw.parent_index<0 ? nil:Int(raw.parent_index),assembly:raw.is_assembly != 0,localTransformMM:doubles(raw.local_transform),worldTransformMM:doubles(raw.world_transform),linearRGBA:raw.has_color != 0 ? doubles(raw.color_rgba):nil,faceColors:colorMap))
        if raw.is_assembly==0{parts[path]=try path.withCString{path in try result(context){fcad_step_part(context,document,path,$0,$1)}}}
      }
      return .init(sourceSHA256:sourceHash,kernelVersion:Self.version,nodes:nodes,parts:parts)
    }
    try Task.checkCancellation()
    let finalHash=SHA256.hash(data:try Data(contentsOf:url,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined();guard finalHash==sourceHash else{throw CADKernelError(.invalidInput,"The STEP file changed during its assembly transfer. Import a stable source revision.")}
    if assembly.estimatedBytes<=64*1024*1024{while stepAssemblyBytes+assembly.estimatedBytes>64*1024*1024 || stepAssemblyOrder.count>=4{guard let key=stepAssemblyOrder.first else{break};stepAssemblyOrder.removeFirst();if let old=stepAssemblies.removeValue(forKey:key){stepAssemblyBytes-=old.estimatedBytes}};stepAssemblies[sourceHash]=assembly;stepAssemblyOrder.append(sourceHash);stepAssemblyBytes+=assembly.estimatedBytes}
    return assembly
  }
  public func readSTEP(from url:URL) async throws ->CADShape {try await operation {c in try url.path.withCString {path in try result(c){fcad_read_step(c,path,$0,$1)}}}}
  public func writeBRep(_ shape:CADShape,to url:URL) async throws {try await write(shape,to:url,step:false)}
  public func writeSTEP(_ shape:CADShape,to url:URL) async throws {try await write(shape,to:url,step:true)}
  private func write(_ shape:CADShape,to destination:URL,step:Bool) async throws {
    try await operation {c in
      guard destination.isFileURL,!FileManager.default.fileExists(atPath:destination.path) else {throw CADKernelError(.ioFailed,"Choose a new local CAD destination; existing files are preserved.")}
      let stage=destination.deletingLastPathComponent().appendingPathComponent(".lab-cad-\(UUID().uuidString)."+(step ? "step":"brep"))
      defer{try? FileManager.default.removeItem(at:stage)}
      var failure=FCADFailure();let status=stage.path.withCString {step ? fcad_write_step(c,shape.pointer,$0,&failure):fcad_write_brep(c,shape.pointer,$0,&failure)}
      try checked(status,failure);try Task.checkCancellation()
      try FileManager.default.moveItem(at:stage,to:destination)
    }
  }
}
