import Foundation
import FormCADModel

/// An authored, inextensible material centerline in (edge-distance, normal-offset)
/// millimeters. It is independent of any product or enclosure category.
public struct SheetPanelNeutralCurve:Codable,Equatable,Sendable {
  public var points:[CADExpressionPoint2]
  public var fitLength:Bool
  public init(points:[CADExpressionPoint2],fitLength:Bool=false){self.points=points;self.fitLength=fitLength}
  private enum CodingKeys:String,CodingKey {case points,fitLength}
  public init(from decoder:Decoder)throws {
    let values=try decoder.container(keyedBy:CodingKeys.self)
    points=try values.decode([CADExpressionPoint2].self,forKey:.points)
    fitLength=try values.decodeIfPresent(Bool.self,forKey:.fitLength) ?? false
  }
}
public struct SheetPanelNeutralSample:Equatable,Sendable {
  public var xMM:Double,yMM:Double,angleRadians:Double,curvaturePerMM:Double
  public init(xMM:Double,yMM:Double,angleRadians:Double,curvaturePerMM:Double){self.xMM=xMM;self.yMM=yMM;self.angleRadians=angleRadians;self.curvaturePerMM=curvaturePerMM}
}

/// One resolved profile is shared by physical mesh deformation and rest bounds.
/// Material positions are inverted from arc length; neither endpoint matching
/// nor fitting changes the source sheet's length or its artwork UV coordinates.
public struct SheetPanelNeutralCurveProfile:Codable,Equatable,Sendable {
  public let points:[Point2]
  public let widthMM:Double
  public let lengthMM:Double
  public let minimumRadiusMM:Double
  private let distances:[Double]
  private static let intervals=512
  struct CacheUsage:Sendable {
    let entries:Int,maximumEntries:Int,hits:Int,solves:Int
    let solveMilliseconds:Double
  }
  private struct CacheKey:Hashable,Sendable {
    let coordinates:[UInt64]
    let fitLength:Bool
    init(points:[Point2],widthMM:Double,fitLength:Bool) {
      coordinates=points.flatMap{[$0.x.bitPattern,$0.y.bitPattern]}+[widthMM.bitPattern]
      self.fitLength=fitLength
    }
  }
  /// Immutable numerical profiles only. A caliper is deliberately absent from
  /// the key and is checked independently on every resolution, including hits.
  private final class ProfileCache:@unchecked Sendable {
    private let lock=NSLock(),maximumEntries=128
    private var entries=[CacheKey:SheetPanelNeutralCurveProfile](),order=[CacheKey]()
    private var hits=0,solves=0,solveMilliseconds=0.0
    func value(for key:CacheKey)->SheetPanelNeutralCurveProfile? {
      lock.lock();defer{lock.unlock()}
      guard let value=entries[key] else{return nil};hits+=1;return value
    }
    func insert(_ value:SheetPanelNeutralCurveProfile,for key:CacheKey,milliseconds:Double)->SheetPanelNeutralCurveProfile {
      lock.lock();defer{lock.unlock()}
      solves+=1;solveMilliseconds+=milliseconds
      if let existing=entries[key] {return existing}
      while entries.count>=maximumEntries {entries.removeValue(forKey:order.removeFirst())}
      entries[key]=value;order.append(key);return value
    }
    var usage:CacheUsage {
      lock.lock();defer{lock.unlock()}
      return .init(entries:entries.count,maximumEntries:maximumEntries,hits:hits,solves:solves,solveMilliseconds:solveMilliseconds)
    }
  }
  private static let profileCache=ProfileCache()
  static var resolutionCacheUsage:CacheUsage {profileCache.usage}
  private enum CodingKeys:String,CodingKey {case points,widthMM}
  public init(from decoder:Decoder)throws {
    let values=try decoder.container(keyedBy:CodingKeys.self)
    try self.init(points:values.decode([Point2].self,forKey:.points),widthMM:values.decode(Double.self,forKey:.widthMM))
  }
  public func encode(to encoder:Encoder)throws {
    var values=encoder.container(keyedBy:CodingKeys.self)
    try values.encode(points,forKey:.points);try values.encode(widthMM,forKey:.widthMM)
  }
  public init(points original:[Point2],widthMM:Double,fitLength:Bool=false,maximumNormalOffsetMM:Double=0)throws {
    guard original.count==4,widthMM.isFinite,(0.01...10000).contains(widthMM),
      original.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<=100000 && abs($0.y)<=100000}),
      abs(original[0].x)<=1e-10,abs(original[0].y)<=1e-10 else {
      throw FormError.invalid("A neutral cubic needs four finite bounded points, origin (0, 0), and a positive physical material length.")
    }
    let key=CacheKey(points:original,widthMM:widthMM,fitLength:fitLength)
    if let cached=Self.profileCache.value(for:key) {
      try cached.validateCaliper(maximumNormalOffsetMM:maximumNormalOffsetMM)
      self=cached;return
    }
    let started=Date.timeIntervalSinceReferenceDate
    let tolerance=max(1e-6,widthMM*1e-7)
    guard hypot(original[3].x,original[3].y)<=widthMM+tolerance else{throw FormError.invalid("A neutral curve's endpoint chord cannot exceed its actual material length.")}
    var fitted=original
    if fitLength {
      func scaled(_ factor:Double)->[Point2] {var p=original;p[1].x *= factor;p[2].x *= factor;return p}
      func measure(_ factor:Double)->(length:Double,derivative:Double) {
        let p=scaled(factor)
        var length=0.0,derivative=0.0
        for i in 0..<64 {
          let a=Double(i)/64,b=Double(i+1)/64
          length += Self.integral(a,b){t in Self.speed(p,t)}
          derivative += Self.integral(a,b){t in
            let v=Self.velocity(p,t),q=1-t
            let dx=3*(q*q*original[1].x+2*q*t*(original[2].x-original[1].x)-t*t*original[2].x)
            let speed=hypot(v.x,v.y);return speed>1e-14 ? v.x*dx/speed:0
          }
        };return(length,derivative)
      }
      let atOne=measure(1)
      if abs(atOne.length-widthMM)>tolerance {
        let largest=max(abs(original[1].x),abs(original[2].x))
        guard largest>1e-12 else{throw FormError.invalid("Length fitting needs a nonzero interior X handle; no path or scale fallback is applied.")}
        let maximumFactor=min(1_048_576,100000/largest),minimumFactor=1e-8
        guard maximumFactor>minimumFactor else{throw FormError.invalid("Neutral curve fitting exceeds its bounded handle allocation.")}
        // Arc length is a convex function of this common handle multiplier.
        // Find its minimum, then bracket the increasing positive branch.
        var low=minimumFactor
        if measure(low).derivative<0 {
          var high=min(maximumFactor,1.0)
          while high<maximumFactor && measure(high).derivative<0 {high=min(maximumFactor,high*2)}
          guard measure(high).derivative>=0 else{throw FormError.invalid("The requested neutral length cannot be bracketed within finite handle bounds.")}
          for _ in 0..<44 {let middle=(low+high)/2;if measure(middle).derivative<0{low=middle}else{high=middle}}
          low=(low+high)/2
        }
        guard measure(low).length<=widthMM+tolerance else{throw FormError.invalid("The fixed neutral endpoints and control heights require more material than the declared width.")}
        var high=min(maximumFactor,max(1,low*2))
        while high<maximumFactor && measure(high).length<widthMM {high=min(maximumFactor,high*2)}
        guard measure(high).length>=widthMM-tolerance else{throw FormError.invalid("The requested neutral length cannot be reached without exceeding finite control bounds.")}
        for _ in 0..<48 {let middle=(low+high)/2;if measure(middle).length<widthMM{low=middle}else{high=middle}}
        fitted=scaled((low+high)/2)
      }
    }
    let vx=Self.velocityPolynomial(fitted,axis:0),vy=Self.velocityPolynomial(fitted,axis:1)
    let speedSquared=Self.add(Self.multiply(vx,vx),Self.multiply(vy,vy))
    let speedCritical=[0.0,1.0]+Self.roots(Self.derivative(speedSquared))+Self.roots(vx)+Self.roots(vy)
    let minimumSpeed=speedCritical.map{Self.speed(fitted,$0)}.min() ?? 0
    guard minimumSpeed>max(1e-8,widthMM*1e-9) else{throw FormError.invalid("A neutral material curve cannot contain a cusp or a stationary tangent.")}
    let cross=Self.add(Self.multiply(vx,Self.derivative(vy)),Self.multiply(vy,Self.derivative(vx)),scale:-1)
    let curvatureDerivative=Self.add(Self.multiply(Self.derivative(cross),speedSquared).map{$0*2},
      Self.multiply(cross,Self.derivative(speedSquared)).map{$0*3},scale:-1)
    let curvatureCritical=[0.0,1.0]+Self.roots(curvatureDerivative)
    let maximumCurvature=curvatureCritical.map{t -> Double in
      let denominator=pow(max(1e-30,Self.evaluate(speedSquared,t)),1.5)
      return abs(Self.evaluate(cross,t))/denominator
    }.max() ?? 0
    var distances=[0.0],length=0.0
    for i in 0..<Self.intervals {length+=Self.integral(Double(i)/Double(Self.intervals),Double(i+1)/Double(Self.intervals)){Self.speed(fitted,$0)};distances.append(length)}
    guard length.isFinite,abs(length-widthMM)<=tolerance else{throw FormError.invalid("The neutral curve must match the actual sheet width; enable length fitting rather than stretching its material.")}
    self.points=fitted;self.widthMM=widthMM;lengthMM=length;minimumRadiusMM=maximumCurvature>1e-12 ? 1/maximumCurvature:1e12;self.distances=distances
    _=Self.profileCache.insert(self,for:key,milliseconds:(Date.timeIntervalSinceReferenceDate-started)*1000)
    try validateCaliper(maximumNormalOffsetMM:maximumNormalOffsetMM)
  }
  public func validateCaliper(maximumNormalOffsetMM:Double)throws {
    guard maximumNormalOffsetMM.isFinite,maximumNormalOffsetMM>=0,minimumRadiusMM>maximumNormalOffsetMM else {
      throw FormError.invalid("The neutral curve's minimum radius must exceed the physical stock and wrapping half-caliper.")
    }
  }
  public func sample(atMM distance:Double)->SheetPanelNeutralSample {
    if distance<0 {let value=sample(parameter:0);return .init(xMM:value.xMM+distance*cos(value.angleRadians),yMM:value.yMM+distance*sin(value.angleRadians),angleRadians:value.angleRadians,curvaturePerMM:0)}
    if distance>widthMM {let value=sample(parameter:1),tail=distance-widthMM;return .init(xMM:value.xMM+tail*cos(value.angleRadians),yMM:value.yMM+tail*sin(value.angleRadians),angleRadians:value.angleRadians,curvaturePerMM:0)}
    var low=0,high=distances.count-1
    while high-low>1 {let middle=(low+high)/2;if distances[middle]<distance{low=middle}else{high=middle}}
    let a=Double(low)/Double(Self.intervals),b=Double(high)/Double(Self.intervals)
    var parameter=a+(b-a)*(distance-distances[low])/max(1e-15,distances[high]-distances[low])
    for _ in 0..<3 {
      let current=distances[low]+Self.integral(a,parameter){Self.speed(points,$0)},speed=Self.speed(points,parameter)
      parameter=min(b,max(a,parameter-(current-distance)/max(1e-15,speed)))
    };return sample(parameter:parameter)
  }
  public func sample(parameter t:Double)->SheetPanelNeutralSample {
    let t=min(1,max(0,t)),q=1-t,p=points
    let x=p[0].x*q*q*q+3*p[1].x*q*q*t+3*p[2].x*q*t*t+p[3].x*t*t*t
    let y=p[0].y*q*q*q+3*p[1].y*q*q*t+3*p[2].y*q*t*t+p[3].y*t*t*t
    let v=Self.velocity(p,t),a=Self.acceleration(p,t),speed=hypot(v.x,v.y)
    return .init(xMM:x,yMM:y,angleRadians:atan2(v.y,v.x),curvaturePerMM:(v.x*a.y-v.y*a.x)/(speed*speed*speed))
  }
  public func distance(atParameter t:Double)->Double {
    let t=min(1,max(0,t)),index=min(Self.intervals-1,Int(t*Double(Self.intervals))),a=Double(index)/Double(Self.intervals)
    return distances[index]+Self.integral(a,t){Self.speed(points,$0)}
  }
  /// Exact tangent roots bound any rotated coordinate of every valid parallel
  /// caliper surface, since its derivative is tangent*(1-curvature*offset).
  public func criticalDistances(xWeight:Double,yWeight:Double)->[Double] {
    let x=Self.velocityPolynomial(points,axis:0),y=Self.velocityPolynomial(points,axis:1)
    return Self.roots(Self.add(x.map{$0*xWeight},y.map{$0*yWeight})).map{distance(atParameter:$0)}
  }
  private static func speed(_ p:[Point2],_ t:Double)->Double {let v=velocity(p,t);return hypot(v.x,v.y)}
  private static func velocity(_ p:[Point2],_ t:Double)->Point2 {
    let q=1-t
    return .init(3*(q*q*(p[1].x-p[0].x)+2*q*t*(p[2].x-p[1].x)+t*t*(p[3].x-p[2].x)),
      3*(q*q*(p[1].y-p[0].y)+2*q*t*(p[2].y-p[1].y)+t*t*(p[3].y-p[2].y)))
  }
  private static func acceleration(_ p:[Point2],_ t:Double)->Point2 {
    .init(6*((1-t)*(p[2].x-2*p[1].x+p[0].x)+t*(p[3].x-2*p[2].x+p[1].x)),
      6*((1-t)*(p[2].y-2*p[1].y+p[0].y)+t*(p[3].y-2*p[2].y+p[1].y)))
  }
  private static func integral(_ a:Double,_ b:Double,_ value:(Double)->Double)->Double {
    guard b>a else{return 0}
    let center=(a+b)/2,half=(b-a)/2
    let middle=0.5688888888888889*value(center)
    let near=0.4786286704993665*(value(center-half*0.5384693101056831)+value(center+half*0.5384693101056831))
    let far=0.2369268850561891*(value(center-half*0.9061798459386640)+value(center+half*0.9061798459386640))
    return half*(middle+near+far)
  }
  private static func velocityPolynomial(_ p:[Point2],axis:Int)->[Double] {
    let v=p.map{axis==0 ? $0.x:$0.y}
    return [3*(v[1]-v[0]),6*(v[2]-2*v[1]+v[0]),3*(v[3]-3*v[2]+3*v[1]-v[0])]
  }
  private static func derivative(_ p:[Double])->[Double] {p.count>1 ? (1..<p.count).map{Double($0)*p[$0]}:[]}
  private static func evaluate(_ p:[Double],_ t:Double)->Double {p.reversed().reduce(0){$0*t+$1}}
  private static func add(_ a:[Double],_ b:[Double],scale:Double=1)->[Double] {(0..<max(a.count,b.count)).map{(a.indices.contains($0) ? a[$0]:0)+scale*(b.indices.contains($0) ? b[$0]:0)}}
  private static func multiply(_ a:[Double],_ b:[Double])->[Double] {guard !a.isEmpty,!b.isEmpty else{return []};var result=[Double](repeating:0,count:a.count+b.count-1);for i in a.indices {for j in b.indices {result[i+j]+=a[i]*b[j]}};return result}
  private static func roots(_ supplied:[Double])->[Double] {
    let scale=supplied.map(abs).max() ?? 0
    guard scale>1e-30 else{return []};var p=supplied.map{$0/scale}
    while let last=p.last,abs(last)<1e-13 {p.removeLast()}
    guard p.count>1 else{return []}
    if p.count==2 {let t = -p[0]/p[1];return t>=0 && t<=1 ? [t]:[]}
    let partitions=[0.0]+roots(derivative(p))+[1.0]
    var result=partitions.filter{abs(evaluate(p,$0))<1e-10}
    for i in 0..<(partitions.count-1) {
      var low=partitions[i],high=partitions[i+1],a=evaluate(p,low),b=evaluate(p,high)
      guard a*b<0 else{continue}
      for _ in 0..<50 {let middle=(low+high)/2,value=evaluate(p,middle);if a*value<=0 {high=middle;b=value}else{low=middle;a=value}}
      result.append((low+high)/2)
    }
    var unique=[Double]()
    for t in result.sorted() where unique.last.map({t-$0>1e-9}) ?? true {unique.append(t)}
    return unique
  }
}

extension ResolvedSheetPanelFlex {
  public func neutralSample(atMM distance:Double)->SheetPanelNeutralSample {
    if let curve{return curve.sample(atMM:distance)}
    return Self.circularSample(atMM:distance,widthMM:widthMM,angleDegrees:angleDegrees)
  }
  public static func circularSample(atMM distance:Double,widthMM:Double,angleDegrees:Double)->SheetPanelNeutralSample {
    let angle=angleDegrees * .pi/180
    if distance<0 || abs(angle)<1e-12 {return .init(xMM:distance,yMM:0,angleRadians:0,curvaturePerMM:0)}
    let radius=widthMM/angle,s=min(distance,widthMM),a=s/radius,tail=max(0,distance-widthMM)
    return .init(xMM:radius*sin(a)+tail*cos(a),yMM:radius*(1-cos(a))+tail*sin(a),angleRadians:a,
      curvaturePerMM:distance<widthMM ? 1/radius:0)
  }
  /// Maps the same local millimeter coordinates used by physical paper meshes.
  /// Local Y is up, while authored page coordinates increase downward.
  public func deform(_ point:Vector3,size:Point2)->Vector3 {
    let horizontal=edge == .left || edge == .right,reverse=edge == .right || edge == .tail
    let extent=horizontal ? size.x:size.y,axis=horizontal ? point.x:-point.y
    let d=reverse ? extent-axis:axis,s=neutralSample(atMM:d),direction=reverse ? -1.0:1.0
    let value=(reverse ? extent:0)+direction*(s.xMM-sin(s.angleRadians)*point.z)
    var result=point
    if horizontal{result.x=value}else{result.y = -value}
    result.z=s.yMM+cos(s.angleRadians)*point.z;return result
  }
  /// Includes tangent extrema in each final world coordinate. Parallel stock
  /// surfaces have the same extrema while the radius exceeds their caliper.
  public func boundarySamples(size:Point2,halfCaliperMM:Double,outsetMM:Double=0,
    rotationDegrees:Vector3 = .init())->[Vector3] {
    boundarySamples(size:size,halfCaliperMM:halfCaliperMM,outsetMM:outsetMM,
      worldMatrix:PaperRigidMatrix.rotation(rotationDegrees.x,rotationDegrees.y,rotationDegrees.z))
  }
  func boundarySamples(size:Point2,halfCaliperMM:Double,outsetMM:Double=0,worldMatrix:[Double])->[Vector3] {
    let horizontal=edge == .left || edge == .right,reverse=edge == .right || edge == .tail
    let extent=horizontal ? size.x:size.y,direction=reverse ? -1.0:1.0
    let axis=horizontal ? Vector3(direction,0,0):Vector3(0,-direction,0)
    func linear(_ p:Vector3)->Vector3 {
      .init(worldMatrix[0]*p.x+worldMatrix[1]*p.y+worldMatrix[2]*p.z,
        worldMatrix[4]*p.x+worldMatrix[5]*p.y+worldMatrix[6]*p.z,
        worldMatrix[8]*p.x+worldMatrix[9]*p.y+worldMatrix[10]*p.z)
    }
    let axisWorld=linear(axis),normalWorld=linear(.init(0,0,1))
    let weights=[(axisWorld.x,normalWorld.x),(axisWorld.y,normalWorld.y),(axisWorld.z,normalWorld.z)]
    var distances=[-outsetMM,0,widthMM,extent,extent+outsetMM]
    for (x,y) in weights {
      if let curve {distances += curve.criticalDistances(xWeight:x,yWeight:y)}
      else if angleDegrees != 0 {
        let angle=angleDegrees * .pi/180,start=atan2(-x,y)
        for turn in -3...3 {let a=start+Double(turn)*Double.pi,d=widthMM*a/angle;if d>0 && d<widthMM {distances.append(d)}}
      }
    }
    var result=[Vector3]()
    for d in distances {
      let axis=(reverse ? extent-d:d)
      let cross=horizontal ? [-size.y-outsetMM,outsetMM]:[-outsetMM,size.x+outsetMM]
      for q in cross {for z in [-halfCaliperMM,halfCaliperMM] {
        result.append(deform(horizontal ? .init(axis,q,z):.init(q,-axis,z),size:size))
      }}
    };return result
  }
}
