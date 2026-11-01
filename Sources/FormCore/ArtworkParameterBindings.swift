import Foundation
import FormCADModel

/// Numeric model relationships targeting the existing canonical artwork.
/// Element/node/edge identities and the source geometry type remain unchanged.
public struct ArtworkParameterBinding:Codable,Equatable,Identifiable,Sendable {
  public enum Property:String,Codable,CaseIterable,Sendable {case x,y,width,height,rotation,seamAllowance}
  public var id:String
  public var elementID:UUID
  public var property:Property
  public var value:CADScalar
  public init(id:String,elementID:UUID,property:Property,value:CADScalar) {
    self.id=id;self.elementID=elementID;self.property=property;self.value=value
  }
  public var units:String {property == .rotation ? "deg":"mm"}
  public func resolvedValue(using parameters:[String:Double]) throws -> Double {
    guard !id.isEmpty,id.utf8.count<=128 else{throw failure("Use a bounded nonempty binding identity.")}
    let result:Double
    do {result=try CADExpression.evaluate(value.expression,variables:parameters)}
    catch {throw failure(error.localizedDescription)}
    let valid:Bool
    switch property {
    case .x,.y:valid=abs(result)<=100000
    case .width,.height:valid=result>=0.001 && result<=100000
    case .rotation:valid=abs(result)<=36000
    case .seamAllowance:valid=result>=0 && result<=100
    }
    guard result.isFinite,valid else{throw failure("The resolved value is outside the physical field's supported range.",expected:result)}
    return result
  }
  public func currentValue(in artwork:Artwork) throws -> Double {
    guard let element=artwork.elements.first(where:{$0.id==elementID}) else{throw failure("The bound source element is missing; repair or remove this binding.")}
    switch property {
    case .x:return element.x
    case .y:return element.y
    case .width:return element.width
    case .height:return element.height
    case .rotation:return element.rotation ?? 0
    case .seamAllowance:
      guard let piece=element.sewingPiece else{throw failure("A seam allowance binding requires an annotated sewing piece.")}
      return piece.seamAllowance
    }
  }
  fileprivate func assign(_ number:Double,to artwork:inout Artwork) throws {
    guard let i=artwork.elements.firstIndex(where:{$0.id==elementID}) else{throw failure("The bound source element is missing; repair or remove this binding.")}
    switch property {
    case .x:artwork.elements[i].x=number
    case .y:artwork.elements[i].y=number
    case .width:artwork.elements[i].width=number
    case .height:artwork.elements[i].height=number
    case .rotation:artwork.elements[i].rotation=number==0 ? nil:number
    case .seamAllowance:
      guard artwork.elements[i].sewingPiece != nil else{throw failure("A seam allowance binding requires an annotated sewing piece.")}
      artwork.elements[i].sewingPiece!.seamAllowance=number
    }
  }
  fileprivate func failure(_ message:String,expected:Double?=nil,actual:Double?=nil) -> ArtworkParameterBindingFailure {
    .init(bindingID:id,elementID:elementID,property:property,expression:value.expression,
      message:message,expected:expected,actual:actual)
  }
}
public struct ArtworkParameterBindingFailure:Error,LocalizedError,Codable,Equatable,Sendable {
  public let bindingID:String
  public let elementID:UUID
  public let property:ArtworkParameterBinding.Property
  public let expression:String
  public let message:String
  public let expected:Double?
  public let actual:Double?
  public var errorDescription:String? {"Binding '\(bindingID)' on element \(elementID.uuidString).\(property.rawValue): \(message)"}
}
public enum ArtworkParameterBindings {
  public static let maximumBindings=256
  public static func decode(_ raw:Any) throws -> [ArtworkParameterBinding]? {
    if raw is NSNull {return nil}
    guard let values=raw as? [[String:Any]],values.count<=maximumBindings,
      values.allSatisfy({Set($0.keys)==["id","elementID","property","value"]}) else {
      throw FormError.invalid("artwork_parameter_bindings needs up to 256 declarations with exactly id, elementID, property and value, or null to remove them.")
    }
    do {
      let decoded=try JSONDecoder.form.decode([ArtworkParameterBinding].self,from:JSONSerialization.data(withJSONObject:values))
      try declarations(decoded);return decoded.isEmpty ? nil:decoded
    } catch let failure as ArtworkParameterBindingFailure {throw failure}
    catch {throw FormError.invalid("Invalid artwork parameter bindings: \(error.localizedDescription)")}
  }
  private static func declarations(_ bindings:[ArtworkParameterBinding]) throws {
    let targets=bindings.map{$0.elementID.uuidString+":"+$0.property.rawValue}
    guard bindings.count<=maximumBindings,Set(bindings.map(\.id)).count==bindings.count,
      Set(targets).count==bindings.count else {
      throw FormError.invalid("Use up to 256 uniquely identified artwork bindings with one rule per element/property.")
    }
  }
  public static func applying(_ bindings:[ArtworkParameterBinding],to source:Artwork,
    parameters:[String:Double]) throws -> Artwork {
    try declarations(bindings)
    // Resolve every rule before changing even the transient document value.
    let values=try bindings.map{try $0.resolvedValue(using:parameters)}
    var artwork=source
    for (binding,value) in zip(bindings,values){try binding.assign(value,to:&artwork)}
    try validateArtwork(artwork)
    return artwork
  }
  public static func validateCanonical(_ bindings:[ArtworkParameterBinding],source:Artwork,
    parameters:[String:Double]) throws {
    try declarations(bindings)
    for binding in bindings {
      let expected=try binding.resolvedValue(using:parameters),actual=try binding.currentValue(in:source)
      guard abs(expected-actual)<=max(1e-7,abs(expected)*1e-12) else {
        throw binding.failure("This field is parameter-bound. Change the source parameter or explicitly update/remove its binding before editing the field.",expected:expected,actual:actual)
      }
    }
  }
}

extension Project {
  public func artworkBindingParameters(for object:ProductObject) throws -> [String:Double] {
    guard let recipe=recipe(object.recipeID),object.artworkSourceID==nil,object.artwork != nil,
      object.patternAssembly==nil,object.cadModel==nil,!PaperConstruction.isPaper(object),!object.isCanvasWorkspace else {
      throw FormError.invalid("Artwork parameter bindings require the existing independent canonical artwork owner and its saved recipe controls.")
    }
    try recipe.validate(object.parameters)
    return recipe.defaults.merging(object.parameters){_,new in new}
  }
  public mutating func applyArtworkParameterBindings(to objectID:UUID) throws {
    guard let object=objects.first(where:{$0.id==objectID}) else{throw FormError.missing("Bound artwork source not found.")}
    guard let bindings=object.artworkParameterBindings,!bindings.isEmpty else{return}
    let values=try artworkBindingParameters(for:object)
    let artwork=try ArtworkParameterBindings.applying(bindings,to:object.artwork!,parameters:values)
    try setArtwork(artwork,for:objectID)
  }
  public func validateArtworkParameterBindings() throws {
    for object in objects where object.artworkParameterBindings?.isEmpty == false {
      let values=try artworkBindingParameters(for:object)
      try ArtworkParameterBindings.validateCanonical(object.artworkParameterBindings!,source:object.artwork!,parameters:values)
    }
  }
}

extension Project {
  /// Source capability follows saved annotations and ownership, not a product name.
  public func isIndependentSewingSource(_ object:ProductObject)->Bool {
    !object.isCanvasWorkspace && !PaperConstruction.isPaper(object) && !object.isFlexibleSurface
      && object.artworkSourceID==nil && object.artwork?.elements.contains{$0.sewingPiece != nil} == true
  }
}

extension Project {
  /// Flat sources keep canonical artwork; generated geometry remains a consumer.
  /// Existing artboards retain their source role. A custom source needs no solid.
  public func isIndependentFlatArtworkSource(_ object:ProductObject)->Bool {
    guard !object.isCanvasWorkspace,object.artworkSourceID==nil,object.artwork != nil,
      !object.isFlexibleSurface,!PaperConstruction.isPaper(object),object.cadModel==nil,
      object.meshAsset==nil,object.asset==nil else{return false}
    if object.recipeID=="artboard" {return true}
    return recipes.contains{$0.id==object.recipeID && $0.parts.isEmpty && $0.solid==nil}
  }
}
