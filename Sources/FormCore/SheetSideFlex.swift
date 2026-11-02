import Foundation

/// A side-fastened leaf retains a flat pinned margin, then bends through a
/// caliper-aware circular transition. Source coordinates measure material arc
/// length; no page content is stretched to make the opening fit.
public struct SheetSideFlexProfile:Sendable {
  public struct Sample:Sendable {
    public var xMM:Double,yMM:Double,angleRadians:Double,curvaturePerMM:Double
  }
  public var widthMM:Double,pinnedWidthMM:Double,transitionLengthMM:Double
  public var transitionRadiusMM:Double,openingRadians:Double,tailLengthMM:Double
  public var tailAngleRadians:Double,normalOffsetMM:Double
  public init(binding:SheetBindingDefinition,leaf:ResolvedSheetAssemblyLeaf,
    stackThicknessMM:Double,openingDegrees:Double,bendMM:Double)throws {
    widthMM=leaf.size.x;pinnedWidthMM=binding.pinnedWidthMM;normalOffsetMM=leaf.stackOffsetMM
    openingRadians=leaf.turned ? openingDegrees * .pi/180:0
    let depth=max(0,stackThicknessMM-leaf.stock.resolvedThicknessMM/2-normalOffsetMM)
    transitionRadiusMM=openingRadians>0 ? binding.flexWidthMM/openingRadians+depth:0
    transitionLengthMM=openingRadians>0 ? transitionRadiusMM*openingRadians:binding.flexWidthMM
    tailLengthMM=widthMM-pinnedWidthMM-transitionLengthMM
    guard tailLengthMM>0.01,openingRadians==0 || transitionRadiusMM>leaf.stock.resolvedThicknessMM/2 else {
      throw FormError.invalid("The side-bound margin flex must fit the physical free page and exceed its stock caliper.")
    }
    tailAngleRadians=0
    if openingDegrees != 0,bendMM>0 {
      guard bendMM<=tailLengthMM/2 else{throw FormError.invalid("Keep the side-bound free-tail bend below half its physical length.")}
      var low=0.0,high=Double.pi/2
      for _ in 0..<40 {let angle=(low+high)/2;if tailLengthMM*(1-cos(angle))/angle<bendMM{low=angle}else{high=angle}}
      tailAngleRadians=(low+high)/2*(leaf.turned ? -1:1)
      guard abs(tailLengthMM/tailAngleRadians)>leaf.stock.resolvedThicknessMM/2 else {
        throw FormError.invalid("The free-tail bend radius must exceed its physical stock caliper.")
      }
    }
  }
  public func sample(atMM x:Double)->Sample {
    if x<=pinnedWidthMM {return .init(xMM:x,yMM:normalOffsetMM,angleRadians:0,curvaturePerMM:0)}
    let s=x-pinnedWidthMM
    if s<transitionLengthMM,openingRadians>0 {
      let a=s/transitionRadiusMM
      return .init(xMM:pinnedWidthMM+transitionRadiusMM*sin(a),
        yMM:normalOffsetMM+transitionRadiusMM*(1-cos(a)),angleRadians:a,curvaturePerMM:1/transitionRadiusMM)
    }
    if s<transitionLengthMM {return .init(xMM:x,yMM:normalOffsetMM,angleRadians:0,curvaturePerMM:0)}
    let startX=pinnedWidthMM+(openingRadians>0 ? transitionRadiusMM*sin(openingRadians):transitionLengthMM)
    let startY=normalOffsetMM+(openingRadians>0 ? transitionRadiusMM*(1-cos(openingRadians)):0)
    let t=s-transitionLengthMM
    if tailAngleRadians != 0 {
      let r=tailLengthMM/tailAngleRadians,a=openingRadians+t/r
      return .init(xMM:startX+r*(sin(a)-sin(openingRadians)),yMM:startY+r*(cos(openingRadians)-cos(a)),
        angleRadians:a,curvaturePerMM:1/r)
    }
    return .init(xMM:startX+t*cos(openingRadians),yMM:startY+t*sin(openingRadians),
      angleRadians:openingRadians,curvaturePerMM:0)
  }
}
