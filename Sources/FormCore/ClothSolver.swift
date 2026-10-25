import Foundation
import simd

public enum ClothRunStatus:String,Codable,Sendable {case stopped,running,timeLimit,failed}
public struct ClothDiagnostics:Codable,Equatable,Sendable {
  public var status:ClothRunStatus
  public var vertexCount:Int
  public var triangleCount:Int
  public var constraintCount:Int
  public var pinnedCount:Int
  public var elapsedSeconds:Double
  public var completedFrames:Int
  public var evaluations:Int
  public var totalMassKg:Double
  public var centerOfMassMm:Vector3
  public var kineticEnergyJ:Double
  public var potentialEnergyJ:Double
  public var maximumSpeedMPerSecond:Double
  public var maximumStretchRatio:Double
  public var maximumDistanceErrorMm:Double
  public var maximumSeamGapMm:Double
  public var maximumVertexPenetrationMm:Double
  public var maximumSurfacePenetrationMm:Double
  public var maximumConstraintForceN:Double
  public var lastError:String?
}
public struct ClothFrame:Equatable,Sendable {
  public var positionsMm:[Vector3]
  public var normals:[Vector3]
  public var velocitiesMPerSecond:[Vector3]
  public var pinnedVertices:[Int]
  public var diagnostics:ClothDiagnostics
}
/// Pure fixed-step state. No timers, UI, document mutation or wall-clock input.
/// Constraint multipliers accumulate across iterations and reset each substep.
public struct ClothSolver:Sendable {
  public static let maximumWorkPerAdvance=2_000_000
  public let mesh:ClothMesh
  public let settings:ClothSettings
  public let colliders:[ClothCollider]
  public private(set) var status=ClothRunStatus.stopped
  public private(set) var completedFrames=0
  public private(set) var evaluations=0
  public private(set) var lastError:String?
  private var positions:[SIMD3<Double>]
  private var velocities:[SIMD3<Double>]
  private var inverseMass:[Double]
  private var pinTargets:[SIMD3<Double>?]
  private var restLengths:[Double]
  private var restDirections:[SIMD3<Double>]
  private var lambdas:[Double]
  private struct Contact:Sendable {var collider:Int;var normal:SIMD3<Double>;var correction:Double}
  public init(mesh:ClothMesh,settings:ClothSettings = .init(),colliders:[ClothCollider] = [])throws {
    try mesh.validate();try settings.validate()
    guard colliders.count<=16 else {throw FormError.invalid("Use at most 16 analytic cloth colliders.")}
    for collider in colliders {try collider.validate()}
    self.mesh=mesh;self.settings=settings;self.colliders=colliders
    positions=mesh.restPositionsMm.map {ClothMath.vector($0)/1000}
    velocities=mesh.initialVelocitiesMPerSecond?.map {ClothMath.vector($0)} ?? [SIMD3<Double>](repeating:.zero,count:positions.count)
    inverseMass=mesh.massesKg.map {1/$0};pinTargets=[SIMD3<Double>?](repeating:nil,count:positions.count)
    restLengths=[];restDirections=[];lambdas=[Double](repeating:0,count:mesh.links.count)
    for link in mesh.links {
      let direction=positions[link.a]-positions[link.b],length=simd_length(direction)
      restLengths.append(link.restLengthMm.map {$0/1000} ?? length)
      restDirections.append(length>1e-12 ? direction/length:SIMD3<Double>(1,0,0))
    }
    for pin in mesh.pins {
      let target=ClothMath.vector(pin.targetMm)/1000
      guard Self.clear(target,colliders:colliders,thickness:settings.collisionThicknessMm/2000) else {throw FormError.invalid("A pinned cloth target lies inside a declared contact shape.")}
      pinTargets[pin.vertex]=target;positions[pin.vertex]=target;velocities[pin.vertex] = .zero;inverseMass[pin.vertex]=0
    }
    try validatePinnedLinks(targets:pinTargets)
    try validateFixedFaces(targets:pinTargets)
    guard workForFrame<=Self.maximumWorkPerAdvance else {throw FormError.invalid("This mesh/contact/iteration combination exceeds the bounded per-frame cloth work budget.")}
  }
  public var isRunning:Bool {status == .running}
  public var elapsedSeconds:Double {Double(completedFrames)*settings.frameStepSeconds}
  public var maximumFrames:Int {Int(floor(settings.maximumSimulationSeconds/settings.frameStepSeconds+1e-10))}
  private var workForFrame:Int {
    let pins=pinTargets.filter {$0 != nil}.count
    return settings.substeps*(positions.count+mesh.links.count*settings.iterations+contactWorkPerPass*(settings.iterations+2)+pins*(settings.iterations+1))
  }
  private var contactWorkPerPass:Int {positions.count*colliders.count+mesh.triangles.count*colliders.filter {$0.kind == .sphere}.count}
  public mutating func start()throws {
    guard status != .failed else {throw FormError.invalid("Reset the stopped cloth study after its numerical failure before running again.")}
    guard completedFrames<maximumFrames else {status = .timeLimit;throw FormError.invalid("The cloth study reached its declared time limit. Reset it to run again.")}
    status = .running
  }
  /// Freezes positions, velocities and time. Start resumes the same state.
  public mutating func stop() {if status == .running {status = .stopped}}
  public mutating func reset() {
    positions=mesh.restPositionsMm.map {ClothMath.vector($0)/1000}
    velocities=mesh.initialVelocitiesMPerSecond?.map {ClothMath.vector($0)} ?? [SIMD3<Double>](repeating:.zero,count:positions.count)
    inverseMass=mesh.massesKg.map {1/$0};pinTargets=[SIMD3<Double>?](repeating:nil,count:positions.count)
    for pin in mesh.pins {let target=ClothMath.vector(pin.targetMm)/1000;pinTargets[pin.vertex]=target;positions[pin.vertex]=target;inverseMass[pin.vertex]=0;velocities[pin.vertex] = .zero}
    lambdas=[Double](repeating:0,count:mesh.links.count);completedFrames=0;evaluations=0;lastError=nil;status = .stopped
  }
  public mutating func pin(_ vertex:Int,toMm target:Vector3)throws {
    guard positions.indices.contains(vertex),ClothMath.finite(target),ClothMath.maximum(target)<=100000 else {throw FormError.invalid("Choose an existing cloth vertex and finite bounded pin target.")}
    let point=ClothMath.vector(target)/1000
    guard Self.clear(point,colliders:colliders,thickness:settings.collisionThicknessMm/2000) else {throw FormError.invalid("A pinned cloth target cannot be placed inside a declared contact shape.")}
    var targets=pinTargets;targets[vertex]=point;try validatePinnedLinks(targets:targets);try validateFixedFaces(targets:targets)
    let newCount=targets.filter {$0 != nil}.count,work=settings.substeps*(positions.count+mesh.links.count*settings.iterations+contactWorkPerPass*(settings.iterations+2)+newCount*(settings.iterations+1))
    guard work<=Self.maximumWorkPerAdvance else {throw FormError.invalid("This pin exceeds the declared cloth work budget.")}
    pinTargets=targets;inverseMass[vertex]=0;positions[vertex]=point;velocities[vertex] = .zero
  }
  public mutating func unpin(_ vertex:Int)throws {
    guard positions.indices.contains(vertex) else {throw FormError.invalid("Choose an existing cloth vertex.")}
    pinTargets[vertex]=nil;inverseMass[vertex]=1/mesh.massesKg[vertex];velocities[vertex] = .zero
  }
  private func validatePinnedLinks(targets:[SIMD3<Double>?])throws {
    for (index,link) in mesh.links.enumerated() where settings.compliance(link.kind)==0 {
      if let a=targets[link.a],let b=targets[link.b],abs(simd_distance(a,b)-restLengths[index])>1e-8 {throw FormError.invalid("Two fixed pin targets contradict an ideal distance/seam constraint.")}
    }
  }
  private func validateFixedFaces(targets:[SIMD3<Double>?])throws {
    for t in mesh.triangles {
      guard let a=targets[t.a],let b=targets[t.b],let c=targets[t.c] else {continue}
      for collider in colliders where collider.kind == .sphere {
        let center=ClothMath.vector(collider.centerMm)/1000,radius=collider.radiusMm/1000+settings.collisionThicknessMm/2000
        if simd_distance(ClothContactGeometry.closestPoint(center,a:a,b:b,c:c).point,center)<radius-1e-10 {throw FormError.invalid("A triangle fixed by three pins intersects a declared sphere contact.")}
      }
    }
  }
  public func validateAdvanceRequest(frames:Int)throws {
    guard (1...120).contains(frames),frames<=Self.maximumWorkPerAdvance/max(1,workForFrame) else {throw FormError.invalid("Advance 1–120 frames within the two-million-evaluation cloth budget; split longer requests.")}
  }
  @discardableResult public mutating func advance(frames:Int = 1)throws -> ClothDiagnostics {
    try validateAdvanceRequest(frames:frames)
    guard isRunning else {return diagnostics}
    let count=min(frames,maximumFrames-completedFrames),prior=self
    do {
      for _ in 0..<count {
        for _ in 0..<settings.substeps {try substep()}
        completedFrames+=1
      }
      evaluations+=count*workForFrame
      if completedFrames>=maximumFrames {status = .timeLimit}
      return diagnostics
    } catch {
      self=prior;status = .failed;lastError=error.localizedDescription;throw error
    }
  }
  private mutating func substep()throws {
    let h=settings.frameStepSeconds/Double(settings.substeps),gravity=ClothMath.vector(settings.gravityMPerSecondSquared)
    let decay=exp(-settings.velocityDampingPerSecond*h)
    var incoming=velocities,contacts=[[Contact]](repeating:[],count:positions.count)
    // Recover pre-existing overlap before choosing the velocity reference. An
    // overlapping initial mesh should not turn depenetration into a rebound.
    let beforeRecovery=positions;projectContacts(previous:beforeRecovery,contacts:&contacts)
    let old=positions
    for i in positions.indices {
      if let target=pinTargets[i] {positions[i]=target;velocities[i] = .zero;continue}
      // Split global velocity drag from external acceleration. Damp existing
      // velocity only: damping gravity itself biases a resting compliant spring.
      velocities[i]=velocities[i]*decay+gravity*h;incoming[i]=velocities[i];positions[i]+=velocities[i]*h
    }
    for index in lambdas.indices {lambdas[index]=0}
    projectContacts(previous:old,contacts:&contacts)
    for _ in 0..<settings.iterations {
      let beforeConstraints=positions
      for (index,link) in mesh.links.enumerated() {
        let weight=inverseMass[link.a]+inverseMass[link.b],alpha=settings.compliance(link.kind)/(h*h)
        if weight==0,alpha==0 {continue}
        let delta=positions[link.a]-positions[link.b],length=simd_length(delta),c=length-restLengths[index]
        if length<1e-12,abs(c)<1e-12 {continue}
        let normal=length>1e-12 ? delta/length:restDirections[index]
        let change=(-c-alpha*lambdas[index])/(weight+alpha)
        positions[link.a]+=normal*(change*inverseMass[link.a]);positions[link.b]-=normal*(change*inverseMass[link.b]);lambdas[index]+=change
      }
      for i in positions.indices {if let target=pinTargets[i] {positions[i]=target}}
      projectContacts(previous:beforeConstraints,contacts:&contacts)
    }
    guard lambdas.allSatisfy(\.isFinite),positions.allSatisfy(ClothMath.finite) else {throw FormError.invalid("Cloth constraints produced a nonfinite value; the last valid frame was retained.")}
    for i in positions.indices {
      guard pinTargets[i]==nil else {velocities[i] = .zero;continue}
      var velocity=(positions[i]-old[i])/h
      for contact in contacts[i] {
        let normal=contact.normal,inward=simd_dot(velocity,normal)
        if inward<0 {velocity-=normal*inward}
        let tangent=velocity-normal*simd_dot(velocity,normal),speed=simd_length(tangent)
        let normalImpulse=max(0,-simd_dot(incoming[i],normal),contact.correction/h)
        if speed>1e-12 {velocity-=tangent*min(1,settings.friction*normalImpulse/speed)}
      }
      guard ClothMath.finite(positions[i]),ClothMath.finite(velocity),simd_length(positions[i])<=10000,simd_length(velocity)<=10000 else {throw FormError.invalid("Cloth motion exceeded the finite study domain; the last valid frame was retained. Reset or use smaller steps/compatible constraints.")}
      velocities[i]=velocity
    }
  }
  private mutating func projectContacts(previous:[SIMD3<Double>],contacts:inout [[Contact]]) {
    let thickness=settings.collisionThicknessMm/2000
    for i in positions.indices where inverseMass[i]>0 {
      for (colliderIndex,collider) in colliders.enumerated() {
        let before=positions[i],center=ClothMath.vector(collider.centerMm)/1000
        var normal=SIMD3<Double>(0,1,0),touch=false
        switch collider.kind {
        case .plane:
          normal=simd_normalize(ClothMath.vector(collider.normal))
          let signed=simd_dot(before-center,normal)-thickness
          if signed<0 {positions[i]-=normal*signed;touch=true}
          else if signed<=1e-10 {touch=true}
        case .sphere:
          let radius=collider.radiusMm/1000+thickness,from=previous[i]-center,motion=before-previous[i],a=simd_length_squared(motion),b=2*simd_dot(from,motion),c=simd_length_squared(from)-radius*radius
          // Swept vertex test prevents a fast point from crossing a sphere and
          // emerging on its far side between the declared small substeps.
          if a>1e-20,c >= -1e-12,b<0 {
            let discriminant=b*b-4*a*c
            if discriminant>=0 {
              let time=max(0,(-b-sqrt(discriminant))/(2*a))
              if time<=1 {
                let hit=previous[i]+motion*time,relative=hit-center
                normal=simd_length_squared(relative)>1e-20 ? simd_normalize(relative):SIMD3<Double>(0,1,0)
                let remainder=before-hit,into=min(0,simd_dot(remainder,normal))
                positions[i]=hit+remainder-normal*into;touch=true
              }
            }
          }
          let delta=positions[i]-center,distance=simd_length(delta)
          if distance<radius {
            normal=distance>1e-12 ? delta/distance:(simd_length_squared(from)>1e-20 ? simd_normalize(from):SIMD3<Double>(0,1,0))
            positions[i]=center+normal*radius;touch=true
          } else if distance<=radius+1e-10 {normal=delta/max(distance,1e-12);touch=true}
        }
        if touch {recordContact(vertex:i,collider:colliderIndex,normal:normal,correction:max(0,simd_dot(positions[i]-before,normal)),contacts:&contacts)}
      }
    }
    // Vertex contacts alone allow triangle chords to cut through a curved
    // collider. Project its closest surface point using barycentric gradients.
    for (colliderIndex,collider) in colliders.enumerated() where collider.kind == .sphere {
      let center=ClothMath.vector(collider.centerMm)/1000,radius=collider.radiusMm/1000+thickness
      for t in mesh.triangles {
        let a=positions[t.a],b=positions[t.b],c=positions[t.c],closest=ClothContactGeometry.closestPoint(center,a:a,b:b,c:c),delta=closest.point-center,distance=simd_length(delta)
        guard distance<radius-1e-12 else {continue}
        let weights=closest.weights,denominator=inverseMass[t.a]*weights.x*weights.x+inverseMass[t.b]*weights.y*weights.y+inverseMass[t.c]*weights.z*weights.z
        guard denominator>0 else {continue}
        var normal:SIMD3<Double>
        if distance>1e-12 {normal=delta/distance}
        else {
          let prior=ClothContactGeometry.closestPoint(center,a:previous[t.a],b:previous[t.b],c:previous[t.c]).point-center,cross=simd_cross(b-a,c-a)
          normal=simd_length_squared(prior)>1e-20 ? simd_normalize(prior):(simd_length_squared(cross)>1e-20 ? simd_normalize(cross):SIMD3<Double>(0,1,0))
        }
        let correction=(radius-distance)/denominator
        for (vertex,weight) in [(t.a,weights.x),(t.b,weights.y),(t.c,weights.z)] where inverseMass[vertex]>0 && weight>0 {
          let move=correction*weight*inverseMass[vertex];positions[vertex]+=normal*move
          recordContact(vertex:vertex,collider:colliderIndex,normal:normal,correction:move,contacts:&contacts)
        }
      }
    }
  }
  private func recordContact(vertex:Int,collider:Int,normal:SIMD3<Double>,correction:Double,contacts:inout [[Contact]]) {
    if let index=contacts[vertex].firstIndex(where:{$0.collider==collider}) {contacts[vertex][index].normal=normal;contacts[vertex][index].correction=max(contacts[vertex][index].correction,correction)}
    else {contacts[vertex].append(.init(collider:collider,normal:normal,correction:correction))}
  }
  private static func signedDistance(_ point:SIMD3<Double>,collider:ClothCollider,thickness:Double)->Double {
    let center=ClothMath.vector(collider.centerMm)/1000
    switch collider.kind {case .plane:return simd_dot(point-center,simd_normalize(ClothMath.vector(collider.normal)))-thickness
    case .sphere:return simd_distance(point,center)-collider.radiusMm/1000-thickness}
  }
  private static func clear(_ point:SIMD3<Double>,colliders:[ClothCollider],thickness:Double)->Bool {colliders.allSatisfy {signedDistance(point,collider:$0,thickness:thickness) >= -1e-10}}
  public var diagnostics:ClothDiagnostics {
    let total=mesh.massesKg.reduce(0,+),gravity=ClothMath.vector(settings.gravityMPerSecondSquared),h=settings.frameStepSeconds/Double(settings.substeps)
    var center=SIMD3<Double>.zero,kinetic=0.0,potential=0.0,speed=0.0,stretch=1.0,error=0.0,seam=0.0,penetration=0.0,surfacePenetration=0.0
    for i in positions.indices {
      let mass=mesh.massesKg[i];center+=positions[i]*mass;kinetic+=0.5*mass*simd_length_squared(velocities[i]);potential-=mass*simd_dot(gravity,positions[i]);speed=max(speed,simd_length(velocities[i]))
      for collider in colliders {penetration=max(penetration,-Self.signedDistance(positions[i],collider:collider,thickness:settings.collisionThicknessMm/2000)*1000)}
    }
    for t in mesh.triangles {
      for collider in colliders where collider.kind == .sphere {
        let center=ClothMath.vector(collider.centerMm)/1000,radius=collider.radiusMm/1000+settings.collisionThicknessMm/2000,closest=ClothContactGeometry.closestPoint(center,a:positions[t.a],b:positions[t.b],c:positions[t.c]).point
        surfacePenetration=max(surfacePenetration,(radius-simd_distance(closest,center))*1000)
      }
    }
    for (index,link) in mesh.links.enumerated() {
      let length=simd_distance(positions[link.a],positions[link.b]),difference=abs(length-restLengths[index])*1000
      if link.kind == .seam {seam=max(seam,difference)}
      else if link.kind != .bendDistance {error=max(error,difference);stretch=max(stretch,length/max(restLengths[index],1e-12))}
    }
    return .init(status:status,vertexCount:positions.count,triangleCount:mesh.triangles.count,constraintCount:mesh.links.count,pinnedCount:pinTargets.filter {$0 != nil}.count,
      elapsedSeconds:elapsedSeconds,completedFrames:completedFrames,evaluations:evaluations,totalMassKg:total,centerOfMassMm:ClothMath.point(center/total*1000),kineticEnergyJ:kinetic,potentialEnergyJ:potential,maximumSpeedMPerSecond:speed,maximumStretchRatio:stretch,maximumDistanceErrorMm:error,maximumSeamGapMm:seam,maximumVertexPenetrationMm:max(0,penetration),maximumSurfacePenetrationMm:max(0,penetration,surfacePenetration),maximumConstraintForceN:lambdas.map {abs($0)/(h*h)}.max() ?? 0,lastError:lastError)
  }
  public var frame:ClothFrame {
    var normals=[SIMD3<Double>](repeating:.zero,count:positions.count)
    for t in mesh.triangles {let normal=simd_cross(positions[t.b]-positions[t.a],positions[t.c]-positions[t.a]);normals[t.a]+=normal;normals[t.b]+=normal;normals[t.c]+=normal}
    return .init(positionsMm:positions.map {ClothMath.point($0*1000)},normals:normals.map {ClothMath.point(simd_length_squared($0)>1e-20 ? simd_normalize($0):SIMD3<Double>(0,1,0))},velocitiesMPerSecond:velocities.map(ClothMath.point),pinnedVertices:pinTargets.indices.filter {pinTargets[$0] != nil},diagnostics:diagnostics)
  }
}
