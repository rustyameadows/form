import Foundation

/// Physical textile specifications. Values are declarations, not simulated cloth measurements.
public struct FabricProfile: Codable, Equatable, Sendable {
  public enum Structure: String, Codable, CaseIterable, Sendable { case woven, knit, nonwoven, thread }
  public var composition: String
  public var structure: Structure
  public var weightGSM: Double?
  public var usableWidth: Double?
  public var stretchWarp: Double?
  public var stretchWeft: Double?
  public var supplier: String?
  public var sku: String?
  public var care: String?
  public var inventoryMeters: Double?
  public var specificationsVerified = false
  public var pattern: FabricPattern?
  public init(composition: String, structure: Structure, weightGSM: Double? = nil, usableWidth: Double? = nil) {
    self.composition=composition;self.structure=structure;self.weightGSM=weightGSM;self.usableWidth=usableWidth
  }
  private enum CodingKeys:String,CodingKey {case composition,structure,weightGSM,usableWidth,stretchWarp,stretchWeft,supplier,sku,care,inventoryMeters,specificationsVerified,pattern}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    composition=try c.decode(String.self,forKey:.composition);structure=try c.decode(Structure.self,forKey:.structure)
    weightGSM=try c.decodeIfPresent(Double.self,forKey:.weightGSM);usableWidth=try c.decodeIfPresent(Double.self,forKey:.usableWidth)
    stretchWarp=try c.decodeIfPresent(Double.self,forKey:.stretchWarp);stretchWeft=try c.decodeIfPresent(Double.self,forKey:.stretchWeft)
    supplier=try c.decodeIfPresent(String.self,forKey:.supplier);sku=try c.decodeIfPresent(String.self,forKey:.sku);care=try c.decodeIfPresent(String.self,forKey:.care)
    inventoryMeters=try c.decodeIfPresent(Double.self,forKey:.inventoryMeters);specificationsVerified=try c.decodeIfPresent(Bool.self,forKey:.specificationsVerified) ?? false
    pattern=try c.decodeIfPresent(FabricPattern.self,forKey:.pattern)
  }
  public func validate() throws {
    guard !composition.isEmpty,composition.count<=500 else {throw FormError.invalid("Fabric composition needs 1–500 characters.")}
    for (value,maximum) in [(weightGSM,3000.0),(usableWidth,10000.0),(stretchWarp,500.0),(stretchWeft,500.0),(inventoryMeters,100000.0)] {
      if let value, !value.isFinite || value<0 || value>maximum {throw FormError.invalid("Fabric measurements must be finite and within supported physical ranges.")}
    }
    guard [supplier,sku,care].allSatisfy({($0?.count ?? 0)<=2000}) else {throw FormError.invalid("Fabric notes are too long.")}
    try pattern?.validate()
  }
}

public struct TextileAttachment: Codable, Equatable, Sendable {
  public enum Zone: String, Codable, CaseIterable, Sendable {
    case leftChest, rightChest, leftSleeve, rightSleeve, collar, back
    public var name: String {
      switch self {case .leftChest:return "Left chest";case .rightChest:return "Right chest";case .leftSleeve:return "Left sleeve";case .rightSleeve:return "Right sleeve";case .collar:return "Inside collar";case .back:return "Back"}
    }
  }
  public var garmentID: UUID
  public var zone: Zone
  public var offset: Point2
  public var rotation: Double
  public var clearance: Double
  public init(garmentID:UUID,zone:Zone,offset:Point2 = .init(),rotation:Double = 0,clearance:Double = 1) {
    self.garmentID=garmentID;self.zone=zone;self.offset=offset;self.rotation=rotation;self.clearance=clearance
  }
  private enum CodingKeys:String,CodingKey {case garmentID,zone,offset,rotation,clearance}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    garmentID=try c.decode(UUID.self,forKey:.garmentID);zone=try c.decode(Zone.self,forKey:.zone)
    offset=try c.decodeIfPresent(Point2.self,forKey:.offset) ?? .init();rotation=try c.decodeIfPresent(Double.self,forKey:.rotation) ?? 0;clearance=try c.decodeIfPresent(Double.self,forKey:.clearance) ?? 1
  }
}

/// Manufactured decoration intent with optional regenerable embroidery source.
public struct TextileProduct: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, CaseIterable, Sendable {case garment, patch, label, embroidery}
  public enum Process: String, Codable, CaseIterable, Sendable {
    case decoratedBlank, embroideredPatch, wovenPatch, printedPatch, sewnLabel, directEmbroidery
    public var name: String {
      switch self {case .decoratedBlank:return "Decorated blank";case .embroideredPatch:return "Embroidered patch study";case .wovenPatch:return "Woven patch";case .printedPatch:return "Printed patch";case .sewnLabel:return "Sewn label";case .directEmbroidery:return "Direct embroidery study"}
    }
  }
  public var kind: Kind
  public var process: Process
  public var blankName: String?
  public var size: String?
  public var manufacturer: String?
  public var sku: String?
  public var measurementsVerified = false
  public var liningMaterialID: String?
  public var trimMaterialID: String?
  public var border: String?
  public var backing: String?
  public var attachmentMethod: String?
  public var threadColors: [String]?
  public var embroidery: EmbroideryDesign?
  public var notes: String?
  public var attachment: TextileAttachment?
  public var laidFaceDown: Bool?
  public init(kind:Kind,process:Process) {self.kind=kind;self.process=process}
  private enum CodingKeys:String,CodingKey {case kind,process,blankName,size,manufacturer,sku,measurementsVerified,liningMaterialID,trimMaterialID,border,backing,attachmentMethod,threadColors,embroidery,notes,attachment,laidFaceDown}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    kind=try c.decode(Kind.self,forKey:.kind);process=try c.decode(Process.self,forKey:.process)
    blankName=try c.decodeIfPresent(String.self,forKey:.blankName);size=try c.decodeIfPresent(String.self,forKey:.size)
    manufacturer=try c.decodeIfPresent(String.self,forKey:.manufacturer);sku=try c.decodeIfPresent(String.self,forKey:.sku)
    measurementsVerified=try c.decodeIfPresent(Bool.self,forKey:.measurementsVerified) ?? false
    liningMaterialID=try c.decodeIfPresent(String.self,forKey:.liningMaterialID);trimMaterialID=try c.decodeIfPresent(String.self,forKey:.trimMaterialID)
    border=try c.decodeIfPresent(String.self,forKey:.border);backing=try c.decodeIfPresent(String.self,forKey:.backing)
    attachmentMethod=try c.decodeIfPresent(String.self,forKey:.attachmentMethod);threadColors=try c.decodeIfPresent([String].self,forKey:.threadColors)
    notes=try c.decodeIfPresent(String.self,forKey:.notes);attachment=try c.decodeIfPresent(TextileAttachment.self,forKey:.attachment)
    embroidery=try c.decodeIfPresent(EmbroideryDesign.self,forKey:.embroidery)
    laidFaceDown=try c.decodeIfPresent(Bool.self,forKey:.laidFaceDown)
  }
  public var renderDefinition: Self {
    var result=Self(kind:kind,process:process)
    result.liningMaterialID=liningMaterialID;result.trimMaterialID=trimMaterialID;result.threadColors=threadColors
    return result
  }
  public static func defaults(for recipe:String)->Self? {
    switch recipe {
    case "bomberJacket":
      var item=Self(kind:.garment,process:.decoratedBlank);item.blankName="Generic flight bomber";item.size="M · concept measurements";item.liningMaterialID="flight-orange";item.trimMaterialID="flight-rib";return item
    case "textilePatch":
      var item=Self(kind:.patch,process:.embroideredPatch);item.border="Merrow-style border · visual study";item.backing="Sew-on";item.attachmentMethod="Perimeter stitching";return item
    case "textileLabel":
      var item=Self(kind:.label,process:.sewnLabel);item.attachmentMethod="Sewn at short edges";return item
    default:return nil
    }
  }
}

public struct TextilePlacement: Equatable, Sendable {
  public var position:Vector3
  public var rotation:Double
  public var underside:Bool
  public var normal:Vector3 = .init(0,1,0)
}

public enum TextileDesign {
  public static let recipeIDs:Set<String>=["bomberJacket","textilePatch","textileLabel"]
  public static let recipes:[Recipe]=[
    .init("bomberJacket","Flight bomber","jacket","A dimensioned generic bomber blank with shaped fabric panels, ribbing, zipper, pockets, and independent decorations. Concept geometry, not a cutting pattern.",[
      .init("width","Body width",620,400...900),.init("depth","Body length",660,420...1000),
      .init("sleeveLength","Sleeve length",570,350...800),.init("sleeveAngle","Sleeve angle",26,5...65,unit:"°"),
      .init("loft","Body loft",65,20...130),.init("cuffWidth","Cuff width",105,65...165),
      .init("ribHeight","Waist rib",65,35...110),.init("neckWidth","Neck opening",175,130...240)]),
    .init("textilePatch","Textile patch","seal","An independent textile component with editable source artwork, border, backing, and garment-relative placement.",[
      .init("width","Width",90,10...400,step:0.5),.init("depth","Height",90,10...400,step:0.5),
      .init("height","Thickness",2.4,0.3...12,step:0.1),.init("corner","Corner radius",45,0...200,step:0.5),.init("borderWidth","Border",3,0...12,step:0.5)]),
    .init("textileLabel","Sewn label","tag","A separate woven or printed label with editable artwork and placement.",[
      .init("width","Width",90,10...300,step:0.5),.init("depth","Height",32,8...160,step:0.5),
      .init("height","Thickness",0.8,0.2...6,step:0.1),.init("corner","Corner radius",1,0...20,step:0.5),.init("borderWidth","Stitch inset",2,0...8,step:0.5)])]

  public static var materials:[Material] {
    func fabric(_ id:String,_ name:String,_ color:String,_ composition:String,_ structure:FabricProfile.Structure,_ gsm:Double,_ thickness:Double,_ roughness:Double)->Material {
      var m=Material(id,name,"Fabric",color,roughness:roughness,thickness:thickness)
      m.fabric=FabricProfile(composition:composition,structure:structure,weightGSM:gsm,usableWidth:1400);return m
    }
    return [fabric("flight-nylon","Flight nylon · midnight","#26323C","Nylon twill · generic",.woven,180,0.45,0.56),
      fabric("flight-sage","Flight nylon · sage","#707B68","Nylon twill · generic",.woven,180,0.45,0.56),
      fabric("flight-orange","Rescue orange lining","#CB5A2E","Polyester lining · generic",.woven,95,0.25,0.48),
      fabric("flight-rib","Midnight rib knit","#19252D","Cotton / elastane rib · generic",.knit,420,2.2,0.94),
      fabric("patch-twill","Patch twill · midnight","#172B42","Polyester twill · generic",.woven,240,0.7,0.88),
      fabric("label-ecru","Woven label · ecru","#E5DEC8","Polyester label tape · generic",.woven,150,0.45,0.9)]
  }
  /// Shared visual surface used by jacket mesh and attachment landmarks, in millimeters.
  public static func bodyTop(_ object:ProductObject,x:Double,z:Double)->Double {
    let width=object["width"],length=object["depth"],loft=object["loft"]
    let u=min(1,max(-1,x/max(1,width/2))),v=min(1,max(-1,z/max(1,length/2)))
    let body=16+loft*sqrt(max(0,1-u*u))*pow(max(0,1-v*v),0.28)
    let hem=length/2-object["ribHeight"],t=min(1,max(0,(z-(hem-70))/70))
    return body*(1-t)+30*t
  }
  public static func anchor(_ garment:ProductObject,zone:TextileAttachment.Zone)->Vector3 {
    let w=garment["width"],d=garment["depth"],s=garment["sleeveLength"],a=garment["sleeveAngle"] * .pi/180
    switch zone {
    case .leftChest:return .init(w*0.24,bodyTop(garment,x:w*0.24,z:-d*0.18),-d*0.18)
    case .rightChest:return .init(-w*0.24,bodyTop(garment,x:-w*0.24,z:-d*0.18),-d*0.18)
    case .leftSleeve:return .init(w*0.41+s*0.34*cos(a),sleeveTop(garment,t:0.34),-d*0.28+s*0.34*sin(a))
    case .rightSleeve:return .init(-w*0.41-s*0.34*cos(a),sleeveTop(garment,t:0.34),-d*0.28+s*0.34*sin(a))
    case .collar:return .init(0,12,-d*0.43)
    case .back:return .init(0,1,d*0.02)
    }
  }
  public static func sleeveTop(_ garment:ProductObject,t:Double)->Double {
    (16+garment["loft"]*0.15)*(1-t)+20*t+(garment["loft"]*0.48*(1-t)+17*t)*(1+0.07*sin(t*45))
  }
}

extension Project {
  public func validateTextiles() throws {
    for material in materials {try material.fabric?.validate()}
    try validateFabricPatterns()
    for object in objects {
      guard let spec=object.textile else {continue}
      if let embroidery=spec.embroidery {
        guard spec.kind != .garment else {throw FormError.invalid("Digitize an independent patch/decoration region before attaching it to a garment.")}
        try embroidery.validate()
      }
      guard TextileDesign.recipeIDs.contains(object.recipeID),
        (object.recipeID=="bomberJacket") == (spec.kind == .garment),
        (spec.kind == .garment) == (spec.process == .decoratedBlank),
        [spec.blankName,spec.size,spec.manufacturer,spec.sku,spec.liningMaterialID,spec.trimMaterialID,spec.border,spec.backing,spec.attachmentMethod,spec.notes].allSatisfy({($0?.count ?? 0)<=2000}),
        (spec.threadColors?.count ?? 0)<=64 else {throw FormError.invalid("Invalid textile product or specification.")}
      for color in spec.threadColors ?? [] {try validateColor(color)}
      if let placement=spec.attachment {
        guard spec.kind != .garment,placement.garmentID != object.id,
          let garment=objects.first(where:{$0.id==placement.garmentID}),garment.recipeID=="bomberJacket",garment.textile?.kind == .garment,
          [placement.offset.x,placement.offset.y,placement.rotation,placement.clearance].allSatisfy(\.isFinite),
          abs(placement.offset.x)<=3000,abs(placement.offset.y)<=3000,abs(placement.rotation)<=36000,
          (0...50).contains(placement.clearance) else {throw FormError.invalid("Attach decorations to a flight bomber with finite, dimensioned placement.")}
      }
    }
  }
  public func textilePlacement(_ object:ProductObject)->TextilePlacement {
    guard let attachment=object.textile?.attachment,
      let garment=objects.first(where:{$0.id==attachment.garmentID}) else {
      return .init(position:object.position,rotation:object.rotation,underside:object.textile?.laidFaceDown == true)
    }
    var local=TextileDesign.anchor(garment,zone:attachment.zone)
    var hx=0.0,hz=0.0
    local.x+=attachment.offset.x;local.z+=attachment.offset.y
    if attachment.zone != .back && ![.leftSleeve,.rightSleeve,.collar].contains(attachment.zone) {
      local.y=TextileDesign.bodyTop(garment,x:local.x,z:local.z)
      hx=(TextileDesign.bodyTop(garment,x:local.x+0.1,z:local.z)-TextileDesign.bodyTop(garment,x:local.x-0.1,z:local.z))/0.2
      hz=(TextileDesign.bodyTop(garment,x:local.x,z:local.z+0.1)-TextileDesign.bodyTop(garment,x:local.x,z:local.z-0.1))/0.2
    } else if [.leftSleeve,.rightSleeve].contains(attachment.zone) {
      let t=0.34,slope=(TextileDesign.sleeveTop(garment,t:t+0.0001)-TextileDesign.sleeveTop(garment,t:t-0.0001))/(0.0002*garment["sleeveLength"])
      let angle=garment["sleeveAngle"] * .pi/180
      hx=slope*cos(angle)*(attachment.zone == .leftSleeve ? 1 : -1);hz=slope*sin(angle)
    }
    local.y += attachment.zone == .back ? -attachment.clearance : attachment.clearance
    let angle=garment.rotation * .pi/180,c=cos(angle),s=sin(angle)
    let length=sqrt(hx*hx+1+hz*hz),normal=attachment.zone == .back ? Vector3(0,-1,0):Vector3((-hx*c-hz*s)/length,1/length,(hx*s-hz*c)/length)
    return .init(position:.init(garment.position.x+local.x*c+local.z*s,garment.position.y+local.y,garment.position.z-local.x*s+local.z*c),
      rotation:garment.rotation+attachment.rotation,underside:attachment.zone == .back,normal:normal)
  }
  public mutating func detachTextileConsumers(of ids:Set<UUID>) {
    let old=self
    for i in objects.indices where !ids.contains(objects[i].id) {
      guard let attached=objects[i].textile?.attachment,ids.contains(attached.garmentID) else {continue}
      let placement=old.textilePlacement(objects[i]);objects[i].position=placement.position;objects[i].rotation=placement.rotation
      objects[i].textile?.laidFaceDown=placement.underside
      objects[i].textile?.attachment=nil
    }
  }
  public mutating func setTextileWorldPosition(_ id:UUID,to position:Vector3) {
    guard let i=objects.firstIndex(where:{$0.id==id}) else {return}
    guard let attachment=objects[i].textile?.attachment,let garment=objects.first(where:{$0.id==attachment.garmentID}) else {objects[i].position=position;return}
    let a=garment.rotation * .pi/180,dx=position.x-garment.position.x,dz=position.z-garment.position.z
    let anchor=TextileDesign.anchor(garment,zone:attachment.zone)
    objects[i].textile?.attachment?.offset = .init(dx*cos(a)-dz*sin(a)-anchor.x,dx*sin(a)+dz*cos(a)-anchor.z)
  }
}
