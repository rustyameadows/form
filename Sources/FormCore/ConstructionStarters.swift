import CryptoKit
import Foundation
import FormCADModel

/// Portable artwork belonging to a declarative construction starter. Width and
/// height resolve from that construction's parameters/aliases, never image-fit.
public struct ConstructionStarterArtworkSource:Codable,Equatable,Sendable {
  public var id:UUID
  public var name:String
  public var width:CADScalar
  public var height:CADScalar
  public var artwork:Artwork
  public var artworkRegions:[PhysicalArtworkRegion]?
  public init(id:UUID=UUID(),name:String,width:CADScalar,height:CADScalar,artwork:Artwork,artworkRegions:[PhysicalArtworkRegion]?=nil) {
    self.id=id;self.name=name;self.width=width;self.height=height;self.artwork=artwork;self.artworkRegions=artworkRegions
  }
}
public struct ConstructionStarter:Codable,Equatable,Identifiable,Sendable {
  public var kind:String
  public var version:Int
  public var id:String
  public var name:String
  public var summary:String
  public var symbol:String
  /// Optional local identity referenced by source declarations; import remaps it.
  public var ownerID:UUID?
  public var definition:PlanarConstructionDefinition
  public var stock:PaperStock
  public var materialID:String?
  public var artwork:Artwork?
  public var artworkSources:[ConstructionStarterArtworkSource]
  public init(id:String,name:String,summary:String="",symbol:String="square.3.layers.3d",ownerID:UUID?=nil,definition:PlanarConstructionDefinition,stock:PaperStock,materialID:String?=nil,artwork:Artwork?=nil,artworkSources:[ConstructionStarterArtworkSource]=[]) {
    kind="constructionStarter";version=1;self.id=id;self.name=name;self.summary=summary;self.symbol=symbol;self.ownerID=ownerID
    self.definition=definition;self.stock=stock;self.materialID=materialID;self.artwork=artwork;self.artworkSources=artworkSources
  }
  private enum CodingKeys:String,CodingKey{case kind,version,id,name,summary,symbol,ownerID,definition,stock,materialID,artwork,artworkSources}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    kind=try c.decodeIfPresent(String.self,forKey:.kind) ?? "constructionStarter"
    version=try c.decodeIfPresent(Int.self,forKey:.version) ?? 1
    id=try c.decode(String.self,forKey:.id);name=try c.decode(String.self,forKey:.name)
    summary=try c.decodeIfPresent(String.self,forKey:.summary) ?? ""
    symbol=try c.decodeIfPresent(String.self,forKey:.symbol) ?? "square.3.layers.3d"
    ownerID=try c.decodeIfPresent(UUID.self,forKey:.ownerID)
    definition=try c.decode(PlanarConstructionDefinition.self,forKey:.definition)
    stock=try c.decode(PaperStock.self,forKey:.stock)
    materialID=try c.decodeIfPresent(String.self,forKey:.materialID)
    artwork=try c.decodeIfPresent(Artwork.self,forKey:.artwork)
    artworkSources=try c.decodeIfPresent([ConstructionStarterArtworkSource].self,forKey:.artworkSources) ?? []
  }
  public func validate()throws {
    guard kind=="constructionStarter",version==1,!id.isEmpty,id.utf8.count<=128,
      !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.utf8.count<=160,
      summary.utf8.count<=4000,!symbol.isEmpty,symbol.utf8.count<=128,artworkSources.count<=128,
      Set(artworkSources.map(\.id)).count==artworkSources.count else {
      throw FormError.invalid("A construction starter needs bounded source metadata and distinct artwork identities.")
    }
    if let ownerID,artworkSources.contains(where:{$0.id==ownerID}) {throw FormError.invalid("A construction owner and its artwork sources need distinct identities.")}
    _=try definition.net();try stock.validate()
    if definition.version>=4 {_=try PlanarAssemblyEnvelope.resolve(ConstructionSourceEditing.paper(definition,stock:stock))}
    if let artwork{try validateArtwork(artwork)}
    let values=try definition.resolvedValues()
    for source in artworkSources {
      guard !source.name.isEmpty,source.name.utf8.count<=256,
        source.width.expression.utf8.count<=256,source.height.expression.utf8.count<=256 else {
        throw FormError.invalid("Starter artwork needs a bounded name and physical dimensions.")
      }
      for scalar in [source.width,source.height] {
        let value=try CADExpression.evaluate(scalar.expression,variables:values)
        guard value.isFinite,(0.01...10000).contains(value) else{throw FormError.invalid("Starter artwork dimensions must resolve to 0.01–10000 mm.")}
      }
      try validateArtwork(source.artwork)
    }
  }
}
public struct ConstructionStarterCatalog:Codable,Equatable,Sendable {
  public var starters:[ConstructionStarter]
  public init(starters:[ConstructionStarter]){self.starters=starters}
  public static func decode(_ data:Data)throws->ConstructionStarter {
    guard data.count<=4*1024*1024 else{throw FormError.invalid("A construction starter exceeds the 4 MiB source bound.")}
    guard let raw=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw FormError.invalid("A construction starter must be a JSON object.")}
    let starter=try JSONDecoder.form.decode(ConstructionStarter.self,from:data)
    try ConstructionToolSchema.validateStarter(raw,decoded:starter);try starter.validate();return starter
  }
  /// Resource names and construction categories are data, not compiled branches.
  /// The kind marker also supports SwiftPM's flattened .process resource layout.
  private static let bundledResult:Result<ConstructionStarterCatalog,Error> = Result {try loadBundled()}
  public static func bundled()throws->ConstructionStarterCatalog {try bundledResult.get()}
  private static func loadBundled()throws->ConstructionStarterCatalog {
    guard let root=Bundle.module.resourceURL else{return .init(starters:[])}
    let urls=(FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects as? [URL] ?? [])
      .filter{$0.pathExtension.lowercased()=="json"}.sorted{$0.path<$1.path}
    var entries=[ConstructionStarter]()
    for url in urls {
      let data=try Data(contentsOf:url,options:.mappedIfSafe)
      guard let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
        object["kind"] as? String=="constructionStarter" else{continue}
      entries.append(try decode(data))
    }
    guard entries.count<=64,Set(entries.map(\.id)).count==entries.count else{throw FormError.invalid("Construction starter catalog contains duplicate identities or too many entries.")}
    return .init(starters:entries)
  }
}
public struct ConstructionStarterImportResult:Codable,Equatable,Sendable {
  public var starterID:String
  public var objectID:UUID
  public var artworkSourceIDs:[UUID]
  public init(starterID:String,objectID:UUID,artworkSourceIDs:[UUID]){self.starterID=starterID;self.objectID=objectID;self.artworkSourceIDs=artworkSourceIDs}
}

public enum ConstructionSourceEditing {
  public static func revision(_ definition:PlanarConstructionDefinition)throws->String {
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
    return SHA256.hash(data:try encoder.encode(definition)).map{String(format:"%02x",$0)}.joined()
  }
  public static func recipe(_ definition:PlanarConstructionDefinition,id:String)->Recipe {
    let labels=Dictionary((definition.controls?.parameters ?? []).map{($0.parameter,$0.label)},uniquingKeysWith:{$1})
    let parameters=definition.parameters.map{Parameter($0.name,labels[$0.name] ?? $0.name,$0.value,$0.minimum...$0.maximum,unit:$0.unit,step:0.1)}
      + [Parameter("fold","Assembly",100,0...100,unit:"%",step:1),Parameter("opening","Opening",0,0...100,unit:"%",step:1)]
      + (definition.version>=4 ? [Parameter("explosion","Explosion",0,0...100,unit:"%",step:1)]:[])
    let names=Set(definition.parameters.map(\.name))
    let requirements=definition.requirements?.filter {requirement in
      guard let lhs=try? CADExpression.referencedNames(in:requirement.lhs.expression),let rhs=try? CADExpression.referencedNames(in:requirement.rhs.expression) else{return false}
      return lhs.union(rhs).isSubset(of:names)
    }
    return Recipe(id,definition.name,"square.3.layers.3d","Editable construction source",parameters,requirements:requirements)
  }
  static func paper(_ definition:PlanarConstructionDefinition,stock:PaperStock)throws->PaperConstruction {
    let net=try definition.net()
    var paper=PaperConstruction(kind:.authored,dimensions:.init(width:definition.values["width"] ?? net.size.x,height:definition.values["height"] ?? net.size.y,depth:definition.values["depth"] ?? 1),stock:stock)
    paper.authored=definition;return paper
  }
  private static func remapped(_ original:ConstructionStarter)throws->ConstructionStarter {
    let object=try JSONSerialization.jsonObject(with:JSONEncoder.form.encode(original))
    var ids=Set<UUID>()
    func collect(_ value:Any) {
      if let map=value as? [String:Any] {
        if let raw=map["id"] as? String,let id=UUID(uuidString:raw){ids.insert(id)}
        for value in map.values{collect(value)}
      }else if let array=value as? [Any]{for value in array{collect(value)}}
    }
    collect(object);if let owner=original.ownerID{ids.insert(owner)}
    let mapping=Dictionary(uniqueKeysWithValues:ids.map{($0,UUID())})
    let contentKeys:Set<String>=["text","name","notes","summary","help","label","expression","asset","url"]
    func replace(_ value:Any,key:String?=nil)->Any {
      if let map=value as? [String:Any]{return Dictionary(uniqueKeysWithValues:map.map{($0.key,replace($0.value,key:$0.key))})}
      if let array=value as? [Any]{return array.map{replace($0,key:key)}}
      if let text=value as? String,!contentKeys.contains(key ?? ""),let id=UUID(uuidString:text),let next=mapping[id]{return next.uuidString}
      return value
    }
    return try JSONDecoder.form.decode(ConstructionStarter.self,from:JSONSerialization.data(withJSONObject:replace(object)))
  }
  static func source(_ source:ConstructionStarterArtworkSource,ownerID:UUID,values:[String:Double],project:inout Project)throws->ProductObject {
    let width=try CADExpression.evaluate(source.width.expression,variables:values),height=try CADExpression.evaluate(source.height.expression,variables:values)
    var names=Set<String>()
    for region in source.artworkRegions ?? [] {for scalar in [region.origin.x,region.origin.y,region.size.x,region.size.y]{names.formUnion(try CADExpression.referencedNames(in:scalar.expression))}}
    names.subtract(["width","depth"])
    guard names.count<=30,names.allSatisfy({values[$0] != nil}) else{throw FormError.invalid("An artwork source uses missing aliases or exceeds its dimension-binding budget.")}
    let recipeID="construction-source-"+source.id.uuidString
    let parameters=[Parameter("width","Width",width,0.01...10000,step:0.1),Parameter("depth","Height",height,0.01...10000,step:0.1)]
      + names.sorted().map{Parameter($0,$0,values[$0]!,-100000...100000,step:0.1)}
    project.recipes.append(Recipe(recipeID,source.name,"square.and.pencil","Canonical physical construction artwork",parameters))
    var object=ProductObject(name:source.name,recipeID:recipeID,parameters:Dictionary(uniqueKeysWithValues:parameters.map{($0.id,$0.value)}),materialID:"paper-superfine",artwork:source.artwork)
    object.id=source.id;object.canvasSourceOnly=true;object.artworkRegions=source.artworkRegions
    func binding(_ target:String,_ scalar:CADScalar)throws->PhysicalDimensionBinding {
      let referenced=try CADExpression.referencedNames(in:scalar.expression).sorted()
      guard referenced.allSatisfy({values[$0] != nil}) else{throw FormError.invalid("Starter source dimensions must reference saved construction parameters or aliases.")}
      var inputs=[String:PhysicalDimensionReference](),renames=[String:String]()
      for (index,name) in referenced.enumerated() {
        var key="sourceValue\(index)";while object.parameters[key] != nil{key="_"+key}
        inputs[key] = .init(sourceObjectID:ownerID,measurement:.parameter,parameter:name);renames[name]=key
      }
      let regex=try NSRegularExpression(pattern:"[A-Za-z_][A-Za-z0-9_]*")
      let original=scalar.expression as NSString;var expression=scalar.expression
      for match in regex.matches(in:scalar.expression,range:NSRange(location:0,length:original.length)).reversed() {
        if let replacement=renames[original.substring(with:match.range)],let range=Range(match.range,in:expression){expression.replaceSubrange(range,with:replacement)}
      }
      return .init(parameter:target,expression:expression,inputs:inputs)
    }
    object.dimensionBindings=try [binding("width",source.width),binding("depth",source.height)]
      + names.sorted().map{try binding($0,CADScalar($0))}
    return object
  }
  public static func importing(_ starter:ConstructionStarter,into original:Project,position:Vector3 = .init())throws->(Project,ConstructionStarterImportResult) {
    guard [position.x,position.y,position.z].allSatisfy({$0.isFinite && abs($0)<=100000}) else{throw FormError.invalid("Construction placement requires three finite bounded millimeter values.")}
    try starter.validate();let starter=try remapped(starter);var project=original
    let id=starter.ownerID ?? UUID(),recipeID="construction-"+id.uuidString
    guard !project.objects.contains(where:{$0.id==id}) else{throw FormError.invalid("The imported construction identity already exists.")}
    let recipe=recipe(starter.definition,id:recipeID),settings=try paper(starter.definition,stock:starter.stock)
    var owner=ProductObject(name:starter.name,recipeID:recipeID,parameters:PaperConstructionEngine.parameters(settings),materialID:starter.materialID ?? "paper-superfine",position:position,artwork:starter.artwork ?? .init(background:"#FFFFFF"))
    if starter.artwork==nil{owner.artwork?.backgroundOpacity=0}
    owner.id=id;owner.paperConstruction=settings
    project.recipes.append(recipe);project.objects.append(owner)
    let values=try starter.definition.resolvedValues()
    for value in starter.artworkSources {
      let artwork=try source(value,ownerID:id,values:values,project:&project);project.objects.append(artwork)
    }
    try project.reconcilePhysicalDimensions(previous:original);try project.validateArtworkLinks()
    return(project,.init(starterID:starter.id,objectID:id,artworkSourceIDs:starter.artworkSources.map(\.id)))
  }
}

extension Project {
  @discardableResult public mutating func importConstructionStarter(_ starter:ConstructionStarter,position:Vector3 = .init())throws->ConstructionStarterImportResult {
    let (candidate,result)=try ConstructionSourceEditing.importing(starter,into:self,position:position);self=candidate;return result
  }
}
