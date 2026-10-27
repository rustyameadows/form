import Foundation
import FormCADModel
import FormCADKernel

/// Form-owned derived mesh format. No OCCT/native pointer is serialized.
public enum CADMeshArchive {
  private static let magic=Data("LABCADM1".utf8)
  public static func encode(_ mesh:CADMesh)throws->Data {
    let n=mesh.positions.count,t=mesh.triangleCount
    guard n>0,n<=6_000_000,t>0,t<=2_000_000,mesh.normals.count==n,mesh.textureCoordinates.count==n,mesh.indices.count==t*3,mesh.faceIndices.count==t,mesh.indices.allSatisfy({$0<n}),mesh.faceIndices.allSatisfy({$0>0&&$0<=100000}) else{throw CADModelError("Invalid bounded CAD mesh buffers.")}
    var data=magic
    func u32(_ value:UInt32){var value=value.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
    func f64(_ value:Double)throws{guard value.isFinite,abs(value)<=1e7 else{throw CADModelError("CAD mesh contains invalid physical coordinates or normals.")};var value=value.bitPattern.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
    data.reserveCapacity(24+n*64+t*16);u32(1);u32(UInt32(n));u32(UInt32(mesh.indices.count));u32(UInt32(t))
    for p in mesh.positions{try f64(p.x);try f64(p.y);try f64(p.z)}
    for p in mesh.normals{try f64(p.x);try f64(p.y);try f64(p.z)}
    for p in mesh.textureCoordinates{try f64(p.x);try f64(p.y)}
    for index in mesh.indices{u32(index)};for face in mesh.faceIndices{u32(face)};return data
  }
  public static func decode(_ data:Data)throws->CADMesh {
    guard data.count>=24,data.count<=512*1024*1024,data.prefix(8)==magic else{throw CADModelError("Not a bounded LAB CAD derived mesh archive.")}
    var offset=8
    func u32()->UInt32{defer{offset+=4};return data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self).littleEndian}}
    func f64()throws->Double{defer{offset+=8};let value=Double(bitPattern:data.withUnsafeBytes{$0.loadUnaligned(fromByteOffset:offset,as:UInt64.self).littleEndian});guard value.isFinite,abs(value)<=1e7 else{throw CADModelError("Invalid CAD mesh coordinate.")};return value}
    let version=u32(),n=Int(u32()),i=Int(u32()),t=Int(u32())
    guard version==1,n>0,n<=6_000_000,t>0,t<=2_000_000,i==t*3,data.count==24+n*64+t*16 else{throw CADModelError("CAD mesh archive version, counts or byte length are invalid.")}
    var positions:[CADPoint3]=[],normals:[CADPoint3]=[],uvs:[CADPoint2]=[];positions.reserveCapacity(n);normals.reserveCapacity(n);uvs.reserveCapacity(n)
    for _ in 0..<n{positions.append(.init(try f64(),try f64(),try f64()))};for _ in 0..<n{normals.append(.init(try f64(),try f64(),try f64()))};for _ in 0..<n{uvs.append(.init(try f64(),try f64()))}
    let indices=(0..<i).map{_ in u32()},faces=(0..<t).map{_ in u32()}
    guard indices.allSatisfy({$0<n}),faces.allSatisfy({$0>0&&$0<=100000}) else{throw CADModelError("CAD mesh indices reference unavailable vertices or faces.")}
    return .init(positions:positions,normals:normals,textureCoordinates:uvs,indices:indices,faceIndices:faces)
  }
}
