import Foundation

public enum DecorationProcess:String,Codable,CaseIterable,Sendable {case htv,dtf}
public enum DecorationWhitePolicy:String,Codable,CaseIterable,Sendable {case printOpaqueWhite,showThrough}
public enum DecorationColorDelivery:String,Codable,CaseIterable,Sendable {case sRGBRaster,profiledProcess}

/// A material declaration is independent from a paint/ink's preview color.
public struct DecorationLayerMaterial:Codable,Equatable,Sendable {
  public var paintKey:String
  public var name:String
  public var supplier:String?
  public var sku:String?
  public var notes:String?
  public init(paintKey:String,name:String) {self.paintKey=paintKey;self.name=name}
  public func validate() throws {
    guard !paintKey.isEmpty,paintKey.count<=100,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=160,
      [supplier,sku].allSatisfy({($0?.count ?? 0)<=500}),(notes?.count ?? 0)<=2000 else{throw FormError.invalid("Use a bounded paint identity and an explicit material name; supplier/SKU/notes are optional declarations.")}
  }
}
public struct DecorationPreparationOptions:Codable,Equatable,Sendable {
  public var process:DecorationProcess
  public var mirror:Bool
  public var includeBackground=false
  public var weedMargin=0.0
  public var dpi=300.0
  public var whitePolicy=DecorationWhitePolicy.printOpaqueWhite
  public var colorDelivery=DecorationColorDelivery.sRGBRaster
  public var convertSpotAlternates=false
  public var includeUnderbaseReference:Bool
  public var layerMaterials:[DecorationLayerMaterial]=[]
  public var materialNotes:String?
  public var equipmentNotes:String?
  public init(process:DecorationProcess) {self.process=process;mirror=process == .htv;includeUnderbaseReference=process == .dtf}
  private enum CodingKeys:String,CodingKey {case process,mirror,includeBackground,weedMargin,dpi,whitePolicy,colorDelivery,convertSpotAlternates,includeUnderbaseReference,layerMaterials,materialNotes,equipmentNotes}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self);self.init(process:try c.decode(DecorationProcess.self,forKey:.process))
    mirror=try c.decodeIfPresent(Bool.self,forKey:.mirror) ?? mirror
    includeBackground=try c.decodeIfPresent(Bool.self,forKey:.includeBackground) ?? false
    weedMargin=try c.decodeIfPresent(Double.self,forKey:.weedMargin) ?? 0;dpi=try c.decodeIfPresent(Double.self,forKey:.dpi) ?? 300
    whitePolicy=try c.decodeIfPresent(DecorationWhitePolicy.self,forKey:.whitePolicy) ?? .printOpaqueWhite
    colorDelivery=try c.decodeIfPresent(DecorationColorDelivery.self,forKey:.colorDelivery) ?? .sRGBRaster
    convertSpotAlternates=try c.decodeIfPresent(Bool.self,forKey:.convertSpotAlternates) ?? false
    includeUnderbaseReference=try c.decodeIfPresent(Bool.self,forKey:.includeUnderbaseReference) ?? includeUnderbaseReference
    layerMaterials=try c.decodeIfPresent([DecorationLayerMaterial].self,forKey:.layerMaterials) ?? []
    materialNotes=try c.decodeIfPresent(String.self,forKey:.materialNotes);equipmentNotes=try c.decodeIfPresent(String.self,forKey:.equipmentNotes)
  }
  public func validate()throws {
    guard weedMargin.isFinite,(0...50).contains(weedMargin),dpi.isFinite,(72...600).contains(dpi),layerMaterials.count<=64,
      Set(layerMaterials.map(\.paintKey)).count==layerMaterials.count,[materialNotes,equipmentNotes].allSatisfy({($0?.count ?? 0)<=4000}),
      process == .htv || weedMargin==0 else{throw FormError.invalid("Use finite 0–50 mm HTV weed padding, 72–600 DPI, and at most 64 unique material declarations. DTF does not use a weed border.")}
    guard process != .htv || (colorDelivery == .sRGBRaster && !convertSpotAlternates && !includeUnderbaseReference) else{throw FormError.invalid("CMYK delivery, spot-alternate conversion and underbase references belong to DTF preparation.")}
    for value in layerMaterials {try value.validate()}
  }
}

public struct DecorationTargetSnapshot:Codable,Equatable,Sendable {
  public enum Surface:String,Codable,Sendable {case planar,cylindricalBand,unverified}
  public var garment:ProductObject
  public var attachment:TextileAttachment
  public var zoneName:String
  public var zoneWidth:Double?
  public var zoneHeight:Double?
  public var surface:Surface
}
/// Original source owners and their reachable component/story dependencies. Runtime
/// resolved fragments are excluded by the existing artwork/story Codable contracts.
public struct DecorationSourceSnapshot:Codable,Equatable,Sendable {
  public var projectID:UUID
  public var objectID:UUID
  public var width:Double,height:Double
  public var objects:[ProductObject]
  public var artwork:Artwork
  public var swatches:[ArtworkSwatch]
  public var textStyles:[ArtworkTextStyle]
  public var stories:[TextStory]
  public var publications:[PublicationDocument]
  public var materials:[Material]
  public var recipes:[Recipe]
  public var target:DecorationTargetSnapshot?
  public func validate() throws {
    guard [width,height].allSatisfy({$0.isFinite && (0.1...10000).contains($0)}),!objects.isEmpty,objects.count<=256,
      Set(objects.map(\.id)).count==objects.count,objects.contains(where:{$0.id==objectID}),swatches.count<=256,textStyles.count<=256,
      stories.count<=128,publications.count<=128,materials.count<=256 else{throw FormError.invalid("Decoration source needs an existing physical object, finite dimensions and bounded original dependencies.")}
    try validateArtwork(artwork)
    for value in swatches {try value.printInk?.validate()}
    if let target {
      guard target.attachment.garmentID==target.garment.id,target.zoneWidth.map({$0.isFinite && $0>0}) ?? true,
        target.zoneHeight.map({$0.isFinite && $0>0}) ?? true else{throw FormError.invalid("The archived target zone is invalid.")}
    }
  }
}

extension Project {
  public func decorationSourceSnapshot(objectID:UUID) throws -> DecorationSourceSnapshot {
    try validateArtworkLinks()
    guard let object=objects.first(where:{$0.id==objectID}),object.supportsArtworkFace,let art=surfaceArtwork(object,keepingSwatchReferences:true),
      !object.isCanvasWorkspace else{throw FormError.invalid("Choose a physical decoration or finite artwork frame with source artwork.")}
    var pending=[objectID],seen=Set<UUID>(),storyIDs=Set<UUID>(),captured:[ProductObject]=[]
    while let id=pending.popLast() {
      guard seen.insert(id).inserted else{continue}
      guard seen.count<=256,let item=objects.first(where:{$0.id==id}) else{throw FormError.invalid("The decoration source dependency is missing or exceeds 256 objects.")}
      captured.append(item)
      if let source=item.artworkSourceID {pending.append(source)}
      if let garment=item.textile?.attachment?.garmentID {pending.append(garment)}
      for materialID in [item.materialID,item.textile?.liningMaterialID,item.textile?.trimMaterialID].compactMap({$0}) {
        if let tile=material(materialID).fabric?.pattern?.sourceObjectID {pending.append(tile)}
      }
      for element in item.artwork?.elements ?? [] {
        if let source=element.component?.sourceObjectID {pending.append(source)}
        if let storyID=element.storyFrame?.storyID,storyIDs.insert(storyID).inserted,let story=textStories?.first(where:{$0.id==storyID}) {pending.append(contentsOf:story.frames.map(\.objectID))}
      }
    }
    let storedStories=(textStories ?? []).filter{storyIDs.contains($0.id)}
    var refs=art.referencedSwatches
    for o in captured {refs.formUnion(o.artwork?.referencedSwatches ?? [])}
    for story in storedStories {refs.formUnion(Artwork(elements:[story.sourceElement]).referencedSwatches)}
    var target:DecorationTargetSnapshot?
    if let a=object.textile?.attachment,let host=objects.first(where:{$0.id==a.garmentID}) {
      try MerchandiseBlanks.validate(object,in:self)
      let zone=MerchandiseBlanks.zones(host).first{$0.id==a.zone}
      target = .init(garment:host,attachment:a,zoneName:zone?.name ?? a.zone.name,zoneWidth:zone?.width,zoneHeight:zone?.height,
        surface:zone.map{$0.curved ? .cylindricalBand:.planar} ?? .unverified)
    }
    let materialIDs=Set(captured.flatMap{[$0.materialID,$0.textile?.liningMaterialID,$0.textile?.trimMaterialID].compactMap{$0}})
    let pubIDs=Set(storedStories.compactMap(\.publicationID))
    let result=DecorationSourceSnapshot(projectID:id,objectID:objectID,width:object.artworkSize.x,height:object.artworkSize.y,
      objects:captured.sorted{$0.id.uuidString<$1.id.uuidString},artwork:art,swatches:(swatches ?? []).filter{refs.contains($0.id)},
      textStyles:textStyles ?? [],stories:storedStories,publications:(publications ?? []).filter{pubIDs.contains($0.id)},
      materials:materials.filter{materialIDs.contains($0.id)},recipes:Set(captured.map(\.recipeID)).sorted().compactMap{recipe($0)},target:target)
    try result.validate();return result
  }
}
