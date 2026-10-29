import Foundation
import CryptoKit
import FormCADModel

/// Portable references to immutable exact/derived resources. Geometry kernel
/// handles and renderer entities never enter the product/document graph.
public struct CADComponentRepresentation:Codable,Equatable,Identifiable,Sendable {
  public var id:UUID
  public var name:String
  public var materialID:String?
  public var color:String?
  public var featureFingerprint:String?
  public var brepAsset:String,brepSHA256:String,meshAsset:String,meshSHA256:String
  public var minimum:Vector3,maximum:Vector3
  public var volumeMM3:Double
  public var valid:Bool,closed:Bool
  public var solidCount:Int,faceCount:Int,edgeCount:Int,vertexCount:Int,triangleCount:Int
  public init(id:UUID,name:String,brepAsset:String,brepSHA256:String,meshAsset:String,meshSHA256:String,minimum:Vector3,maximum:Vector3,volumeMM3:Double,valid:Bool,closed:Bool,solidCount:Int,faceCount:Int,edgeCount:Int,vertexCount:Int,triangleCount:Int){self.id=id;self.name=name;self.brepAsset=brepAsset;self.brepSHA256=brepSHA256;self.meshAsset=meshAsset;self.meshSHA256=meshSHA256;self.minimum=minimum;self.maximum=maximum;self.volumeMM3=volumeMM3;self.valid=valid;self.closed=closed;self.solidCount=solidCount;self.faceCount=faceCount;self.edgeCount=edgeCount;self.vertexCount=vertexCount;self.triangleCount=triangleCount}
}
public struct CADRepresentation:Codable,Equatable,Sendable {
  public var resolvedSurfaces:[CADResolvedPlanarSurface]?
  public var modelID:UUID
  public var definitionSHA256:String
  public var kernelVersion:String
  public var editability:String
  public var components:[CADComponentRepresentation]
  public var meshDeflectionMM:Double
  public init(modelID:UUID,definitionSHA256:String,kernelVersion:String,editability:String="nativeFeatureModel",components:[CADComponentRepresentation],meshDeflectionMM:Double=0.05){self.modelID=modelID;self.definitionSHA256=definitionSHA256;self.kernelVersion=kernelVersion;self.editability=editability;self.components=components;self.meshDeflectionMM=meshDeflectionMM}
  public var minimum:Vector3 {.init(components.map(\.minimum.x).min() ?? 0,components.map(\.minimum.y).min() ?? 0,components.map(\.minimum.z).min() ?? 0)}
  public var maximum:Vector3 {.init(components.map(\.maximum.x).max() ?? 0,components.map(\.maximum.y).max() ?? 0,components.map(\.maximum.z).max() ?? 0)}
  public static func definitionHash(_ definition:CADModelDefinition)throws->String {try definition.sourceFingerprint()}
  public func validate(for model:CADModelDefinition)throws {
    _=try model.validatedOrder()
    guard modelID==model.id,definitionSHA256 == (try Self.definitionHash(model)),!kernelVersion.isEmpty,kernelVersion.utf8.count<=64,["nativeFeatureModel","importedCADBody"].contains(editability),!components.isEmpty,components.count<=256,Set(components.map(\.id))==Set(model.outputs),Set(components.map(\.id)).count==components.count,meshDeflectionMM.isFinite,meshDeflectionMM>0,meshDeflectionMM<=5 else{throw FormError.invalid("Exact CAD source, outputs or revision metadata do not match the feature model.")}
    func file(_ s:String)->Bool {!s.isEmpty && s.utf8.count<=255 && s==URL(fileURLWithPath:s).lastPathComponent && !s.contains("\\") && !s.contains("\0") && s != "." && s != ".."}
    func digest(_ s:String)->Bool {s.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
    for c in components {
      guard c.featureFingerprint == nil || digest(c.featureFingerprint!) else{throw FormError.invalid("CAD feature topology needs its exact revision fingerprint.")}
      guard c.materialID == nil || (!c.materialID!.isEmpty && c.materialID!.utf8.count<=160),c.color == nil || c.color!.range(of:"^#[0-9A-Fa-f]{6}$",options:.regularExpression) != nil else{throw FormError.invalid("Use a bounded material identity and RGB color for CAD appearance.")}
      guard file(c.brepAsset),file(c.meshAsset),c.brepAsset != c.meshAsset,digest(c.brepSHA256),digest(c.meshSHA256),c.name.utf8.count<=256,c.valid,c.closed,c.solidCount>0,c.solidCount<=10000,c.faceCount>0,c.edgeCount>0,c.vertexCount>0,c.vertexCount<=6_000_000,c.triangleCount>0,c.triangleCount<=2_000_000,c.volumeMM3.isFinite,c.volumeMM3>0,
        [c.minimum.x,c.minimum.y,c.minimum.z,c.maximum.x,c.maximum.y,c.maximum.z].allSatisfy({$0.isFinite && abs($0)<=1e7}),c.minimum.x<=c.maximum.x,c.minimum.y<=c.maximum.y,c.minimum.z<=c.maximum.z else{throw FormError.invalid("CAD output must reference bounded immutable resources and validated closed solid geometry.")}
    }
    if let surfaces=resolvedSurfaces {
      guard surfaces.count<=128,Set(surfaces.map(\.id)).count==surfaces.count else {throw FormError.invalid("Named CAD surface identities must be unique and bounded.")}
      for surface in surfaces {
        try surface.validate()
        guard let component=components.first(where:{$0.id==surface.outputFeatureID}),component.featureFingerprint==surface.fingerprint,
          surface.faceIndex>0,surface.faceIndex<=component.faceCount,surface.width.isFinite,surface.height.isFinite,surface.width>0,surface.height>0 else {
          throw FormError.invalid("Named CAD surface is missing its validated component or exact face revision.")
        }
      }
    }
  }
}
extension Project {
  public func validateModelRepresentations()throws {
    for object in objects {
      if let mesh=object.meshAsset {guard object.recipeID=="importedMesh",object.cadModel==nil,object.cadRepresentation==nil else{throw FormError.invalid("A visual mesh source cannot masquerade as native exact CAD.")};try mesh.validate()}
      if object.recipeID=="importedMesh",object.meshAsset==nil {throw FormError.invalid("An imported model requires its preserved source and normalized asset reference.")}
      if let model=object.cadModel {guard object.recipeID=="cadModel",let representation=object.cadRepresentation,object.meshAsset==nil else{throw FormError.invalid("A CAD model requires its accepted exact representation.")};try representation.validate(for:model)}
      if object.recipeID=="cadModel",object.cadModel==nil || object.cadRepresentation==nil {throw FormError.invalid("Create a validated CAD feature model before publishing this object.")}
      if object.cadModel==nil,object.cadRepresentation != nil {throw FormError.invalid("An exact CAD representation needs its durable source graph.")}
    }
  }
}
