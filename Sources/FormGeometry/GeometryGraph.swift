import AppKit
import Foundation
import simd

/// A CPU construction graph, independent of any view or GPU API. Legacy recipes
/// use their historical construction coordinates; adapters explicitly normalize
/// them to Double millimeters. CAD and imported authoritative data stay in mm.
public struct MeshVector3: Equatable, Sendable {
  public var x: Double, y: Double, z: Double
  public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {self.x=x;self.y=y;self.z=z}
  public init<T: BinaryFloatingPoint>(_ x: T, _ y: T, _ z: T) {self.init(Double(x),Double(y),Double(z))}
  public var simd: SIMD3<Double> {.init(x,y,z)}
  public init(_ v: SIMD3<Double>) {self.init(v.x,v.y,v.z)}
}
public let MeshVector3Zero = MeshVector3()
public struct MeshMatrix4: Sendable {
  public var raw: simd_double4x4
  public init(_ raw: simd_double4x4 = matrix_identity_double4x4) {self.raw=raw}
  public init(m11:Double,m12:Double,m13:Double,m14:Double,m21:Double,m22:Double,m23:Double,m24:Double,m31:Double,m32:Double,m33:Double,m34:Double,m41:Double,m42:Double,m43:Double,m44:Double) {raw = .init(.init(m11,m12,m13,m14),.init(m21,m22,m23,m24),.init(m31,m32,m33,m34),.init(m41,m42,m43,m44))}
  public var m11:Double {get{raw[0,0]}set{raw[0,0]=newValue}};public var m12:Double {get{raw[0,1]}set{raw[0,1]=newValue}};public var m13:Double {get{raw[0,2]}set{raw[0,2]=newValue}};public var m14:Double {get{raw[0,3]}set{raw[0,3]=newValue}}
  public var m21:Double {get{raw[1,0]}set{raw[1,0]=newValue}};public var m22:Double {get{raw[1,1]}set{raw[1,1]=newValue}};public var m23:Double {get{raw[1,2]}set{raw[1,2]=newValue}};public var m24:Double {get{raw[1,3]}set{raw[1,3]=newValue}}
  public var m31:Double {get{raw[2,0]}set{raw[2,0]=newValue}};public var m32:Double {get{raw[2,1]}set{raw[2,1]=newValue}};public var m33:Double {get{raw[2,2]}set{raw[2,2]=newValue}};public var m34:Double {get{raw[2,3]}set{raw[2,3]=newValue}}
  public var m41:Double {get{raw[3,0]}set{raw[3,0]=newValue}};public var m42:Double {get{raw[3,1]}set{raw[3,1]=newValue}};public var m43:Double {get{raw[3,2]}set{raw[3,2]=newValue}};public var m44:Double {get{raw[3,3]}set{raw[3,3]=newValue}}
}
public let MeshMatrix4Identity = MeshMatrix4()
public enum MeshWrapMode {case clamp,`repeat`,mirror}
public enum MeshTextureFilter {case none,nearest,linear}
public final class MeshMaterialProperty {
  public let resourceID=UUID()
  public private(set) var resourceRevision:UInt64=0
  public var contents:Any? {didSet{resourceRevision &+= 1}}
  public var contentsTransform=MeshMatrix4Identity {didSet{resourceRevision &+= 1}}
  public var intensity=1.0,maxAnisotropy=1.0
  public var wrapS:MeshWrapMode = .clamp,wrapT:MeshWrapMode = .clamp
  public var mipFilter:MeshTextureFilter = .linear,minificationFilter:MeshTextureFilter = .linear,magnificationFilter:MeshTextureFilter = .linear
  public init(){}
  func clone()->MeshMaterialProperty {let p=MeshMaterialProperty();p.contents=contents;p.contentsTransform=contentsTransform;p.intensity=intensity;p.maxAnisotropy=maxAnisotropy;p.wrapS=wrapS;p.wrapT=wrapT;p.mipFilter=mipFilter;p.minificationFilter=minificationFilter;p.magnificationFilter=magnificationFilter;return p}
}
public final class MeshMaterial:NSObject,NSCopying {
  public enum LightingModel {case physicallyBased,constant}
  public enum TransparencyMode {case aOne,dualLayer,singleLayer}
  public var name:String?
  public var lightingModel:LightingModel = .physicallyBased
  public var transparencyMode:TransparencyMode = .aOne
  public var diffuse=MeshMaterialProperty(),normal=MeshMaterialProperty(),roughness=MeshMaterialProperty(),metalness=MeshMaterialProperty(),emission=MeshMaterialProperty(),transparent=MeshMaterialProperty()
  public var isDoubleSided=false,readsFromDepthBuffer=true,writesToDepthBuffer=true
  public var transparency=1.0
  public override init(){super.init()}
  public func copy(with zone:NSZone?=nil)->Any {let m=MeshMaterial();m.name=name;m.lightingModel=lightingModel;m.transparencyMode=transparencyMode;m.diffuse=diffuse.clone();m.normal=normal.clone();m.roughness=roughness.clone();m.metalness=metalness.clone();m.emission=emission.clone();m.transparent=transparent.clone();m.isDoubleSided=isDoubleSided;m.readsFromDepthBuffer=readsFromDepthBuffer;m.writesToDepthBuffer=writesToDepthBuffer;m.transparency=transparency;return m}
}
public final class MeshGeometrySource:NSObject {
  public enum Semantic {case vertex,normal,texcoord}
  public let semantic:Semantic,data:Data,vectorCount:Int,componentsPerVector:Int
  public let usesFloatComponents=true,bytesPerComponent=8,dataOffset=0
  public var dataStride:Int {componentsPerVector*bytesPerComponent}
  public init(values:[Double],components:Int,semantic:Semantic) {self.semantic=semantic;componentsPerVector=components;vectorCount=values.count/components;data=values.withUnsafeBufferPointer{Data(buffer:$0)};super.init()}
  public convenience init(vertices:[MeshVector3]) {self.init(values:vertices.flatMap{[$0.x,$0.y,$0.z]},components:3,semantic:.vertex)}
  public convenience init(normals:[MeshVector3]) {self.init(values:normals.flatMap{[$0.x,$0.y,$0.z]},components:3,semantic:.normal)}
  public convenience init(textureCoordinates:[CGPoint]) {self.init(values:textureCoordinates.flatMap{[Double($0.x),Double($0.y)]},components:2,semantic:.texcoord)}
  public var vectors:[MeshVector3] {guard componentsPerVector>=3 else{return []};return data.withUnsafeBytes{b in (0..<vectorCount).map{i in let p=i*dataStride;return .init(b.loadUnaligned(fromByteOffset:p,as:Double.self),b.loadUnaligned(fromByteOffset:p+8,as:Double.self),b.loadUnaligned(fromByteOffset:p+16,as:Double.self))}}}
  public var points:[CGPoint] {guard componentsPerVector==2 else{return []};return data.withUnsafeBytes{b in (0..<vectorCount).map{i in .init(x:b.loadUnaligned(fromByteOffset:i*16,as:Double.self),y:b.loadUnaligned(fromByteOffset:i*16+8,as:Double.self))}}}
}
public final class MeshGeometryElement:NSObject {
  public enum PrimitiveType {case triangles,triangleStrip,line,point}
  public let data:Data,primitiveType:PrimitiveType,bytesPerIndex=4
  public var primitiveCount:Int {let n=data.count/4;switch primitiveType{case .triangles:return n/3;case .triangleStrip:return max(0,n-2);case .line:return n/2;case .point:return n}}
  public init(indices:[Int32],primitiveType:PrimitiveType) {self.data=indices.withUnsafeBufferPointer{Data(buffer:$0)};self.primitiveType=primitiveType;super.init()}
  public convenience init(indices:[UInt32],primitiveType:PrimitiveType) {self.init(indices:indices.map{Int32(bitPattern:$0)},primitiveType:primitiveType)}
  public var indices:[UInt32] {data.withUnsafeBytes{b in (0..<data.count/4).map{b.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self)}}}
}
open class MeshGeometry:NSObject,NSCopying {
  /// A renderer cache can outlive this object. Memory addresses can be recycled
  /// for unrelated buffers, so resource identity must survive that reuse safely.
  public let resourceID=UUID()
  private var storedSources:[MeshGeometrySource],storedElements:[MeshGeometryElement]
  public private(set) var resourceRevision:UInt64=0
  public var materials:[MeshMaterial]=[]
  public var name:String?
  public init(sources:[MeshGeometrySource]=[],elements:[MeshGeometryElement]=[]) {storedSources=sources;storedElements=elements;super.init()}
  open func prepare(){}
  public func replace(sources:[MeshGeometrySource],elements:[MeshGeometryElement]) {storedSources=sources;storedElements=elements;resourceRevision &+= 1}
  public func sources(for semantic:MeshGeometrySource.Semantic)->[MeshGeometrySource] {prepare();return storedSources.filter{$0.semantic==semantic}}
  public var sources:[MeshGeometrySource] {prepare();return storedSources}
  public var elements:[MeshGeometryElement] {prepare();return storedElements}
  public var firstMaterial:MeshMaterial? {get{materials.first}set{if let newValue{if materials.isEmpty{materials=[newValue]}else{materials[0]=newValue}}else{materials=[]}}}
  public var boundingBox:(min:MeshVector3,max:MeshVector3) {let v=sources(for:.vertex).flatMap(\.vectors);guard let first=v.first else{return(.init(),.init())};var lo=first.simd,hi=lo;for p in v.dropFirst(){lo=simd_min(lo,p.simd);hi=simd_max(hi,p.simd)};return(.init(lo),.init(hi))}
  public func copy(with zone:NSZone?=nil)->Any {let g=MeshGeometry(sources:sources,elements:elements);g.name=name;g.materials=materials.map{$0.copy() as! MeshMaterial};return g}
}
public final class MeshCamera:NSObject,NSCopying {
  public enum ProjectionDirection {case vertical,horizontal}
  public var fieldOfView=39.0,zNear=0.01,zFar=1500.0,orthographicScale=1.0
  public var usesOrthographicProjection=false,wantsHDR=true,wantsExposureAdaptation=false
  public var projectionDirection:ProjectionDirection = .vertical
  public var exposureOffset=0.0,averageGray=0.18,bloomIntensity=0.0
  private var explicitProjection:MeshMatrix4?
  public var projectionTransform:MeshMatrix4 {get{explicitProjection ?? projectionTransform(withViewportSize:.init(width:1,height:1))}set{explicitProjection=newValue}}
  public func projectionTransform(withViewportSize size:CGSize)->MeshMatrix4 {
    let aspect=Double(size.width/max(1,size.height)),near=zNear,far=zFar
    if usesOrthographicProjection {let h=orthographicScale,w=h*aspect;return .init(.init(.init(1/w,0,0,0),.init(0,1/h,0,0),.init(0,0,1/(near-far),0),.init(0,0,near/(near-far),1)))}
    let s=1/tan(fieldOfView * .pi/360),x=projectionDirection == .vertical ? s/aspect:s,y=projectionDirection == .vertical ? s:s*aspect
    return .init(.init(.init(x,0,0,0),.init(0,y,0,0),.init(0,0,far/(near-far),-1),.init(0,0,far*near/(near-far),0)))
  }
  public func removeAllAnimations(){}
  public func copy(with zone:NSZone?=nil)->Any {let c=MeshCamera();c.fieldOfView=fieldOfView;c.zNear=zNear;c.zFar=zFar;c.orthographicScale=orthographicScale;c.usesOrthographicProjection=usesOrthographicProjection;c.projectionDirection=projectionDirection;c.exposureOffset=exposureOffset;c.explicitProjection=explicitProjection;return c}
}
public final class MeshLight {
  public enum Kind {case ambient,directional,omni}
  public enum ShadowMode {case forward}
  public var type:Kind = .ambient
  public var intensity=0.0,color:Any=NSColor.white,castsShadow=false,shadowMode:ShadowMode = .forward,shadowRadius=0.0,shadowSampleCount=1,shadowMapSize=CGSize(width:1024,height:1024),shadowColor:Any=NSColor.black,orthographicScale=1.0,zNear=0.1,zFar=80.0
  public init(){}
}
public final class MeshNode:NSObject {
  public var name:String?,geometry:MeshGeometry?,camera:MeshCamera?,light:MeshLight?
  public var isHidden=false,castsShadow=true,categoryBitMask=1,renderingOrder=0,opacity=1.0
  public private(set) weak var parent:MeshNode?
  public private(set) var childNodes:[MeshNode]=[]
  private var matrix=matrix_identity_double4x4,euler=MeshVector3()
  public init(geometry:MeshGeometry?=nil) {self.geometry=geometry;super.init()}
  public var transform:MeshMatrix4 {get{.init(matrix)}set{matrix=newValue.raw}}
  public var simdTransform:simd_float4x4 {get{simd_float4x4(columns:(SIMD4<Float>(matrix.columns.0),SIMD4<Float>(matrix.columns.1),SIMD4<Float>(matrix.columns.2),SIMD4<Float>(matrix.columns.3)))}set{matrix=simd_double4x4(columns:(SIMD4<Double>(newValue.columns.0),SIMD4<Double>(newValue.columns.1),SIMD4<Double>(newValue.columns.2),SIMD4<Double>(newValue.columns.3)))}}
  public var position:MeshVector3 {get{.init(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z)}set{matrix.columns.3 = .init(newValue.x,newValue.y,newValue.z,1)}}
  public var simdPosition:SIMD3<Float> {get{SIMD3<Float>(position.simd)}set{position = .init(SIMD3<Double>(newValue))}}
  public var eulerAngles:MeshVector3 {get{euler}set{euler=newValue;let q=simd_quatd(angle:newValue.z,axis:.init(0,0,1))*simd_quatd(angle:newValue.y,axis:.init(0,1,0))*simd_quatd(angle:newValue.x,axis:.init(1,0,0));setRotation(q)}}
  public var simdOrientation:simd_quatf {
    get {let q=simd_quatd(simd_double3x3(columns:(SIMD3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),SIMD3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),SIMD3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z))));return simd_quatf(vector:SIMD4<Float>(q.vector))}
    set {setRotation(simd_quatd(vector:SIMD4<Double>(newValue.vector)))}
  }
  private func setRotation(_ q:simd_quatd) {let p=matrix.columns.3;matrix=simd_double4x4(q);matrix.columns.3=p}
  public var worldTransform:MeshMatrix4 { .init((parent?.worldTransform.raw ?? matrix_identity_double4x4)*matrix) }
  public var worldPosition:MeshVector3 {.init(worldTransform.raw.columns.3.x,worldTransform.raw.columns.3.y,worldTransform.raw.columns.3.z)}
  public func addChildNode(_ node:MeshNode){node.removeFromParentNode();node.parent=self;childNodes.append(node)}
  public func removeFromParentNode(){parent?.childNodes.removeAll{$0 === self};parent=nil}
  public func childNode(withName name:String,recursively:Bool)->MeshNode? {for child in childNodes {if child.name==name{return child};if recursively,let found=child.childNode(withName:name,recursively:true){return found}};return nil}
  public func enumerateChildNodes(_ block:(MeshNode,UnsafeMutablePointer<ObjCBool>)->Void){var stop=ObjCBool(false);func visit(_ node:MeshNode){for child in Array(node.childNodes){block(child,&stop);if stop.boolValue{return};visit(child);if stop.boolValue{return}}};visit(self)}
  public func clone()->MeshNode {let n=MeshNode(geometry:geometry);n.name=name;n.camera=camera?.copy() as? MeshCamera;n.light=light;n.isHidden=isHidden;n.castsShadow=castsShadow;n.categoryBitMask=categoryBitMask;n.renderingOrder=renderingOrder;n.opacity=opacity;n.matrix=matrix;n.euler=euler;for child in childNodes{n.addChildNode(child.clone())};return n}
  public func flattenedClone()->MeshNode {clone()}
  public func convertPosition(_ p:MeshVector3,to node:MeshNode?)->MeshVector3 {let m=(node?.worldTransform.raw.inverse ?? matrix_identity_double4x4)*worldTransform.raw,q=m*SIMD4(p.simd,1);return .init(q.x/q.w,q.y/q.w,q.z/q.w)}
  public func convertPosition(_ p:MeshVector3,from node:MeshNode?)->MeshVector3 {let m=worldTransform.raw.inverse*(node?.worldTransform.raw ?? matrix_identity_double4x4),q=m*SIMD4(p.simd,1);return .init(q.x/q.w,q.y/q.w,q.z/q.w)}
  public var boundingBox:(min:MeshVector3,max:MeshVector3) {
    var points=geometry?.sources(for:.vertex).flatMap(\.vectors) ?? []
    for child in childNodes {if child.geometry==nil && child.childNodes.isEmpty{continue};let b=child.boundingBox;for x in [b.min.x,b.max.x]{for y in [b.min.y,b.max.y]{for z in [b.min.z,b.max.z]{let q=child.matrix*SIMD4(x,y,z,1);points.append(.init(q.x,q.y,q.z))}}}}
    guard let p=points.first else{return(.init(),.init())};var lo=p.simd,hi=lo;for p in points.dropFirst(){lo=simd_min(lo,p.simd);hi=simd_max(hi,p.simd)};return(.init(lo),.init(hi))
  }
  public func look(at target:MeshVector3){let eye=worldPosition.simd,z=simd_normalize(eye-target.simd),up=abs(z.y)>0.999 ? SIMD3<Double>(0,0,1):SIMD3<Double>(0,1,0),x=simd_normalize(simd_cross(up,z)),y=simd_cross(z,x);let p=position;matrix = .init(SIMD4(x,0),SIMD4(y,0),SIMD4(z,0),SIMD4(p.simd,1))}
  public func removeAllAnimations(){}
}
public final class MeshScene {
  public let rootNode=MeshNode(),background=MeshMaterialProperty(),lightingEnvironment=MeshMaterialProperty()
  public init(){}
}
