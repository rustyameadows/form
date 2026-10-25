import Foundation

public struct CMYKComponents:Codable,Equatable,Sendable {
  public var cyan:Double,magenta:Double,yellow:Double,black:Double
  public init(_ cyan:Double,_ magenta:Double,_ yellow:Double,_ black:Double) {self.cyan=cyan;self.magenta=magenta;self.yellow=yellow;self.black=black}
  public var values:[Double] {[cyan,magenta,yellow,black]}
  public var valid:Bool {values.allSatisfy{$0.isFinite && (0...1).contains($0)}}
}

/// Source ink numbers are independent of the swatch's approximate sRGB preview.
public struct ProductionInk:Codable,Equatable,Sendable {
  public enum Kind:String,Codable,Sendable {case processCMYK="process_cmyk",spot}
  public var kind:Kind
  public var components:CMYKComponents
  public var profile:ArtworkOutputProfile
  public var spotName:String?
  public var tint:Double
  public init(kind:Kind,components:CMYKComponents,profile:ArtworkOutputProfile,spotName:String?=nil,tint:Double=1) {
    self.kind=kind;self.components=components;self.profile=profile;self.spotName=spotName;self.tint=tint
  }
  private enum CodingKeys:String,CodingKey {case kind,components,profile,spotName,tint}
  public init(from decoder:Decoder) throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    kind=try c.decode(Kind.self,forKey:.kind);components=try c.decode(CMYKComponents.self,forKey:.components)
    profile=try c.decode(ArtworkOutputProfile.self,forKey:.profile);spotName=try c.decodeIfPresent(String.self,forKey:.spotName)
    tint=try c.decodeIfPresent(Double.self,forKey:.tint) ?? 1
  }
  public func validate() throws {
    try profile.validate()
    guard profile.model=="CMYK",components.valid,tint.isFinite,(0...1).contains(tint) else{throw FormError.invalid("Production inks require finite 0–1 CMYK components/tint and a portable CMYK profile.")}
    if kind == .spot {
      guard let name=spotName,!name.isEmpty,name==name.trimmingCharacters(in:.whitespacesAndNewlines),name.utf8.count<=127,
        !name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
        !["all","none","cyan","magenta","yellow","black"].contains(name.lowercased()) else{throw FormError.invalid("Use a distinct named spot ink up to 127 UTF-8 bytes; All, None and process colorant names are reserved.")}
    } else {guard spotName==nil,tint==1 else{throw FormError.invalid("Process CMYK uses its four declared components directly; spot names and tints belong to named spot inks.")}}
  }
  public var previewComponents:[Double] {components.values.map{$0*(kind == .spot ? tint:1)}}
}

extension Project {
  public func validateProductionInks() throws {
    var named:[String:ProductionInk]=[:]
    for swatch in swatches ?? [] {
      guard let ink=swatch.printInk else{continue};try ink.validate()
      if let name=ink.spotName {
        if let prior=named[name],prior.components != ink.components || prior.profile.sha256 != ink.profile.sha256 {throw FormError.invalid("Named ink \(name) has conflicting CMYK alternates or profile identities. Tints may vary; its definition must match.")}
        named[name]=ink
      }
    }
  }
  public func productionInk(_ id:UUID?)->ProductionInk? {id.flatMap{id in swatches?.first{$0.id==id}?.printInk}}
  public func productionInkIsReferenced(_ id:UUID)->Bool {
    objects.contains{ $0.artwork?.referencedSwatches.contains(id)==true } || (textStories ?? []).contains{Artwork(elements:[$0.sourceElement]).referencedSwatches.contains(id)}
  }
}

public enum ProductionInkCommands {
  /// Structural detach used to preserve RGB appearance. It must not silently
  /// erase a production declaration that cannot be represented by that RGB.
  public static func validateDetach(_ project:Project,artwork:Artwork,ids:Set<UUID>,target:String,stopID:UUID?,partID:UUID?,location:Int?,length:Int?) throws {
    var refs=Set<UUID>()
    func add(_ id:UUID?) {if let id {refs.insert(id)}}
    if target=="background" {add(artwork.backgroundSwatchID)}
    let targets=["fill","stroke"].contains(target) ? artwork.swatchPaintTargets(for:ids):ids
    for raw in artwork.elements where targets.contains(raw.id) {
      let e=raw.storyFrame.flatMap{ref in project.textStories?.first{$0.id==ref.storyID}?.sourceElement} ?? raw
      switch target {
      case "fill":
        if e.component != nil {add(e.component?.colorSwatchID)}
        else if e.kind=="line" {add(e.stroke?.swatchID)}
        else {add(e.fillSwatchID);for run in e.textRuns ?? [] {add(run.swatchID)}}
      case "text_range":
        guard let location,let length,location>=0,length>0,location<=e.text.utf16.count,length<=e.text.utf16.count-location else{continue}
        let range=NSRange(location:location,length:length)
        var covered=0
        for run in e.textRuns ?? [] {
          let overlap=NSIntersectionRange(range,NSRange(location:run.location,length:run.length))
          if overlap.length>0 {covered+=overlap.length;add(run.swatchID)}
        }
        if covered<length {add(e.fillSwatchID)}
      case "stroke":add(e.stroke?.swatchID)
      case "shadow":add(e.shadow?.swatchID)
      case "gradient_stop":add(e.gradient?.stops.first{$0.id==stopID}?.swatchID)
      case "component_part":add(e.component?.overrides?.first{$0.elementID==partID}?.colorSwatchID)
      default:break
      }
    }
    if refs.contains(where:{project.productionInk($0) != nil}) {throw FormError.invalid("Convert this production ink to RGB preview before detaching its paint link.")}
  }
}

extension Project {
  /// Test derived ordinary source leaves before stripping their palette links.
  public func hasUsedProductionInks(in art:Artwork)->Bool {
    let masks=Set(art.elements.compactMap(\.clipID)),byID=Dictionary(uniqueKeysWithValues:art.elements.map{($0.id,$0)}),roles=ArtworkProduction.effectiveRoles(in:art)
    func ink(_ id:UUID?)->Bool {productionInk(id) != nil}
    func fill(_ e:ArtworkElement)->Bool {
      guard e.fillEnabled != false,(e.fillOpacity ?? 1)>0 else{return false}
      if let gradient=e.gradient {return gradient.stops.contains{ink($0.swatchID)}}
      if ink(e.fillSwatchID) || e.textRuns?.contains(where:{ink($0.swatchID)})==true {return true}
      return false
    }
    for e in art.elements where !masks.contains(e.id) && (roles[e.id] ?? .print) == .print {
      var current:ArtworkElement?=e,visible=true,seen=Set<UUID>()
      while let value=current,seen.insert(value.id).inserted {
        if value.hidden==true || (value.opacity ?? 1)==0 {visible=false;break}
        current=value.parentID.flatMap{byID[$0]}
      }
      guard visible else{continue}
      if e.shadow?.enabled==true,(e.shadow?.opacity ?? 0)>0,ink(e.shadow?.swatchID) {return true}
      if e.kind=="group",e.booleanOperation==nil {continue}
      if !["text","image"].contains(e.kind),let stroke=e.visibleStroke,ink(stroke.swatchID) {return true}
      if e.kind=="image" || e.kind=="line" {continue}
      if fill(e) {return true}
      if let story=e.storyFrame?.resolved?.story,fill(story.sourceElement) {return true}
    }
    return (art.backgroundOpacity ?? 1)>0 && ink(art.backgroundSwatchID)
  }
}

extension Artwork {
  /// Runtime guards do not change semantic document equality or undo history.
  public static func == (lhs:Artwork,rhs:Artwork)->Bool {
    let appearance=lhs.background==rhs.background && lhs.outputColorProfile==rhs.outputColorProfile && lhs.elements==rhs.elements && lhs.bleed==rhs.bleed && lhs.backgroundOpacity==rhs.backgroundOpacity && lhs.backgroundSwatchID==rhs.backgroundSwatchID && lhs.boundary==rhs.boundary
    let layout=lhs.unit==rhs.unit && lhs.guides==rhs.guides && lhs.gridSpacing==rhs.gridSpacing && lhs.showGrid==rhs.showGrid && lhs.snapEnabled==rhs.snapEnabled && lhs.nudge==rhs.nudge && lhs.showGuides==rhs.showGuides && lhs.canvasPosition==rhs.canvasPosition
    return appearance && layout && lhs.sewingSeams==rhs.sewingSeams && lhs.sewingLayout==rhs.sewingLayout && lhs.sewingTiles==rhs.sewingTiles && lhs.language==rhs.language && lhs.imports==rhs.imports
  }
}
