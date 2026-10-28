import Foundation

public struct PaperDimensions:Codable,Equatable,Sendable {
  /// Finished usable internal millimeters, before the declared contents clearance check.
  public var width:Double,height:Double,depth:Double
  public init(width:Double,height:Double,depth:Double){self.width=width;self.height=height;self.depth=depth}
}
public struct PaperStock:Codable,Equatable,Sendable {
  public enum Grain:String,Codable,CaseIterable,Sendable{case parallelHeight,parallelWidth,unknown}
  public var name:String,vendor:String?,gsm:Double?,thicknessMM:Double,grain:Grain,sheetSizeMM:Point2?,verified:Bool,notes:String
  public init(name:String="Uncoated paperboard",vendor:String?=nil,gsm:Double?=300,thicknessMM:Double=0.35,grain:Grain = .unknown,sheetSizeMM:Point2?=nil,verified:Bool=false,notes:String="Prototype assumptions; verify the chosen stock and crease tooling."){self.name=name;self.vendor=vendor;self.gsm=gsm;self.thicknessMM=thicknessMM;self.grain=grain;self.sheetSizeMM=sheetSizeMM;self.verified=verified;self.notes=notes}
}
public struct PaperAnnotation:Codable,Equatable,Identifiable,Sendable {
  public enum Kind:String,Codable,CaseIterable,Sendable{case note,measurement,assembly}
  public var id:UUID,kind:Kind,text:String,panelID:String?,edgeID:String?,position:Point2?,view:String?
  public init(id:UUID=UUID(),kind:Kind = .note,text:String,panelID:String?=nil,edgeID:String?=nil,position:Point2?=nil,view:String?=nil){self.id=id;self.kind=kind;self.text=text;self.panelID=panelID;self.edgeID=edgeID;self.position=position;self.view=view}
}
public struct PaperBounds:Codable,Equatable,Sendable {
  public var x:Double,y:Double,width:Double,height:Double
  public init(x:Double,y:Double,width:Double,height:Double){self.x=x;self.y=y;self.width=width;self.height=height}
  public var minimum:Point2{.init(x,y)};public var maximum:Point2{.init(x+width,y+height)}
}
public struct PaperPanel:Codable,Equatable,Identifiable,Sendable {
  public enum Role:String,Codable,Sendable{case body,side,glue,tuck,dust,bottomClosure}
  public var id:String,name:String,role:Role,polygon:[Point2],parentID:String?,foldID:String?
  public init(id:String,name:String,role:Role,polygon:[Point2],parentID:String?=nil,foldID:String?=nil){self.id=id;self.name=name;self.role=role;self.polygon=polygon;self.parentID=parentID;self.foldID=foldID}
  public var bounds:PaperBounds{let xs=polygon.map(\.x),ys=polygon.map(\.y),x=xs.min() ?? 0,y=ys.min() ?? 0;return .init(x:x,y:y,width:(xs.max() ?? x)-x,height:(ys.max() ?? y)-y)}
}
public struct PaperFold:Codable,Equatable,Identifiable,Sendable {
  public var id:String,parentPanelID:String,childPanelID:String,start:Point2,end:Point2,angleDegrees:Double
  public init(id:String,parentPanelID:String,childPanelID:String,start:Point2,end:Point2,angleDegrees:Double){self.id=id;self.parentPanelID=parentPanelID;self.childPanelID=childPanelID;self.start=start;self.end=end;self.angleDegrees=angleDegrees}
}
public struct PaperEdge:Codable,Equatable,Identifiable,Sendable {
  public var id:String,panelID:String,start:Point2,end:Point2
  public init(id:String,panelID:String,start:Point2,end:Point2){self.id=id;self.panelID=panelID;self.start=start;self.end=end}
}
public struct PaperJoin:Codable,Equatable,Identifiable,Sendable {
  public var id:String,name:String,firstPanelID:String,secondPanelID:String,kind:String,overlapMM:Double,notes:String
  public init(id:String,name:String,firstPanelID:String,secondPanelID:String,kind:String="glue",overlapMM:Double,notes:String=""){self.id=id;self.name=name;self.firstPanelID=firstPanelID;self.secondPanelID=secondPanelID;self.kind=kind;self.overlapMM=overlapMM;self.notes=notes}
}
public struct PaperResolvedPanel:Codable,Equatable,Sendable {
  public var panelID:String
  /// Row-major rigid matrix. Input is RIGHT-HANDED flat3D (canonical.x,-canonical.y,zOutside).
  /// Outside +z maps to +Y at fold0; canonical y-down maps to world+Z / Top-view down.
  public var flatToWorld:[Double]
  public init(panelID:String,flatToWorld:[Double]){self.panelID=panelID;self.flatToWorld=flatToWorld}
}
public struct PaperPreflightIssue:Codable,Equatable,Identifiable,Sendable {
  public enum Severity:String,Codable,Sendable{case info,warning,error}
  public var id:String,severity:Severity,code:String,message:String,panelIDs:[String]
  public init(id:String?=nil,severity:Severity,code:String,message:String,panelIDs:[String]=[]){self.id=id ?? code;self.severity=severity;self.code=code;self.message=message;self.panelIDs=panelIDs}
}
public struct PaperPreflight:Codable,Equatable,Sendable {
  public var issues:[PaperPreflightIssue],netSize:Point2,usableInternalDimensions:PaperDimensions,requiresArtworkReview:Bool
  public var hasErrors:Bool{issues.contains{$0.severity == .error}}
  public init(issues:[PaperPreflightIssue],netSize:Point2,usableInternalDimensions:PaperDimensions,requiresArtworkReview:Bool){self.issues=issues;self.netSize=netSize;self.usableInternalDimensions=usableInternalDimensions;self.requiresArtworkReview=requiresArtworkReview}
}
public struct PaperLayoutPlacement:Codable,Equatable,Identifiable,Sendable {
  public var id:Int,sheetIndex:Int,origin:Point2,rotationDegrees:Double,bounds:PaperBounds
  public init(id:Int,sheetIndex:Int,origin:Point2,rotationDegrees:Double,bounds:PaperBounds){self.id=id;self.sheetIndex=sheetIndex;self.origin=origin;self.rotationDegrees=rotationDegrees;self.bounds=bounds}
}
public struct PaperLayout:Codable,Equatable,Sendable {
  public var sheetSize:Point2,marginMM:Double,gapMM:Double,count:Int,placements:[PaperLayoutPlacement],sheetCount:Int,wasteFraction:Double,issues:[PaperPreflightIssue]
  public var hasErrors:Bool{issues.contains{$0.severity == .error}}
  public init(sheetSize:Point2,marginMM:Double,gapMM:Double,count:Int,placements:[PaperLayoutPlacement],sheetCount:Int,wasteFraction:Double,issues:[PaperPreflightIssue]){self.sheetSize=sheetSize;self.marginMM=marginMM;self.gapMM=gapMM;self.count=count;self.placements=placements;self.sheetCount=sheetCount;self.wasteFraction=wasteFraction;self.issues=issues}
}
public struct PaperNet:Codable,Equatable,Sendable {
  public var size:Point2,panels:[PaperPanel],folds:[PaperFold],joins:[PaperJoin],cutEdges:[PaperEdge],rootPanelID:String
  public init(size:Point2,panels:[PaperPanel],folds:[PaperFold],joins:[PaperJoin],cutEdges:[PaperEdge],rootPanelID:String="front"){self.size=size;self.panels=panels;self.folds=folds;self.joins=joins;self.cutEdges=cutEdges;self.rootPanelID=rootPanelID}
  public var bounds:PaperBounds{.init(x:0,y:0,width:size.x,height:size.y)}
}
public struct PaperConstruction:Codable,Equatable,Sendable {
  public enum Kind:String,Codable,CaseIterable,Sendable{case envelope,straightTuckCarton}
  public var version:Int=1
  public var kind:Kind,dimensions:PaperDimensions,stock:PaperStock,clearanceMM:Double,glueTabMM:Double,topFlapMM:Double,bottomFlapMM:Double,cornerRadiusMM:Double,foldPercent:Double,openingPercent:Double
  public var insideArtworkSourceID:UUID?,insideArtwork:Artwork?,annotations:[PaperAnnotation],artworkReviewRequired:Bool,artworkReferenceSize:Point2?
  public init(kind:Kind,dimensions:PaperDimensions,stock:PaperStock = .init(),clearanceMM:Double=2,glueTabMM:Double=16,topFlapMM:Double=38,bottomFlapMM:Double=30,cornerRadiusMM:Double=4,foldPercent:Double=100,openingPercent:Double=0,insideArtworkSourceID:UUID?=nil,insideArtwork:Artwork?=nil,annotations:[PaperAnnotation]=[],artworkReviewRequired:Bool=false,artworkReferenceSize:Point2?=nil){self.kind=kind;self.dimensions=dimensions;self.stock=stock;self.clearanceMM=clearanceMM;self.glueTabMM=glueTabMM;self.topFlapMM=topFlapMM;self.bottomFlapMM=bottomFlapMM;self.cornerRadiusMM=cornerRadiusMM;self.foldPercent=foldPercent;self.openingPercent=openingPercent;self.insideArtworkSourceID=insideArtworkSourceID;self.insideArtwork=insideArtwork;self.annotations=annotations;self.artworkReviewRequired=artworkReviewRequired;self.artworkReferenceSize=artworkReferenceSize}
  enum CodingKeys:String,CodingKey{case version,kind,dimensions,stock,clearanceMM,glueTabMM,topFlapMM,bottomFlapMM,cornerRadiusMM,foldPercent,openingPercent,insideArtworkSourceID,insideArtwork,annotations,artworkReviewRequired,artworkReferenceSize}
  public init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);version=try c.decodeIfPresent(Int.self,forKey:.version) ?? 1;kind=try c.decode(Kind.self,forKey:.kind);dimensions=try c.decode(PaperDimensions.self,forKey:.dimensions);stock=try c.decode(PaperStock.self,forKey:.stock);clearanceMM=try c.decode(Double.self,forKey:.clearanceMM);glueTabMM=try c.decode(Double.self,forKey:.glueTabMM);topFlapMM=try c.decode(Double.self,forKey:.topFlapMM);bottomFlapMM=try c.decode(Double.self,forKey:.bottomFlapMM);cornerRadiusMM=try c.decode(Double.self,forKey:.cornerRadiusMM);foldPercent=try c.decode(Double.self,forKey:.foldPercent);openingPercent=try c.decodeIfPresent(Double.self,forKey:.openingPercent) ?? 0;insideArtworkSourceID=try c.decodeIfPresent(UUID.self,forKey:.insideArtworkSourceID);insideArtwork=try c.decodeIfPresent(Artwork.self,forKey:.insideArtwork);annotations=try c.decodeIfPresent([PaperAnnotation].self,forKey:.annotations) ?? [];artworkReviewRequired=try c.decodeIfPresent(Bool.self,forKey:.artworkReviewRequired) ?? false;artworkReferenceSize=try c.decodeIfPresent(Point2.self,forKey:.artworkReferenceSize)}
  public static let recipeIDs:Set<String>=["paperEnvelope","tuckCarton"]
  public static func isPaper(_ object:ProductObject)->Bool{object.paperConstruction != nil || recipeIDs.contains(object.recipeID)}
  public static func definition(for object:ProductObject)throws->PaperConstruction{try PaperConstructionEngine.definition(for:object)}
  public func net()throws->PaperNet{try PaperConstructionEngine.net(self)}
  public func resolvedPanels(foldPercent:Double?=nil)throws->[PaperResolvedPanel]{try PaperConstructionEngine.resolvedPanels(self,foldPercent:foldPercent)}
  public func preflight(contents:PaperDimensions?=nil)throws->PaperPreflight{try PaperConstructionEngine.preflight(self,contents:contents)}
}
