import Foundation
import simd

public struct PatternPanelID:Codable,Equatable,Hashable,Sendable,Comparable {
  public var elementID:UUID
  public var copy:Int
  public init(elementID:UUID,copy:Int) {self.elementID=elementID;self.copy=copy}
  public var key:String {"\(elementID.uuidString):\(copy)"}
  public static func <(a:Self,b:Self)->Bool {a.key<b.key}
}
/// An explicit isometry from panel material millimeters into initial3D space.
/// materialFront selects winding only, never a hidden scale/reflection of cloth.
public struct PatternPanelPose:Codable,Equatable,Sendable {
  public var originMm:Vector3
  public var uAxis:Vector3
  public var vAxis:Vector3
  public var materialFront:Int
  public init(originMm:Vector3 = .init(),uAxis:Vector3 = .init(1,0,0),vAxis:Vector3 = .init(0,-1,0),materialFront:Int = -1) {self.originMm=originMm;self.uAxis=uAxis;self.vAxis=vAxis;self.materialFront=materialFront}
  public func validate()throws {
    let u=ClothMath.vector(uAxis),v=ClothMath.vector(vAxis)
    guard ClothMath.finite(originMm),ClothMath.maximum(originMm)<=100000,ClothMath.finite(uAxis),ClothMath.finite(vAxis),abs(simd_length(u)-1)<1e-8,abs(simd_length(v)-1)<1e-8,abs(simd_dot(u,v))<1e-8,[-1,1].contains(materialFront) else {throw FormError.invalid("Assembly panel poses need finite bounded origins and orthonormal material axes; scale belongs in the source pattern.")}
  }
  public func point(_ point:Point2)->Vector3 {ClothMath.point(ClothMath.vector(originMm)+ClothMath.vector(uAxis)*point.x+ClothMath.vector(vAxis)*point.y)}
}
public struct PatternPanelPlacement:Codable,Equatable,Sendable {
  public var panel:PatternPanelID
  public var pose:PatternPanelPose
  /// Portable assignment snapshot, independent of later Studio inventory edits.
  public var material:Material
  public var densityGSM:Double
  public var textureOriginMm:Point2
  public init(panel:PatternPanelID,pose:PatternPanelPose,material:Material,densityGSM:Double,textureOriginMm:Point2 = .init()) {self.panel=panel;self.pose=pose;self.material=material;self.densityGSM=densityGSM;self.textureOriginMm=textureOriginMm}
}
public struct PatternAssemblyPin:Codable,Equatable,Sendable {
  public var panel:PatternPanelID
  public var edgeID:UUID
  public var endID:UUID
  public var fraction:Double
  public var targetMm:Vector3?
  public init(panel:PatternPanelID,edgeID:UUID,endID:UUID,fraction:Double,targetMm:Vector3? = nil) {self.panel=panel;self.edgeID=edgeID;self.endID=endID;self.fraction=fraction;self.targetMm=targetMm}
}
/// Source/provenance only. A generated mesh is derived and is not an additional
/// editable document source. Persisting this declaration requires schema36.
public struct PatternAssemblyDefinition:Codable,Equatable,Sendable {
  public var sourceObjectID:UUID
  public var panels:[PatternPanelPlacement]
  public var seamIDs:[UUID]
  public var pins:[PatternAssemblyPin]
  public var maximumEdgeMm:Double
  public var boundaryToleranceMm:Double
  public var maximumVertices:Int
  public var maximumMeshingOperations:Int
  public var settings:ClothSettings
  public var colliders:[ClothCollider]
  public var preparation:ClothAssemblyPreparation?
  public init(sourceObjectID:UUID,panels:[PatternPanelPlacement],seamIDs:[UUID],pins:[PatternAssemblyPin] = [],maximumEdgeMm:Double = 20) {
    self.sourceObjectID=sourceObjectID;self.panels=panels;self.seamIDs=seamIDs;self.pins=pins;self.maximumEdgeMm=maximumEdgeMm
    boundaryToleranceMm=0.02;maximumVertices=ClothMesh.maximumVertices;maximumMeshingOperations=16_000_000;settings = .init();colliders=[];preparation = .init()
  }
  public func validateDeclarations()throws {
    guard (1...8).contains(panels.count),Set(panels.map(\.panel)).count==panels.count,seamIDs.count<=128,Set(seamIDs).count==seamIDs.count,pins.count<=128,
      maximumEdgeMm.isFinite,(4...100).contains(maximumEdgeMm),boundaryToleranceMm.isFinite,(0.005...0.05).contains(boundaryToleranceMm),(3...ClothMesh.maximumVertices).contains(maximumVertices),(1000...AssemblyMesher.maximumOperations).contains(maximumMeshingOperations),colliders.count<=16 else {throw FormError.invalid("Assembly supports 1–8 distinct piece copies, up to 128 seams/pins, declared 4–100 mm spacing and bounded meshing work.")}
    for panel in panels {
      try panel.pose.validate();try validateColor(panel.material.color);try panel.material.fabric?.validate()
      guard (1...100).contains(panel.panel.copy),panel.material.category=="Fabric",!panel.material.id.isEmpty,panel.material.id.utf8.count<=160,panel.material.name.utf8.count<=300,panel.material.roughness.isFinite,(0...1).contains(panel.material.roughness),panel.material.metallic.isFinite,(0...1).contains(panel.material.metallic),panel.material.thickness.isFinite,(0...100).contains(panel.material.thickness),panel.densityGSM.isFinite,(10...5000).contains(panel.densityGSM),panel.textureOriginMm.x.isFinite,panel.textureOriginMm.y.isFinite,max(abs(panel.textureOriginMm.x),abs(panel.textureOriginMm.y))<=100000 else {throw FormError.invalid("Each assembly panel needs a declared fabric snapshot, positive 10–5000 GSM mass and finite physical texture origin.")}
    }
    let ids=Set(panels.map(\.panel))
    for pin in pins {guard ids.contains(pin.panel),pin.fraction.isFinite,(0...1).contains(pin.fraction),pin.targetMm.map({ClothMath.finite($0) && ClothMath.maximum($0)<=100000}) ?? true else {throw FormError.invalid("Pin an existing assembly panel at a guarded source-edge arc fraction and optional bounded target.")}}
    try settings.validate();try preparation?.validate();for collider in colliders {try collider.validate()}
  }
}

public struct PatternAssemblyPanel:Codable,Equatable,Sendable {
  public var id:PatternPanelID
  public var panelIndex:Int
  public var name:String
  public var sourceOriginMm:Point2
  public var materialSizeMm:Point2
  public var material:Material
  public var densityGSM:Double
  public var textureOriginMm:Point2
  public var vertexIndices:[Int]
  public var sourceAreaMm2:Double
  public var meshAreaMm2:Double
}
public struct PatternAssemblySeamSample:Codable,Equatable,Sendable {
  public var seamID:UUID
  public var firstEdgeID:UUID
  public var secondEdgeID:UUID
  public var firstFraction:Double
  public var secondFraction:Double
  public var firstDistanceMm:Double
  public var secondDistanceMm:Double
  public var firstVertex:Int
  public var secondVertex:Int
}
public struct PatternAssemblyProduct:Sendable {
  public var study:ClothStudy
  public var panels:[PatternAssemblyPanel]
  public var materialPointsMm:[Point2]
  public var seamSamples:[PatternAssemblySeamSample]
  public var sourceDigest:String
  public var definitionDigest:String
  public var operations:Int
  public var sourceAreaErrorBoundMm2:Double
}


struct AssemblyBuildBudget {
  var used=0
  var limit:Int
  mutating func charge(_ count:Int = 1)throws {
    guard count>=0,used<=limit-count else {throw FormError.invalid("Assembly source sampling/meshing exceeded its declared work budget. Simplify the source, increase spacing, or select fewer panels.")};used+=count
  }
  var remaining:Int {limit-used}
}
