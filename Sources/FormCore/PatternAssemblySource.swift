import Foundation

public enum PatternAssemblySource {
  /// Assign manufacturing identities to original source nodes, converting only
  /// supported sharp shapes without changing physical placement or dimensions.
  /// The caller wraps this source preparation and assembly creation in one edit.
  @discardableResult public static func prepare(in project:inout Project,objectID:UUID,elements:Set<UUID>)throws -> Artwork {
    var candidate=project
    guard let object=candidate.objects.first(where:{$0.id==objectID}),candidate.artworkOwner(object).id==objectID,!object.locked,var art=object.artwork else {throw FormError.invalid("Choose an independent unlocked pattern owner.")}
    guard !elements.isEmpty,elements.isSubset(of:Set(art.elements.filter{$0.sewingPiece != nil && !art.isLocked($0)}.map(\.id))) else {throw FormError.invalid("Select unlocked annotated sewing pieces for assembly.")}
    for i in art.elements.indices where elements.contains(art.elements[i].id) {
      var e=art.elements[i]
      _ = try SewingPatterns.geometry(e,in:art)
      if e.kind != "path" {
        let points:[Point2]
        if e.kind=="rectangle",(e.cornerRadius ?? 0)==0 {points=[.init(),.init(e.width,0),.init(e.width,e.height),.init(0,e.height)]}
        else if e.kind=="polygon",(3...64).contains(e.sides ?? 5) {let count=e.sides ?? 5;points=(0..<count).map {let a=Double($0)*2*Double.pi/Double(count)-Double.pi/2;return .init(e.width/2+cos(a)*e.width/2,e.height/2+sin(a)*e.height/2)}}
        else {throw FormError.invalid("Assembly source preparation supports editable paths or sharp rectangles/polygons.")}
        e.kind="path";e.path = .init(width:e.width,height:e.height,contours:[.init(points.map {BezierNode($0)})]);e.cornerRadius=nil;e.sides=nil
      }
      guard let path=e.path,path.contours.allSatisfy(\.closed) else {throw FormError.invalid("Assembly needs closed source stitch contours.")}
      for ci in e.path!.contours.indices where e.path!.contours[ci].id==nil {e.path!.contours[ci].id=UUID()}
      art.elements[i]=e
      let edges=try SewingCurves.boundaries(e,in:art).flatMap(\.edges)
      if SewingPatterns.needsGeneralGeometry(e) {
        for j in e.sewingPiece!.notches.indices {let index=e.sewingPiece!.notches[j].edge;guard edges.indices.contains(index) else {throw FormError.invalid("A source notch references a missing edge.")};e.sewingPiece!.notches[j].edgeID=edges[index].id;e.sewingPiece!.notches[j].endID=edges[index].endID}
      }
      art.elements[i]=e
      for si in art.sewingSeams?.indices ?? 0..<0 {
        for first in [true,false] {
          var end=first ? art.sewingSeams![si].first:art.sewingSeams![si].second
          guard end.elementID==e.id else {continue}
          let index=try SewingPatterns.geometry(e,in:art).edgeIndex(end.edge,id:end.edgeID,endID:end.endID)
          guard let edge=edges.first(where:{$0.index==index}),let id=edge.id,let endID=edge.endID else {throw FormError.invalid("This seam has no stable source edge identity.")}
          end.edgeID=id;end.endID=endID
          if first {art.sewingSeams![si].first=end}else {art.sewingSeams![si].second=end}
        }
      }
    }
    try validateArtwork(art);try candidate.setArtwork(art,for:objectID,recordingStyleOverrides:false);project=candidate;return art
  }
}
