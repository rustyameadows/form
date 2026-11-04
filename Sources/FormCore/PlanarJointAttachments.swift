import Foundation
import FormCADModel

public struct PlanarJointSurfaceRegion:Codable,Equatable,Sendable {
  public var polygon:[CADExpressionPoint2]
  public var side:PaperFinishAssignment.Side
  /// When present, polygon coordinates are (distance along edge, distance through stock)
  /// rather than canonical net coordinates. This can declare a real cut-edge bond.
  public var edgeIndex:Int?
  public init(polygon:[CADExpressionPoint2],side:PaperFinishAssignment.Side = .outside,edgeIndex:Int?=nil){self.polygon=polygon;self.side=side;self.edgeIndex=edgeIndex}
}
public struct PlanarAttachmentInstallation:Codable,Equatable,Sendable {
  public var order:Int
  public var stage:String
  /// Exact pieces present when installed; later coverings remain separate source pieces.
  public var presentComponentIDs:[String]
  public var coveredByComponentIDs:[String]?
  public init(order:Int=0,stage:String="Before covering",presentComponentIDs:[String],coveredByComponentIDs:[String]?=nil) {
    self.order=order;self.stage=stage;self.presentComponentIDs=presentComponentIDs;self.coveredByComponentIDs=coveredByComponentIDs
  }
}
public struct PlanarAdhesiveDefinition:Codable,Equatable,Sendable {
  public var identity:String
  public var thicknessMM:CADScalar,coverage:CADScalar
  public var firstRegion:PlanarJointSurfaceRegion,secondRegion:PlanarJointSurfaceRegion
  public var firstExclusions:[[CADExpressionPoint2]]?,secondExclusions:[[CADExpressionPoint2]]?
  public init(identity:String,thicknessMM:CADScalar=0.05,coverage:CADScalar=1,firstRegion:PlanarJointSurfaceRegion,secondRegion:PlanarJointSurfaceRegion,firstExclusions:[[CADExpressionPoint2]]?=nil,secondExclusions:[[CADExpressionPoint2]]?=nil) {
    self.identity=identity;self.thicknessMM=thicknessMM;self.coverage=coverage;self.firstRegion=firstRegion;self.secondRegion=secondRegion;self.firstExclusions=firstExclusions;self.secondExclusions=secondExclusions
  }
}
public struct PlanarTapeDefinition:Codable,Equatable,Sendable {
  public enum Axis:String,Codable,Sendable {case x,y}
  public var componentID:String
  public var firstRegion:PlanarJointSurfaceRegion,secondRegion:PlanarJointSurfaceRegion
  public var lengthAxis:Axis
  public var widthMM:CADScalar,lengthMM:CADScalar,overlapMM:CADScalar,endOffsetStartMM:CADScalar,endOffsetEndMM:CADScalar
  public var side:String
  public var bondThicknessMM:CADScalar
  public var installation:PlanarAttachmentInstallation
  public init(componentID:String,firstRegion:PlanarJointSurfaceRegion,secondRegion:PlanarJointSurfaceRegion,lengthAxis:Axis = .x,widthMM:CADScalar,lengthMM:CADScalar,overlapMM:CADScalar=0,endOffsetStartMM:CADScalar=0,endOffsetEndMM:CADScalar=0,side:String="outside",bondThicknessMM:CADScalar=0.05,installation:PlanarAttachmentInstallation) {
    self.componentID=componentID;self.firstRegion=firstRegion;self.secondRegion=secondRegion;self.lengthAxis=lengthAxis;self.widthMM=widthMM;self.lengthMM=lengthMM;self.overlapMM=overlapMM;self.endOffsetStartMM=endOffsetStartMM;self.endOffsetEndMM=endOffsetEndMM;self.side=side;self.bondThicknessMM=bondThicknessMM;self.installation=installation
  }
}
/// Independent board-joint wire fastening. No publication-binding assumptions are inherited.
public struct PlanarStapleDefinition:Codable,Equatable,Identifiable,Sendable {
  public enum Termination:String,Codable,CaseIterable,Sendable {case buried,clinch,exposed}
  public var id:String
  public var entryPanelID:String,receivingPanelID:String
  public var anchor:CADExpressionPoint2
  public var entrySide:PaperFinishAssignment.Side
  public var crownDirection:CADExpressionPoint2
  /// In the entry panel's right-handed (x,-y,zOutside) frame. Nil drives into entrySide.
  public var driveDirection:CADExpressionPoint?
  public var crownWidthMM:CADScalar,wireWidthMM:CADScalar,wireDepthMM:CADScalar,legLengthMM:CADScalar
  public var count:CADScalar,spacingMM:CADScalar
  public var spacingDirection:CADExpressionPoint2?
  public var endMarginMM:CADScalar,minimumReceivingDepthMM:CADScalar,minimumEdgeDistanceMM:CADScalar,maximumJointGapMM:CADScalar
  public var termination:Termination
  public var clinchLengthMM:CADScalar?
  public var tool:String
  public var toolAccessMM:CADScalar,toolClearanceMM:CADScalar
  public var clincherAccessMM:CADScalar?
  public var installation:PlanarAttachmentInstallation
  public var layerComponentIDs:[String]?
  public init(id:String,entryPanelID:String,receivingPanelID:String,anchor:CADExpressionPoint2,
    entrySide:PaperFinishAssignment.Side = .outside,crownDirection:CADExpressionPoint2 = .init(1,0),driveDirection:CADExpressionPoint?=nil,
    crownWidthMM:CADScalar=8,wireWidthMM:CADScalar=0.5,wireDepthMM:CADScalar=0.5,legLengthMM:CADScalar=8,
    count:CADScalar=1,spacingMM:CADScalar=0,spacingDirection:CADExpressionPoint2?=nil,endMarginMM:CADScalar=1,
    minimumReceivingDepthMM:CADScalar=2,minimumEdgeDistanceMM:CADScalar=0.2,maximumJointGapMM:CADScalar=0.2,
    termination:Termination = .buried,clinchLengthMM:CADScalar?=nil,tool:String,
    toolAccessMM:CADScalar=20,toolClearanceMM:CADScalar=2,clincherAccessMM:CADScalar?=nil,installation:PlanarAttachmentInstallation,layerComponentIDs:[String]?=nil) {
    self.id=id;self.entryPanelID=entryPanelID;self.receivingPanelID=receivingPanelID;self.anchor=anchor;self.entrySide=entrySide;self.crownDirection=crownDirection;self.driveDirection=driveDirection
    self.crownWidthMM=crownWidthMM;self.wireWidthMM=wireWidthMM;self.wireDepthMM=wireDepthMM;self.legLengthMM=legLengthMM;self.count=count;self.spacingMM=spacingMM;self.spacingDirection=spacingDirection;self.endMarginMM=endMarginMM;self.minimumReceivingDepthMM=minimumReceivingDepthMM;self.minimumEdgeDistanceMM=minimumEdgeDistanceMM;self.maximumJointGapMM=maximumJointGapMM
    self.termination=termination;self.clinchLengthMM=clinchLengthMM;self.tool=tool;self.toolAccessMM=toolAccessMM;self.toolClearanceMM=toolClearanceMM;self.clincherAccessMM=clincherAccessMM;self.installation=installation;self.layerComponentIDs=layerComponentIDs
  }
}
public struct PlanarJointAttachmentDefinition:Codable,Equatable,Identifiable,Sendable {
  public var id:String,joinID:String
  public var enabled:CADScalar?
  public var adhesive:PlanarAdhesiveDefinition?
  public var tape:PlanarTapeDefinition?
  public var staples:[PlanarStapleDefinition]?
  public init(id:String,joinID:String,enabled:CADScalar?=nil,adhesive:PlanarAdhesiveDefinition?=nil,tape:PlanarTapeDefinition?=nil,staples:[PlanarStapleDefinition]?=nil) {
    self.id=id;self.joinID=joinID;self.enabled=enabled;self.adhesive=adhesive;self.tape=tape;self.staples=staples
  }
}
public struct PlanarMaterialInterval:Codable,Equatable,Sendable {
  public var panelID:String,componentID:String?
  public var entryMM:Double,exitMM:Double
}
public struct ResolvedPlanarJointRegion:Codable,Equatable,Sendable {
  public var panelID:String,componentID:String?
  public var side:PaperFinishAssignment.Side
  /// Nil uses canonical net coordinates. A cut-edge region uses distance along
  /// that edge and distance through the actual stock, both in millimeters.
  public var edgeIndex:Int?
  public var coordinatesMM:[Point2]
  public var pointsMM:[Vector3]
}
public struct ResolvedPlanarWireBoundary:Codable,Equatable,Sendable {
  public enum Surface:String,Codable,Sendable {case outside,inside,cutEdge}
  public var panelID:String,componentID:String?
  public var surface:Surface
  public var edgeIndex:Int?,cutoutID:String?
  /// Right-handed canonical panel coordinates, before the physical part pose.
  public var panelPointMM:Vector3
  public var pointMM:Vector3
}
public struct ResolvedPlanarStaple:Codable,Equatable,Identifiable,Sendable {
  public var id:String,jointID:String,definitionID:String
  public var instanceIndex:Int
  public var entryPanelID:String,receivingPanelID:String
  public var pointsMM:[Vector3]
  public var wireWidthMM:Double,wireDepthMM:Double,legLengthMM:Double,crownWidthMM:Double
  public var legMaterialIntervals:[[PlanarMaterialInterval]]
  public var termination:PlanarStapleDefinition.Termination
  public var tool:String,installation:PlanarAttachmentInstallation
  public var sourceAnchorMM:Point2,instanceAnchorMM:Point2
  public var entrySide:PaperFinishAssignment.Side
  public var crownDirection:Vector3,driveDirection:Vector3,spacingDirection:Vector3
  public var definitionCount:Int,spacingMM:Double
  public var endMarginMM:Double,minimumReceivingDepthMM:Double,minimumEdgeDistanceMM:Double,maximumJointGapMM:Double
  public var toolAccessMM:Double,toolClearanceMM:Double,clincherAccessMM:Double?,clinchLengthMM:Double?
  public var layerComponentIDs:[String]
  public var receivingEntryBoundaries:[ResolvedPlanarWireBoundary]
  /// The receiving solid's through-exit boundary. A buried leg deliberately
  /// stops before this boundary; this does not assert an actual exposed exit.
  public var receivingThroughExitBoundaries:[ResolvedPlanarWireBoundary]
  public var engagementFrame:String = "closedInstalledAssembly"
}
public struct ResolvedPlanarTape:Codable,Equatable,Identifiable,Sendable {
  public var id:String,jointID:String,componentID:String
  public var widthMM:Double,lengthMM:Double,overlapMM:Double,endOffsetStartMM:Double,endOffsetEndMM:Double
  public var stock:PaperStock
  public var quantity:Int
  public var side:String,installation:PlanarAttachmentInstallation
  public var lengthAxis:PlanarTapeDefinition.Axis,bondThicknessMM:Double
  public var firstTarget:ResolvedPlanarJointRegion,secondTarget:ResolvedPlanarJointRegion
}
public struct ResolvedPlanarAdhesive:Codable,Equatable,Identifiable,Sendable {
  public var id:String,jointID:String,identity:String
  public var thicknessMM:Double,coverage:Double
  public var firstPanelID:String,secondPanelID:String
  public var firstRegionMM:[Point2],secondRegionMM:[Point2]
  public var firstExclusionsMM:[[Point2]],secondExclusionsMM:[[Point2]]
  public var firstTarget:ResolvedPlanarJointRegion,secondTarget:ResolvedPlanarJointRegion
}
public struct ResolvedPlanarAttachments:Codable,Equatable,Sendable {
  public var tapes:[ResolvedPlanarTape],staples:[ResolvedPlanarStaple],adhesives:[ResolvedPlanarAdhesive]
  public init(tapes:[ResolvedPlanarTape]=[],staples:[ResolvedPlanarStaple]=[],adhesives:[ResolvedPlanarAdhesive]=[]) {self.tapes=tapes;self.staples=staples;self.adhesives=adhesives}
}
