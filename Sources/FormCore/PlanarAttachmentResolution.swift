import Foundation
import FormCADModel

extension PlanarConstructionDefinition {
  func attachmentEnabled(_ expression:CADScalar?,values:[String:Double]?=nil)throws->Bool {
    guard let expression else{return true};let value=try CADExpression.evaluate(expression.expression,variables:values ?? resolvedValues())
    guard abs(value)<1e-9 || abs(value-1)<1e-9 else{throw FormError.invalid("Joint attachment enabled must resolve to zero or one.")};return value>0.5
  }
  func validateAttachmentMetadata(values:[String:Double]?=nil)throws {
    let declarations=jointAttachments ?? []
    guard !declarations.isEmpty else{return}
    let variables=try values ?? resolvedValues()
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:variables)}
    guard declarations.count<=256,Set(declarations.map(\.id)).count==declarations.count,
      declarations.reduce(0,{$0+($1.staples?.count ?? 0)})<=256,
      Set(declarations.flatMap{$0.staples ?? []}.map(\.id)).count==declarations.reduce(0,{$0+($1.staples?.count ?? 0)}) else{throw FormError.invalid("Use at most256 distinct attachment records and256 staple definitions.")}
    let pieceIDs=Set((components ?? []).map(\.id)),panelIDs=Set(panels.map(\.id)),ownership=try componentPanels()
    let panelOwners=Dictionary(uniqueKeysWithValues:ownership.flatMap{key,value in value.map{($0,key)}})
    func installation(_ value:PlanarAttachmentInstallation)throws {
      guard (0...10000).contains(value.order),!value.stage.isEmpty,value.stage.utf8.count<=160,
        !value.presentComponentIDs.isEmpty,value.presentComponentIDs.count<=128,Set(value.presentComponentIDs).count==value.presentComponentIDs.count,
        Set(value.presentComponentIDs).isSubset(of:pieceIDs),(value.coveredByComponentIDs?.count ?? 0)<=128,
        Set(value.coveredByComponentIDs ?? []).count==(value.coveredByComponentIDs?.count ?? 0),
        Set(value.coveredByComponentIDs ?? []).isSubset(of:pieceIDs),Set(value.presentComponentIDs).isDisjoint(with:Set(value.coveredByComponentIDs ?? [])) else {
        throw FormError.invalid("Attachment installation needs explicit existing pieces, bounded order/stage and distinct later coverings.")
      }
    }
    for declaration in declarations {
      guard !declaration.id.isEmpty,declaration.id.utf8.count<=128,let join=joins.first(where:{$0.id==declaration.joinID}),
        declaration.adhesive != nil || declaration.tape != nil || declaration.staples?.isEmpty == false else{throw FormError.invalid("Each attachment needs a stable identity, existing join and a declared attachment method.")}
      _ = try attachmentEnabled(declaration.enabled,values:variables)
      if let adhesive=declaration.adhesive {
        guard !adhesive.identity.isEmpty,adhesive.identity.utf8.count<=256,(0...2).contains(try number(adhesive.thicknessMM)),(0...1).contains(try number(adhesive.coverage)),
          (adhesive.firstExclusions?.count ?? 0)<=16,(adhesive.secondExclusions?.count ?? 0)<=16 else{throw FormError.invalid("Adhesive needs identity,0–2mm effective thickness and0–1 coverage with bounded exclusions.")}
      }
      if let tape=declaration.tape {
        guard pieceIDs.contains(tape.componentID),["inside","outside","edge"].contains(tape.side),
          (0.01...10000).contains(try number(tape.widthMM)),(0.01...10000).contains(try number(tape.lengthMM)),
          (0...1000).contains(try number(tape.overlapMM)),(0...10000).contains(try number(tape.endOffsetStartMM)),(0...10000).contains(try number(tape.endOffsetEndMM)),
          (0...2).contains(try number(tape.bondThicknessMM)) else{throw FormError.invalid("Tape must identify an actual cut piece and finite physical strip dimensions/placement.")}
        try installation(tape.installation)
        guard tape.installation.presentComponentIDs.contains(tape.componentID) else{throw FormError.invalid("The tape piece must be present at its declared installation.")}
      }
      guard (declaration.staples?.count ?? 0)<=64,Set((declaration.staples ?? []).map(\.id)).count==(declaration.staples?.count ?? 0) else{throw FormError.invalid("Each attachment supports at most64 uniquely identified staple definitions.")}
      for staple in declaration.staples ?? [] {
        guard !staple.id.isEmpty,staple.id.utf8.count<=128,panelIDs.contains(staple.entryPanelID),panelIDs.contains(staple.receivingPanelID),
          Set([staple.entryPanelID,staple.receivingPanelID])==Set([join.firstPanelID,join.secondPanelID]),
          !staple.tool.isEmpty,staple.tool.utf8.count<=256 else{throw FormError.invalid("A board staple must target both actual joined panels and declare its tool.")}
        let count=try number(staple.count),wire=max(try number(staple.wireWidthMM),try number(staple.wireDepthMM)),crown=try number(staple.crownWidthMM)
        guard (1...64).contains(count),abs(count-count.rounded())<1e-9,(0.05...4).contains(try number(staple.wireWidthMM)),
          (0.05...4).contains(try number(staple.wireDepthMM)),(0.5...100).contains(crown),crown>wire*2,
          (0.1...100).contains(try number(staple.legLengthMM)),(0...10000).contains(try number(staple.spacingMM)),
          (0...50).contains(try number(staple.endMarginMM)),(0.01...100).contains(try number(staple.minimumReceivingDepthMM)),
          (0...20).contains(try number(staple.minimumEdgeDistanceMM)),(0...2).contains(try number(staple.maximumJointGapMM)),
          (0.1...1000).contains(try number(staple.toolAccessMM)),(0...100).contains(try number(staple.toolClearanceMM)),
          staple.layerComponentIDs.map({$0.count<=128}) ?? true else{throw FormError.invalid("Board staple dimensions, counts, margins and access must be finite and within declared physical bounds.")}
        if let length=staple.clinchLengthMM {guard (0.01...100).contains(try number(length)) else{throw FormError.invalid("Clinch length must be positive and bounded.")}}
        if let access=staple.clincherAccessMM {guard (0.01...1000).contains(try number(access)) else{throw FormError.invalid("Clincher access must be positive and bounded.")}}
        try installation(staple.installation)
        let present=Set(staple.installation.presentComponentIDs),layers=Set(staple.layerComponentIDs ?? [])
        guard layers.count==(staple.layerComponentIDs?.count ?? 0),layers.isSubset(of:present),
          [staple.entryPanelID,staple.receivingPanelID].allSatisfy({panelOwners[$0].map(present.contains) ?? false}) else {
          throw FormError.invalid("Staple installation must include both joined board pieces and every declared additional layer.")
        }
        if staple.termination == .clinch {guard staple.clinchLengthMM != nil,staple.clincherAccessMM != nil else{throw FormError.invalid("Clinched staples require a declared clinch length and clincher access.")}}
      }
    }
  }

  /// Resolve the actual accepted structure at rest for engagement, and map the
  /// same source anchors into the requested presentation. No document is edited.
  public func resolveJointAttachments(stock:PaperStock,foldPercent:Double=100,openingPercent:Double=0,
    explosionPercent:Double=0,validateEngagement:Bool=true)throws->ResolvedPlanarAttachments {
    guard jointAttachments?.isEmpty == false else{return .init()}
    let values=try resolvedValues()
    func number(_ scalar:CADScalar)throws->Double {try CADExpression.evaluate(scalar.expression,variables:values)}
    try validateAttachmentMetadata(values:values)
    let context=try PlanarAssemblySourceContext(self,values:values,fallbackStock:stock),net=try net()
    let activePieces=(components ?? []).filter{context.enabledIDs.contains($0.id)},activeIDs=context.enabledIDs
    var closed=PaperConstruction(kind:.authored,dimensions:.init(width:1,height:1,depth:1),stock:stock,foldPercent:100,openingPercent:0,explosionPercent:0);closed.authored=self
    var current=closed;current.foldPercent=foldPercent;current.openingPercent=openingPercent;current.explosionPercent=explosionPercent
    let closedPoses=try PlanarComponentPoseResolver.resolve(closed,net:net,amount:1).panels
    let currentPoses=try PlanarComponentPoseResolver.resolve(current,net:net,amount:foldPercent/100).panels
    let oldMatrices=Dictionary(uniqueKeysWithValues:closedPoses.map{($0.panelID,$0.flatToWorld)}),newMatrices=Dictionary(uniqueKeysWithValues:currentPoses.map{($0.panelID,$0.flatToWorld)})
    let prisms=try net.panels.map {panel->PlanarJointGeometry.Prism in
      var material=try panel.resolvedStock(fallback:stock)
      if let thickness=panel.features?.stockThickness {material=try Self.resizedStock(material,thickness:CADExpression.evaluate(thickness.expression,variables:values))}
      let simple=panel.features?.flex==nil && panel.features?.wrap==nil && panel.features?.recesses?.isEmpty != false
      return .init(panel:panel,matrix:oldMatrices[panel.id]!,stock:material,rigidReceivingSupported:simple)
    }
    let byID=Dictionary(uniqueKeysWithValues:prisms.map{($0.panel.id,$0)})
    var result=ResolvedPlanarAttachments()
    typealias G=PlanarJointGeometry
    func target(_ source:PlanarJointSurfaceRegion,_ prism:G.Prism,_ resolved:(flat:[Point2],world:[Vector3]))throws->ResolvedPlanarJointRegion {
      guard let current=newMatrices[prism.panel.id] else{throw FormError.invalid("A scheduled attachment lost its target material pose.")}
      return .init(panelID:prism.panel.id,componentID:prism.panel.componentID,side:source.side,edgeIndex:source.edgeIndex,
        coordinatesMM:resolved.flat,pointsMM:resolved.world.map{PaperRigidMatrix.point(current,G.inversePoint(prism.matrix,$0))})
    }
    for declaration in jointAttachments ?? [] where try attachmentEnabled(declaration.enabled,values:values) {
      guard let join=net.joins.first(where:{$0.id==declaration.joinID}),let first=byID[join.firstPanelID],let second=byID[join.secondPanelID] else {
        throw FormError.invalid("Active attachment '\(declaration.id)' targets a disabled join or cut piece.")
      }
      if let adhesive=declaration.adhesive {
        let a=try G.regions(adhesive.firstRegion,prism:first,values:values),b=try G.regions(adhesive.secondRegion,prism:second,values:values)
        let thickness=try number(adhesive.thicknessMM)
        if validateEngagement {try validateBondContact(a.world,b.world,thickness:thickness,id:declaration.id)}
        func exclusions(_ raw:[[CADExpressionPoint2]]?,within region:[Point2])throws->[[Point2]] {
          try (raw ?? []).map {points in
            let p=try points.map{try Point2(number($0.x),number($0.y))}
            guard p.count<=16,Self.validJointRegion(p),abs(try G.intersectionArea([p],[region])-G.area(p))<=0.01 else{throw FormError.invalid("Glue exclusion must fit its declared bonded region.")};return p
          }
        }
        result.adhesives.append(.init(id:declaration.id,jointID:join.id,identity:adhesive.identity,thicknessMM:thickness,coverage:try number(adhesive.coverage),firstPanelID:first.panel.id,secondPanelID:second.panel.id,firstRegionMM:a.flat,secondRegionMM:b.flat,firstExclusionsMM:try exclusions(adhesive.firstExclusions,within:a.flat),secondExclusionsMM:try exclusions(adhesive.secondExclusions,within:b.flat),firstTarget:try target(adhesive.firstRegion,first,a),secondTarget:try target(adhesive.secondRegion,second,b)))
      }
      if let tape=declaration.tape {
        guard activeIDs.contains(tape.componentID),let component=activePieces.first(where:{$0.id==tape.componentID}) else{throw FormError.invalid("Active tape '\(declaration.id)' references a disabled physical strip.")}
        try validateActiveInstallation(tape.installation,activeIDs:activeIDs)
        guard let bounds=context.bounds[tape.componentID] else{throw FormError.invalid("A tape schedule lost its actual cut-piece bounds.")}
        let width=try number(tape.widthMM),length=try number(tape.lengthMM)
        let actualLength=tape.lengthAxis == .x ? bounds.width:bounds.height,actualWidth=tape.lengthAxis == .x ? bounds.height:bounds.width
        guard abs(actualLength-length)<=0.01,abs(actualWidth-width)<=0.01,try number(tape.overlapMM)<=length,
          try number(tape.endOffsetStartMM)+number(tape.endOffsetEndMM)<length else{throw FormError.invalid("Tape schedule dimensions must equal its actual flat cut piece and leave positive seam coverage.")}
        let a=try G.regions(tape.firstRegion,prism:first,values:values),b=try G.regions(tape.secondRegion,prism:second,values:values)
        if validateEngagement {
          let targets=[a.world,b.world]
          let physical=prisms.filter{$0.panel.componentID==tape.componentID},bond=try number(tape.bondThicknessMM)
          for region in targets {guard try tapeCovers(region,with:physical,bond:bond) else{throw FormError.invalid("Tape '\(declaration.id)' does not physically cover both declared joined-face regions.")}}
        }
        guard let stripStock=context.stocks[component.id] else{throw FormError.invalid("A tape schedule lost its actual physical stock.")}
        result.tapes.append(.init(id:declaration.id,jointID:join.id,componentID:tape.componentID,widthMM:width,lengthMM:length,overlapMM:try number(tape.overlapMM),endOffsetStartMM:try number(tape.endOffsetStartMM),endOffsetEndMM:try number(tape.endOffsetEndMM),stock:stripStock,quantity:component.quantity ?? 1,side:tape.side,installation:tape.installation,lengthAxis:tape.lengthAxis,bondThicknessMM:try number(tape.bondThicknessMM),firstTarget:try target(tape.firstRegion,first,a),secondTarget:try target(tape.secondRegion,second,b)))
      }
      for staple in declaration.staples ?? [] {
        try validateActiveInstallation(staple.installation,activeIDs:activeIDs)
        guard let entry=byID[staple.entryPanelID],let receiving=byID[staple.receivingPanelID],let currentMatrix=newMatrices[staple.entryPanelID] else{throw FormError.invalid("Staple '\(staple.id)' has a disabled receiving path.")}
        guard entry.rigidReceivingSupported,receiving.rigidReceivingSupported else{throw FormError.invalid("Staple '\(staple.id)' receiving geometry must be explicit rigid pieces; curved, wrapped or recessed targets require separate actual layers.")}
        let source=try resolveStaple(staple,jointID:join.id,entry:entry,receiving:receiving,prisms:prisms,values:values,validate:validateEngagement)
        for var instance in source {
          instance.pointsMM=instance.pointsMM.map {p in PaperRigidMatrix.point(currentMatrix,G.inversePoint(entry.matrix,p))}
          instance.crownDirection=G.vector(currentMatrix,G.inverseVector(entry.matrix,instance.crownDirection))
          instance.driveDirection=G.vector(currentMatrix,G.inverseVector(entry.matrix,instance.driveDirection))
          instance.spacingDirection=G.vector(currentMatrix,G.inverseVector(entry.matrix,instance.spacingDirection))
          func boundary(_ original:ResolvedPlanarWireBoundary)throws->ResolvedPlanarWireBoundary {
            guard let matrix=newMatrices[original.panelID] else{throw FormError.invalid("A scheduled wire boundary lost its receiving material pose.")}
            var value=original;value.pointMM=PaperRigidMatrix.point(matrix,original.panelPointMM);return value
          }
          instance.receivingEntryBoundaries=try instance.receivingEntryBoundaries.map(boundary)
          instance.receivingThroughExitBoundaries=try instance.receivingThroughExitBoundaries.map(boundary)
          result.staples.append(instance)
        }
        guard result.staples.count<=512 else{throw FormError.invalid("Construction fasteners exceed512 actual staple instances.")}
      }
    }
    return result
  }
  private func validateActiveInstallation(_ installation:PlanarAttachmentInstallation,activeIDs:Set<String>)throws {
    guard Set(installation.presentComponentIDs).isSubset(of:activeIDs) else{throw FormError.invalid("Attachment installation references a disabled material layer; repair its installed stack explicitly.")}
  }
  private func validateBondContact(_ a:[Vector3],_ b:[Vector3],thickness:Double,id:String)throws {
    typealias G=PlanarJointGeometry
    let u=try G.unit(G.sub(a[1],a[0])),normal=try G.unit(G.cross(G.sub(a[1],a[0]),G.sub(a[2],a[0]))),v=G.cross(normal,u)
    guard b.allSatisfy({abs(G.dot(G.sub($0,a[0]),normal))<=thickness+0.02}) else{throw FormError.invalid("Bond '\(id)' declared faces are separated beyond the effective adhesive allowance.")}
    func projected(_ p:[Vector3])->[Point2] {p.map{let d=G.sub($0,a[0]);return .init(G.dot(d,u),G.dot(d,v))}}
    guard try G.intersectionArea([projected(a)],[projected(b)])>0.001 else{throw FormError.invalid("Bond '\(id)' has no actual overlapping contact region.")}
  }
  private func tapeCovers(_ world:[Vector3],with prisms:[PlanarJointGeometry.Prism],bond:Double)throws->Bool {
    typealias G=PlanarJointGeometry
    for prism in prisms {
      let points=world.map{G.inversePoint(prism.matrix,$0)}
      guard points.allSatisfy({abs($0.z)<=prism.half+bond+0.02}),
        (points.map(\.z).max()! - points.map(\.z).min()!)<=0.02 else{continue}
      let projected=points.map{Point2($0.x,-$0.y)},area=G.area(projected)
      if area>0.001,abs(try G.intersectionArea([projected],G.normalizedContours(prism.panel))-area)<=max(0.01,area*1e-5) {return true}
    };return false
  }
}
