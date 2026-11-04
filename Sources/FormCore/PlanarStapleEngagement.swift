import Foundation
import FormCADModel

extension PlanarConstructionDefinition {
  func resolveStaple(_ source:PlanarStapleDefinition,jointID:String,entry:PlanarJointGeometry.Prism,
    receiving:PlanarJointGeometry.Prism,prisms:[PlanarJointGeometry.Prism],values:[String:Double],validate:Bool)throws->[ResolvedPlanarStaple] {
    typealias G=PlanarJointGeometry
    func number(_ x:CADScalar)throws->Double {try CADExpression.evaluate(x.expression,variables:values)}
    func point(_ x:CADExpressionPoint2)throws->Point2 {try .init(number(x.x),number(x.y))}
    let crownWidth=try number(source.crownWidthMM),wireWidth=try number(source.wireWidthMM),wireDepth=try number(source.wireDepthMM),legLength=try number(source.legLengthMM)
    let wireRadius=max(wireWidth,wireDepth)/2,edgeMargin=try number(source.minimumEdgeDistanceMM),endMargin=try number(source.endMarginMM)
    let gap=try number(source.maximumJointGapMM),minimumDepth=try number(source.minimumReceivingDepthMM)
    let count=Int(try number(source.count).rounded()),spacing=try number(source.spacingMM),anchor=try point(source.anchor),crown2=try point(source.crownDirection)
    let localCrown=try G.unit(.init(crown2.x,-crown2.y,0)),crownAxis=G.vector(entry.matrix,localCrown),sign=source.entrySide == .outside ? 1.0:-1.0
    let localDrive:Vector3
    if let d=source.driveDirection {localDrive=try G.unit(.init(number(d.x),number(d.y),number(d.z)))}else{localDrive = .init(0,0,-sign)}
    guard localDrive.z*sign < -0.05,abs(G.dot(localDrive,localCrown))<1e-6 else{throw FormError.invalid("Staple '\(source.id)' must drive into the selected entry face, perpendicular to its crown.")}
    let drive=G.vector(entry.matrix,localDrive)
    let spacing2=try source.spacingDirection.map(point) ?? crown2
    let localSpacing=try G.unit(.init(spacing2.x,-spacing2.y,0)),step=G.mul(G.vector(entry.matrix,localSpacing),spacing)
    if count>1 {
      let along=abs(G.dot(step,crownAxis)),across=G.length(G.sub(step,G.mul(crownAxis,G.dot(step,crownAxis))))
      guard spacing>wireRadius*2,(along>=crownWidth+wireWidth || across>=wireRadius*2) else{throw FormError.invalid("Staple '\(source.id)' instances overlap at the declared spacing.")}
    }
    let presentIDs=Set(source.installation.presentComponentIDs),present=prisms.filter{$0.panel.componentID.map(presentIDs.contains) ?? false}
    let layers=Set(source.layerComponentIDs ?? []),allowed=present.filter{$0.panel.id==entry.panel.id || $0.panel.id==receiving.panel.id || $0.panel.componentID.map(layers.contains) ?? false}
    if validate,let curved=present.first(where:{!$0.rigidReceivingSupported}) {
      throw FormError.invalid("Staple '\(source.id)' installed stack includes non-rigid material '\(curved.panel.id)'; declare explicit rigid receiving layers for this supported fastening route.")
    }
    let allowedPanelIDs=Set(allowed.map{$0.panel.id}),toolDepth=try number(source.toolAccessMM),toolClearance=try number(source.toolClearanceMM)
    let lateral=try G.unit(G.cross(drive,crownAxis))
    func fail(_ reason:String)throws->Never {throw FormError.invalid("Staple '\(source.id)' \(reason)")}
    func boundary(_ point:Vector3)throws->ResolvedPlanarWireBoundary {
      let local=G.inversePoint(receiving.matrix,point),flat=Point2(local.x,-local.y)
      if abs(local.z-receiving.half)<1e-6 {return .init(panelID:receiving.panel.id,componentID:receiving.panel.componentID,surface:.outside,panelPointMM:local,pointMM:point)}
      if abs(local.z+receiving.half)<1e-6 {return .init(panelID:receiving.panel.id,componentID:receiving.panel.componentID,surface:.inside,panelPointMM:local,pointMM:point)}
      for (ringIndex,ring) in ([receiving.panel.polygon]+(receiving.panel.cutouts ?? []).map(\.polygon)).enumerated() {
        for index in ring.indices {
          let a=ring[index],b=ring[(index+1)%ring.count],dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
          let t=length>0 ? min(1,max(0,((flat.x-a.x)*dx+(flat.y-a.y)*dy)/length)):0
          if hypot(flat.x-a.x-t*dx,flat.y-a.y-t*dy)<1e-6 {
            return .init(panelID:receiving.panel.id,componentID:receiving.panel.componentID,surface:.cutEdge,edgeIndex:index,
              cutoutID:ringIndex==0 ? nil:receiving.panel.cutouts?[ringIndex-1].id,panelPointMM:local,pointMM:point)
          }
        }
      }
      throw FormError.invalid("A scheduled wire boundary is not on the actual receiving material.")
    }
    var result=[ResolvedPlanarStaple]()
    for index in 0..<count {
      let center=G.add(entry.point(anchor,z:sign*entry.half),G.mul(step,Double(index)))
      let nominal=[G.sub(center,G.mul(crownAxis,crownWidth/2)),G.add(center,G.mul(crownAxis,crownWidth/2))]
      if validate {
        for p in nominal {
          let local=G.inversePoint(entry.matrix,p),flat=Point2(local.x,-local.y)
          guard entry.panel.containsMaterial(flat),G.boundaryDistance(flat,panel:entry.panel)>=endMargin+wireRadius-1e-7 else {try fail("violates the entry material or declared end margin.")}
        }
      }
      // Derive the crown side from the actual installed layer stack. A later
      // covering is not inserted into a pre-cover staple path by implication.
      var outer=0.0
      for leg in nominal {
        let entryIntervals=entry.intervals(origin:leg,direction:drive,range:(-20)...(legLength+40))
        guard let target=entryIntervals.first(where:{$0.lowerBound<=1e-6 && $0.upperBound>0}) else {try fail("has no physical entry material at its anchor.")}
        var cursor=target.lowerBound
        let neighbors=allowed.flatMap{$0.intervals(origin:leg,direction:drive,range:(-20)...target.upperBound)}
        for _ in 0...neighbors.count {
          let next=neighbors.filter{$0.upperBound>=cursor-gap-1e-7 && $0.lowerBound<cursor}.map(\.lowerBound).min() ?? cursor
          if next>=cursor-1e-9 {break};cursor=next
        }
        if validate,neighbors.contains(where:{$0.upperBound<cursor-gap-1e-7}) {try fail("has disconnected declared material on the crown side; repair its installed stack.")}
        outer=min(outer,cursor)
      }
      let shift=outer-wireDepth/2,crowns=nominal.map{G.add($0,G.mul(drive,shift))}
      var tips=[Vector3](),bends=[Vector3](),records=[[PlanarMaterialInterval]](),entryBoundaries=[ResolvedPlanarWireBoundary](),exitBoundaries=[ResolvedPlanarWireBoundary]()
      for (leg,crown) in crowns.enumerated() {
        // Keep the actual through-exit boundary even when a short buried leg
        // receives into a long board. Truncating at leg+200 invents a cut edge.
        let fullRange=0.0...200_000.0
        let firstRanges=entry.intervals(origin:crown,direction:drive,range:fullRange)
        let receivingRanges=receiving.intervals(origin:crown,direction:drive,range:fullRange)
        guard let first=firstRanges.first,let second=receivingRanges.first(where:{$0.upperBound>first.lowerBound+1e-8}) else {try fail("does not engage both intended board parts with leg\(leg+1).")}
        let engaged=min(legLength,second.upperBound)-max(0,second.lowerBound)
        entryBoundaries.append(try boundary(G.add(crown,G.mul(drive,second.lowerBound))))
        exitBoundaries.append(try boundary(G.add(crown,G.mul(drive,second.upperBound))))
        if validate {
          guard first.upperBound<=legLength+1e-7,second.lowerBound>=first.lowerBound-1e-7,
            second.lowerBound-first.upperBound<=gap+1e-7,engaged>=minimumDepth-1e-7 else {
            try fail("has insufficient receiving depth or an unsupported gap between its joined boards.")
          }
          // A rectangular offset-ray envelope checks the actual wire plus
          // declared edge distance, including an edge-driven wall receiving path.
          let radius=wireRadius+edgeMargin
          for a in [-radius,radius] {for b in [-radius,radius] {
            let offset=G.add(crown,G.add(G.mul(crownAxis,a),G.mul(lateral,b)))
            let firstOffset=entry.intervals(origin:offset,direction:drive,range:fullRange)
            let secondOffset=receiving.intervals(origin:offset,direction:drive,range:fullRange)
            func overlap(_ intervals:[ClosedRange<Double>],_ range:ClosedRange<Double>)->Double {intervals.map{max(0,min($0.upperBound,range.upperBound)-max($0.lowerBound,range.lowerBound))}.max() ?? 0}
            guard overlap(firstOffset,first)>=first.upperBound-first.lowerBound-0.01,
              overlap(secondOffset,second.lowerBound...min(legLength,second.upperBound))>=minimumDepth-1e-7 else {try fail("does not retain wire/edge clearance in the actual receiving material.")}
          }}
        }
        var materialRecords=[PlanarMaterialInterval]()
        for prism in present {
          let spans=prism.intervals(origin:crown,direction:drive,range:0...legLength)
          if validate,!spans.isEmpty,!allowedPanelIDs.contains(prism.panel.id) {try fail("collides with unintended piece '\(prism.panel.componentID ?? prism.panel.id)'.")}
          for span in spans {materialRecords.append(.init(panelID:prism.panel.id,componentID:prism.panel.componentID,entryMM:span.lowerBound,exitMM:span.upperBound))}
        }
        materialRecords.sort{$0.entryMM<$1.entryMM};records.append(materialRecords)
        switch source.termination {
        case .buried:
          let tip=G.add(crown,G.mul(drive,legLength))
          if validate {guard second.upperBound>=legLength+wireRadius-1e-7,receiving.contains(tip,margin:wireRadius) else {try fail("leaves an unintended exposed leg end; shorten the leg or declare a supported termination.")}}
          tips.append(tip)
        case .exposed:
          if validate {guard legLength>second.upperBound+wireRadius else {try fail("declares an exposed termination without a through receiving route.")}}
          tips.append(G.add(crown,G.mul(drive,legLength)))
        case .clinch:
          let minimum=try number(source.clinchLengthMM!),access=try number(source.clincherAccessMM!)
          let bendDistance=second.upperBound+wireRadius,remaining=legLength-bendDistance
          if validate {
            guard abs(G.dot(drive,G.vector(receiving.matrix,.init(0,0,1))))>0.5,remaining>=minimum else {try fail("cannot reach the declared clinch through this receiving face.")}
            if let blocked=G.toolObstructed(origin:G.add(crown,G.mul(drive,bendDistance)),axis:drive,across:crownAxis,depth:access,halfWidth:crownWidth/2+toolClearance,halfHeight:wireDepth/2+toolClearance,prisms:present,ignoring:allowedPanelIDs) {try fail("has blocked clincher access at '\(blocked)'.")}
          }
          let bend=G.add(crown,G.mul(drive,bendDistance)),tip=G.add(bend,G.mul(crownAxis,leg==0 ? remaining:-remaining))
          bends.append(bend);tips.append(tip)
        }
      }
      if validate {
        let crownCenter=G.mul(G.add(crowns[0],crowns[1]),0.5)
        if let blocked=G.toolObstructed(origin:G.sub(crownCenter,G.mul(drive,wireDepth/2)),axis:G.mul(drive,-1),across:crownAxis,depth:toolDepth,halfWidth:crownWidth/2+toolClearance,halfHeight:wireDepth/2+toolClearance,prisms:present,ignoring:allowedPanelIDs) {try fail("has obstructed driver access at '\(blocked)'.")}
      }
      let path=bends.isEmpty ? [tips[0],crowns[0],crowns[1],tips[1]]:[tips[0],bends[0],crowns[0],crowns[1],bends[1],tips[1]]
      if validate,source.termination == .clinch {
        try validateClinchWire(path,crownAxis:crownAxis,drive:drive,width:wireWidth,depth:wireDepth,id:source.id)
      }
      result.append(.init(id:source.id+":"+String(index),jointID:jointID,definitionID:source.id,instanceIndex:index,entryPanelID:source.entryPanelID,receivingPanelID:source.receivingPanelID,pointsMM:path,wireWidthMM:wireWidth,wireDepthMM:wireDepth,legLengthMM:legLength,crownWidthMM:crownWidth,legMaterialIntervals:records,termination:source.termination,tool:source.tool,installation:source.installation,
        sourceAnchorMM:anchor,instanceAnchorMM:.init(anchor.x+localSpacing.x*spacing*Double(index),anchor.y-localSpacing.y*spacing*Double(index)),entrySide:source.entrySide,
        crownDirection:crownAxis,driveDirection:drive,spacingDirection:G.vector(entry.matrix,localSpacing),definitionCount:count,spacingMM:spacing,
        endMarginMM:endMargin,minimumReceivingDepthMM:minimumDepth,minimumEdgeDistanceMM:edgeMargin,maximumJointGapMM:gap,
        toolAccessMM:toolDepth,toolClearanceMM:toolClearance,clincherAccessMM:try source.clincherAccessMM.map(number),clinchLengthMM:try source.clinchLengthMM.map(number),
        layerComponentIDs:source.layerComponentIDs ?? [],receivingEntryBoundaries:entryBoundaries,receivingThroughExitBoundaries:exitBoundaries))
    }
    return result
  }

  /// The two inward bends need not emerge at the same receiving-face height.
  /// Test the actual mitered rectangular wire used by the mesh/envelope, rather
  /// than comparing total tip lengths against the crown's projected span.
  private func validateClinchWire(_ path:[Vector3],crownAxis:Vector3,drive:Vector3,width:Double,depth:Double,id:String)throws {
    typealias G=PlanarJointGeometry
    let rings=try PlanarWireSection.corners(pointsMM:path,widthMM:width,depthMM:depth),origin=path[0]
    func project(_ point:Vector3)->Point2 {
      let delta=G.sub(point,origin);return .init(G.dot(delta,crownAxis),G.dot(delta,drive))
    }
    // All segments share the same positive out-of-plane width. Their overlap
    // is exactly the overlap of these in-plane sweep polygons, including the
    // physical miter at each bend and the butt cap at either actual wire tip.
    let segments=(0..<rings.count-1).map {index in
      [rings[index][0],rings[index][1],rings[index+1][1],rings[index+1][0]].map(project)
    }
    for segment in segments {
      guard Self.validJointRegion(segment) else {
        throw FormError.invalid("Staple '\(id)' clinch is too short for its physical wire section and bends. Increase its usable clinch reach or reduce the wire depth.")
      }
    }
    for first in segments.indices {for second in segments.indices where second>first+1 {
      // Adjacent sweeps meet on their deliberately shared miter plane. Any
      // positive-area contact elsewhere is physical wire interpenetration.
      if try G.intersectionArea([segments[first]],[segments[second]])>0.000001 {
        throw FormError.invalid("Staple '\(id)' clinch wire overlaps itself. Shorten the leg/clinch reach, increase the crown span, or reduce the wire section.")
      }
    }}
  }
}
