import Foundation
import CFormClipper

/// The print region comes from the same material contours as construction, including real inner cuts.
public enum PaperPrintGeometry {
  private static func area(_ ring:[Point2])->Double {
    guard ring.count>2 else{return 0}
    return zip(ring,Array(ring.dropFirst())+[ring[0]]).reduce(0){$0+$1.0.x*$1.1.y-$1.1.x*$1.0.y}/2
  }
  private static func oriented(_ ring:[Point2],positive:Bool)->[Point2] {
    (area(ring)>0)==positive ? ring:Array(ring.reversed())
  }
  public static func materialContours(_ net:PaperNet)->[[Point2]] {
    net.panels.flatMap { panel in
      [oriented(panel.polygon,positive:true)]+(panel.cutouts ?? []).map{oriented($0.polygon,positive:false)}
    }
  }
  public static func bleedContours(_ net:PaperNet,millimeters:Double)throws->[[Point2]] {
    guard millimeters.isFinite,(0...25).contains(millimeters) else{throw FormError.invalid("Paper bleed must be0–25mm.")}
    let paths=materialContours(net),counts=paths.map{Int32($0.count)},xy=paths.flatMap{$0.flatMap{[$0.x,$0.y]}}
    let united=try xy.withUnsafeBufferPointer { c in try counts.withUnsafeBufferPointer { n in
      try unpack(fc_union(c.baseAddress,n.baseAddress,Int32(n.count)))
    }}
    return millimeters==0 ? united:try SewingPolygonKernel.offset(united,distance:millimeters)
  }
  public static func svgPath(_ contours:[[Point2]])->String {
    contours.compactMap { ring in
      guard let first=ring.first else{return nil}
      return "M \(first.x),\(first.y) "+ring.dropFirst().map{"L \($0.x),\($0.y)"}.joined(separator:" ")+" Z"
    }.joined(separator:" ")
  }
  private static func unpack(_ paths:FCPaths)throws->[[Point2]] {
    defer{fc_free(paths)}
    guard paths.status==0,paths.count>0,let counts=paths.counts,let xy=paths.coordinates else{throw FormError.invalid("Paper print contours exceeded the bounded polygon work limit.")}
    var index=0,result:[[Point2]]=[]
    for i in 0..<Int(paths.count) {
      var ring:[Point2]=[]
      for _ in 0..<Int(counts[i]){ring.append(.init(xy[index],xy[index+1]));index+=2}
      result.append(ring)
    }
    return result
  }
}
