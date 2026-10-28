import Foundation
import simd

public enum ClothRunStatus:String,Codable,Sendable {case stopped,running,timeLimit,failed}
public struct ClothInitialJoinDiagnostics:Codable,Equatable,Sendable {
  public var idealGroupCount:Int
  public var projectedMaximumStructuralRatio:Double
  public var projectedStructuralP95Ratio:Double
  public var projectedMaximumStructuralErrorMm:Double
  public var centerOfMassBeforeMm:Vector3
  public var centerOfMassAfterMm:Vector3
  public var linearMomentumBeforeKgMPerSecond:Vector3
  public var linearMomentumAfterKgMPerSecond:Vector3
  public var idealSeamReactionsEstimated:Bool
}
public struct ClothDiagnostics:Codable,Equatable,Sendable {
  public var initialJoin:ClothInitialJoinDiagnostics?
  public var preparation:ClothPreparationDiagnostics?

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
  public var minimumStructuralRatio:Double
  public var maximumStructuralRelativeError:Double
  public var structuralP95RelativeError:Double
  public var maximumDistanceErrorMm:Double
  public var maximumSeamGapMm:Double
  public var maximumVertexPenetrationMm:Double
  public var maximumSurfacePenetrationMm:Double
  /// XPBD distance multipliers only; ideal-seam, contact and support reactions are not estimated.
  public var distanceForcesEstimated:Bool
  public var maximumConstraintForceN:Double
  public var lastError:String?
}
public struct ClothFrame:Equatable,Sendable {
  public var positionsMm:[Vector3]
  public var preparationCandidatePositionsMm:[Vector3]?
  public var normals:[Vector3]
  public var velocitiesMPerSecond:[Vector3]
  public var pinnedVertices:[Int]
  public var diagnostics:ClothDiagnostics
}
/// Pure fixed-step state. No timers, UI, document mutation or wall-clock input.
/// Constraint multipliers accumulate across iterations and reset each substep.
public struct ClothSolver:Sendable {
  public static let maximumWorkPerAdvance=2_000_000
  public static let maximumPreparationWorkPerAdvance=500_000
  public let mesh:ClothMesh
  public let settings:ClothSettings
  public let colliders:[ClothCollider]
  public private(set) var status=ClothRunStatus.stopped
  public private(set) var completedFrames=0
  public private(set) var evaluations=0
  public private(set) var lastError:String?
  private var positions:[SIMD3<Double>]
  private var sourcePose:[SIMD3<Double>]
  private var velocities:[SIMD3<Double>]
  private var inverseMass:[Double]
  private var seamRoots:[Int]
  private var seamMembers:[[Int]]
  private var effectivePinTargets:[SIMD3<Double>?]
  private var constraintWorkPerPass=0
  private var synchronizationWork=0
  private var initialJoin:ClothInitialJoinDiagnostics?
  private var preparationSettings:ClothAssemblyPreparation?
  private var preparationReport:ClothPreparationDiagnostics?
  private var preparationPassWork=0
  private var constraintOrder:[Int]
  private var structuralIndices:[Int]
  private var pinTargets:[SIMD3<Double>?]
  private var restLengths:[Double]
  private var restDirections:[SIMD3<Double>]
  private var lambdas:[Double]
  private struct Contact:Sendable {var collider:Int;var normal:SIMD3<Double>;var correction:Double}
  public init(mesh:ClothMesh,settings:ClothSettings = .init(),colliders:[ClothCollider] = [],preparation:ClothAssemblyPreparation? = nil)throws {
    try mesh.validate();try settings.validate();try preparation?.validate()
    if preparation != nil,let initial=mesh.initialVelocitiesMPerSecond {guard initial.allSatisfy({ClothMath.maximum($0)==0}) else{throw FormError.invalid("Assembly preparation requires zero declared initial velocity. This static joining prototype does not preserve an authored motion field.")}}
    guard colliders.count<=16 else {throw FormError.invalid("Use at most 16 analytic cloth colliders.")}
    for collider in colliders {try collider.validate()}
    self.mesh=mesh;self.settings=settings;self.colliders=colliders
    positions=mesh.restPositionsMm.map {ClothMath.vector($0)/1000};sourcePose=positions
    velocities=mesh.initialVelocitiesMPerSecond?.map {ClothMath.vector($0)} ?? [SIMD3<Double>](repeating:.zero,count:positions.count)
    inverseMass=mesh.massesKg.map {1/$0};pinTargets=[SIMD3<Double>?](repeating:nil,count:positions.count)
    initialJoin=nil;preparationSettings=preparation;preparationReport=preparation.map(ClothPreparationDiagnostics.init)
    constraintOrder=Array(mesh.links.indices);structuralIndices=mesh.links.indices.filter{[ClothLinkKind.warp,.weft,.shear].contains(mesh.links[$0].kind)}
    if preparation != nil {constraintOrder.sort{a,b in let x=mesh.links[a].kind == .bendDistance ? 0:1,y=mesh.links[b].kind == .bendDistance ? 0:1;return x==y ? a<b:x<y}}
    seamRoots=Array(positions.indices);seamMembers=[[Int]](repeating:[],count:positions.count);effectivePinTargets=pinTargets
    restLengths=[];restDirections=[];lambdas=[Double](repeating:0,count:mesh.links.count)
    if settings.seamComplianceMPerN==0 {
      func root(_ vertex:Int)->Int {var result=vertex;while seamRoots[result] != result {result=seamRoots[result]};return result}
      for link in mesh.links where link.kind == .seam && (link.restLengthMm ?? simd_distance(positions[link.a],positions[link.b])*1000)==0 {
        let a=root(link.a),b=root(link.b);seamRoots[max(a,b)]=min(a,b)
      }
      for i in seamRoots.indices {seamRoots[i]=root(i)}
    }
    for i in seamRoots.indices {seamMembers[seamRoots[i]].append(i)}
    constraintWorkPerPass=mesh.links.reduce(mesh.links.count){$0+max(0,seamMembers[seamRoots[$1.a]].count-1)+max(0,seamMembers[seamRoots[$1.b]].count-1)}
    synchronizationWork=seamMembers.filter{$0.count>1}.reduce(0){$0+$1.count}
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
    sourcePose=positions
    try updateSeamMassAndPins(targets:pinTargets)
    for (index,link) in mesh.links.enumerated() where seamRoots[link.a]==seamRoots[link.b] {
      guard restLengths[index]<1e-10 else{throw FormError.invalid("An ideal sewn-point group contradicts a nonzero internal distance. Reassign the source seam.")}
    }
    for triangle in mesh.triangles {
      guard Set([seamRoots[triangle.a],seamRoots[triangle.b],seamRoots[triangle.c]]).count==3 else{throw FormError.invalid("An ideal seam collapses a material triangle. Reassign the source seam.")}
    }
    try validatePinnedLinks(targets:effectivePinTargets)
    try validateFixedFaces(targets:effectivePinTargets)
    preparationPassWork=constraintWorkPerPass+structuralIndices.count+contactWorkPerPass+mesh.pins.count
    if preparation != nil {guard preparationPassWork>0,preparationPassWork<=Self.maximumPreparationWorkPerAdvance else{throw FormError.invalid("One assembly preparation pass exceeds the bounded worker budget.")}}
    guard workForFrame<=Self.maximumWorkPerAdvance else {throw FormError.invalid("This mesh/contact/iteration combination exceeds the bounded per-frame cloth work budget.")}
  }
  public var isRunning:Bool {status == .running}
  public var elapsedSeconds:Double {Double(completedFrames)*settings.frameStepSeconds}
  public var maximumFrames:Int {Int(floor(settings.maximumSimulationSeconds/settings.frameStepSeconds+1e-10))}
  private var workForFrame:Int {workForFrame(pinCount:pinTargets.filter{$0 != nil}.count)}
  private func workForFrame(pinCount:Int)->Int {
    settings.substeps*(positions.count+synchronizationWork+constraintWorkPerPass*settings.iterations+contactWorkPerPass*(settings.iterations+2)+pinCount*(settings.iterations+1))
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
    positions=mesh.restPositionsMm.map {ClothMath.vector($0)/1000};sourcePose=positions
    velocities=mesh.initialVelocitiesMPerSecond?.map {ClothMath.vector($0)} ?? [SIMD3<Double>](repeating:.zero,count:positions.count)
    inverseMass=mesh.massesKg.map {1/$0};pinTargets=[SIMD3<Double>?](repeating:nil,count:positions.count)
    for pin in mesh.pins {let target=ClothMath.vector(pin.targetMm)/1000;pinTargets[pin.vertex]=target;positions[pin.vertex]=target;inverseMass[pin.vertex]=0;velocities[pin.vertex] = .zero}
    try! updateSeamMassAndPins(targets:pinTargets)
    initialJoin=nil;preparationReport=preparationSettings.map(ClothPreparationDiagnostics.init)
    lambdas=[Double](repeating:0,count:mesh.links.count);completedFrames=0;evaluations=0;lastError=nil;status = .stopped
  }
  public mutating func pin(_ vertex:Int,toMm target:Vector3)throws {
    guard preparationSettings==nil else{throw FormError.invalid("Edit the declared assembly supports and reset preparation before changing its pins.")}
    guard positions.indices.contains(vertex),ClothMath.finite(target),ClothMath.maximum(target)<=100000 else {throw FormError.invalid("Choose an existing cloth vertex and finite bounded pin target.")}
    let point=ClothMath.vector(target)/1000
    guard Self.clear(point,colliders:colliders,thickness:settings.collisionThicknessMm/2000) else {throw FormError.invalid("A pinned cloth target cannot be placed inside a declared contact shape.")}
    var targets=pinTargets;targets[vertex]=point
    let effective=try seamPins(targets:targets);try validatePinnedLinks(targets:effective);try validateFixedFaces(targets:effective)
    let newCount=targets.filter {$0 != nil}.count,work=workForFrame(pinCount:newCount)
    guard work<=Self.maximumWorkPerAdvance else {throw FormError.invalid("This pin exceeds the declared cloth work budget.")}
    pinTargets=targets;try updateSeamMassAndPins(targets:targets)
    for member in seamMembers[seamRoots[vertex]] {positions[member]=point;velocities[member] = .zero}
  }
  public mutating func unpin(_ vertex:Int)throws {
    guard preparationSettings==nil else{throw FormError.invalid("Edit the declared assembly supports and reset preparation before changing its pins.")}
    guard positions.indices.contains(vertex) else {throw FormError.invalid("Choose an existing cloth vertex.")}
    pinTargets[vertex]=nil;try updateSeamMassAndPins(targets:pinTargets)
    for member in seamMembers[seamRoots[vertex]] {velocities[member] = .zero}
  }
  /// Ideal zero-gap seams are equality constraints. Eliminate their duplicate
  /// translational DOFs instead of repeatedly pulling one side away from the
  /// structural solve. Each group retains every source vertex/UV and uses the
  /// sum of its real area masses, never an arbitrary mass floor.
  private func seamPins(targets:[SIMD3<Double>?])throws -> [SIMD3<Double>?] {
    var result=[SIMD3<Double>?](repeating:nil,count:positions.count)
    for members in seamMembers where !members.isEmpty {
      var fixed:SIMD3<Double>?
      for i in members {if let target=targets[i] {if let previous=fixed,simd_distance(previous,target)>1e-8 {throw FormError.invalid("An ideal sewn-point group has incompatible fixed support targets.")};fixed=target}}
      for i in members {result[i]=fixed}
    };return result
  }
  private mutating func updateSeamMassAndPins(targets:[SIMD3<Double>?])throws {
    effectivePinTargets=try seamPins(targets:targets)
    for members in seamMembers where !members.isEmpty {
      let mass=members.reduce(0.0){$0+mesh.massesKg[$1]},weight=effectivePinTargets[members[0]]==nil ? 1/mass:0
      for i in members {inverseMass[i]=weight}
    }
  }
  private mutating func synchronizeIdealSeams() {
    let groups=seamMembers.filter{$0.count>1}
    guard !groups.isEmpty else{return}
    let measure=initialJoin==nil,mass=mesh.massesKg.reduce(0,+)
    let beforeCenter=measure ? positions.indices.reduce(SIMD3<Double>.zero){$0+positions[$1]*mesh.massesKg[$1]}/mass:.zero
    let beforeMomentum=measure ? velocities.indices.reduce(SIMD3<Double>.zero){$0+velocities[$1]*mesh.massesKg[$1]}:.zero
    for members in groups {
      let total=members.reduce(0.0){$0+mesh.massesKg[$1]}
      let position=effectivePinTargets[members[0]] ?? members.reduce(SIMD3<Double>.zero){$0+positions[$1]*mesh.massesKg[$1]}/total
      let velocity=effectivePinTargets[members[0]]==nil ? members.reduce(SIMD3<Double>.zero){$0+velocities[$1]*mesh.massesKg[$1]}/total:.zero
      for i in members {positions[i]=position;velocities[i]=velocity}
    }
    if measure {
      var ratios:[Double]=[],error=0.0
      for (index,link) in mesh.links.enumerated() where [.warp,.weft,.shear].contains(link.kind) {
        let length=simd_distance(positions[link.a],positions[link.b]);ratios.append(length/restLengths[index]);error=max(error,abs(length-restLengths[index])*1000)
      }
      ratios.sort()
      let center=positions.indices.reduce(SIMD3<Double>.zero){$0+positions[$1]*mesh.massesKg[$1]}/mass,momentum=velocities.indices.reduce(SIMD3<Double>.zero){$0+velocities[$1]*mesh.massesKg[$1]}
      initialJoin = .init(idealGroupCount:groups.count,projectedMaximumStructuralRatio:ratios.last ?? 1,projectedStructuralP95Ratio:ratios.isEmpty ? 1:ratios[Int(Double(ratios.count-1)*0.95)],projectedMaximumStructuralErrorMm:error,centerOfMassBeforeMm:ClothMath.point(beforeCenter*1000),centerOfMassAfterMm:ClothMath.point(center*1000),linearMomentumBeforeKgMPerSecond:ClothMath.point(beforeMomentum),linearMomentumAfterKgMPerSecond:ClothMath.point(momentum),idealSeamReactionsEstimated:false)
    }
  }
  private mutating func move(_ vertex:Int,by delta:SIMD3<Double>) {
    let members=seamMembers[seamRoots[vertex]]
    if members.count==1 {positions[vertex]+=delta}
    else {for i in members {positions[i]+=delta}}
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
    if let report=preparationReport,report.status != .ready {return try advancePreparation()}
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
    synchronizeIdealSeams()
    let h=settings.frameStepSeconds/Double(settings.substeps),gravity=ClothMath.vector(settings.gravityMPerSecondSquared)
    let decay=exp(-settings.velocityDampingPerSecond*h)
    var incoming=velocities,contacts=[[Contact]](repeating:[],count:positions.count)
    // Recover pre-existing overlap before choosing the velocity reference. An
    // overlapping initial mesh should not turn depenetration into a rebound.
    let beforeRecovery=positions;projectContacts(previous:beforeRecovery,contacts:&contacts)
    let old=positions
    for i in positions.indices {
      if let target=effectivePinTargets[i] {positions[i]=target;velocities[i] = .zero;continue}
      // Split global velocity drag from external acceleration. Damp existing
      // velocity only: damping gravity itself biases a resting compliant spring.
      velocities[i]=velocities[i]*decay+gravity*h;incoming[i]=velocities[i];positions[i]+=velocities[i]*h
    }
    for index in lambdas.indices {lambdas[index]=0}
    projectContacts(previous:old,contacts:&contacts)
    for _ in 0..<settings.iterations {
      let beforeConstraints=positions
      for index in constraintOrder {solveDistance(index,h:h)}
      for i in positions.indices {if let target=effectivePinTargets[i] {positions[i]=target}}
      projectContacts(previous:beforeConstraints,contacts:&contacts)
    }
    guard lambdas.allSatisfy(\.isFinite),positions.allSatisfy(ClothMath.finite) else {throw FormError.invalid("Cloth constraints produced a nonfinite value; the last valid frame was retained.")}
    for i in positions.indices {
      guard effectivePinTargets[i]==nil else {velocities[i] = .zero;continue}
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
  private mutating func solveDistance(_ index:Int,h:Double) {
    let link=mesh.links[index]
    if seamRoots[link.a]==seamRoots[link.b] {return}
    let weight=inverseMass[link.a]+inverseMass[link.b],alpha=settings.compliance(link.kind)/(h*h)
    if weight==0,alpha==0 {return}
    let delta=positions[link.a]-positions[link.b],length=simd_length(delta),c=length-restLengths[index]
    if length<1e-12,abs(c)<1e-12 {return}
    let normal=length>1e-12 ? delta/length:restDirections[index],change=(-c-alpha*lambdas[index])/(weight+alpha)
    move(link.a,by:normal*(change*inverseMass[link.a]));move(link.b,by:-normal*(change*inverseMass[link.b]));lambdas[index]+=change
  }
  private mutating func measurePreparation() {
    guard var report=preparationReport else{return}
    var relative:[Double]=[],minimum=1.0,maximum=1.0,error=0.0
    for index in structuralIndices {
      let link=mesh.links[index],length=simd_distance(positions[link.a],positions[link.b]),ratio=length/restLengths[index]
      relative.append(abs(ratio-1));minimum=min(minimum,ratio);maximum=max(maximum,ratio);error=max(error,abs(length-restLengths[index])*1000)
    }
    relative.sort();report.maximumRelativeError=relative.last ?? 0;report.p95RelativeError=relative.isEmpty ? 0:relative[Int(Double(relative.count-1)*0.95)]
    report.minimumStructuralRatio=minimum;report.maximumStructuralRatio=maximum;report.maximumDistanceErrorMm=error
    report.worstPreparationStructuralRatio=max(report.worstPreparationStructuralRatio,maximum);report.lowestPreparationStructuralRatio=min(report.lowestPreparationStructuralRatio,minimum)
    preparationReport=report
  }
  /// One bounded cancellable worker batch, without physical time or velocity.
  private mutating func advancePreparation()throws -> ClothDiagnostics {
    guard let config=preparationSettings else{return diagnostics}
    let prior=self
    if preparationReport?.status == .pending {
      synchronizeIdealSeams();lambdas=[Double](repeating:0,count:mesh.links.count)
      preparationReport?.status = .preparing;measurePreparation()
    }
    let remaining=config.maximumEvaluations-(preparationReport?.evaluations ?? 0),batch=min(Self.maximumPreparationWorkPerAdvance,remaining),count=min(batch/preparationPassWork,config.maximumPasses-(preparationReport?.passes ?? 0))
    let h=settings.frameStepSeconds/Double(settings.substeps)
    var contacts=[[Contact]](repeating:[],count:positions.count)
    for _ in 0..<max(0,count) {
      let before=positions
      for index in constraintOrder {solveDistance(index,h:h)}
      for i in positions.indices {if let target=effectivePinTargets[i] {positions[i]=target}}
      projectContacts(previous:before,contacts:&contacts)
      guard positions.allSatisfy(ClothMath.finite),lambdas.allSatisfy(\.isFinite) else {
        self=prior;preparationReport?.status = .failed;status = .failed;lastError="Assembly preparation became nonfinite; the last valid batch was retained. Reset and repair the declared source/supports."
        throw FormError.invalid(lastError!)
      }
      preparationReport?.passes+=1;preparationReport?.evaluations+=preparationPassWork;measurePreparation()
      if let report=preparationReport,report.maximumRelativeError<=config.maximumRelativeError,report.p95RelativeError<=config.maximumP95RelativeError {
        preparationReport?.status = .ready;velocities=[SIMD3<Double>](repeating:.zero,count:positions.count);lambdas=[Double](repeating:0,count:mesh.links.count)
        return diagnostics
      }
    }
    if let report=preparationReport,report.passes>=config.maximumPasses || config.maximumEvaluations-report.evaluations<preparationPassWork {
      preparationReport?.status = .failed;status = .failed;lastError="Assembly preparation did not meet its declared 5% maximum/1% P95 structural error gate within its pass/work budget. Physical time has not advanced. Reset and revise source poses, supports or settings."
      throw FormError.invalid(lastError!)
    }
    return diagnostics
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
          if signed<0 {move(i,by:-normal*signed);touch=true}
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
                move(i,by:hit+remainder-normal*into-positions[i]);touch=true
              }
            }
          }
          let delta=positions[i]-center,distance=simd_length(delta)
          if distance<radius {
            normal=distance>1e-12 ? delta/distance:(simd_length_squared(from)>1e-20 ? simd_normalize(from):SIMD3<Double>(0,1,0))
            move(i,by:center+normal*radius-positions[i]);touch=true
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
        let weights=closest.weights
        var grouped:[Int:Double]=[:]
        for (vertex,weight) in [(t.a,weights.x),(t.b,weights.y),(t.c,weights.z)] {grouped[seamRoots[vertex],default:0]+=weight}
        let denominator=grouped.reduce(0.0){$0+inverseMass[$1.key]*$1.value*$1.value}
        guard denominator>0 else {continue}
        var normal:SIMD3<Double>
        if distance>1e-12 {normal=delta/distance}
        else {
          let prior=ClothContactGeometry.closestPoint(center,a:previous[t.a],b:previous[t.b],c:previous[t.c]).point-center,cross=simd_cross(b-a,c-a)
          normal=simd_length_squared(prior)>1e-20 ? simd_normalize(prior):(simd_length_squared(cross)>1e-20 ? simd_normalize(cross):SIMD3<Double>(0,1,0))
        }
        let correction=(radius-distance)/denominator
        for (vertex,weight) in grouped.sorted(by:{$0.key<$1.key}) where inverseMass[vertex]>0 && weight>0 {
          let distance=correction*weight*inverseMass[vertex];move(vertex,by:normal*distance)
          recordContact(vertex:vertex,collider:colliderIndex,normal:normal,correction:distance,contacts:&contacts)
        }
      }
    }
  }
  private func recordContact(vertex:Int,collider:Int,normal:SIMD3<Double>,correction:Double,contacts:inout [[Contact]]) {
    for member in seamMembers[seamRoots[vertex]] {
      if let index=contacts[member].firstIndex(where:{$0.collider==collider}) {contacts[member][index].normal=normal;contacts[member][index].correction=max(contacts[member][index].correction,correction)}
      else {contacts[member].append(.init(collider:collider,normal:normal,correction:correction))}
    }
  }
  private static func signedDistance(_ point:SIMD3<Double>,collider:ClothCollider,thickness:Double)->Double {
    let center=ClothMath.vector(collider.centerMm)/1000
    switch collider.kind {case .plane:return simd_dot(point-center,simd_normalize(ClothMath.vector(collider.normal)))-thickness
    case .sphere:return simd_distance(point,center)-collider.radiusMm/1000-thickness}
  }
  private static func clear(_ point:SIMD3<Double>,colliders:[ClothCollider],thickness:Double)->Bool {colliders.allSatisfy {signedDistance(point,collider:$0,thickness:thickness) >= -1e-10}}
  private var displaysSourcePose:Bool {preparationReport.map{$0.status != .ready} ?? false}
  public var diagnostics:ClothDiagnostics {
    let positions=displaysSourcePose ? sourcePose:self.positions
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
    var minimumRatio=1.0,relativeErrors:[Double]=[]
    for (index,link) in mesh.links.enumerated() {
      let length=simd_distance(positions[link.a],positions[link.b]),difference=abs(length-restLengths[index])*1000
      if link.kind == .seam {seam=max(seam,difference)}
      else if link.kind != .bendDistance {let ratio=length/max(restLengths[index],1e-12);error=max(error,difference);stretch=max(stretch,ratio);minimumRatio=min(minimumRatio,ratio);relativeErrors.append(abs(ratio-1))}
    }
    relativeErrors.sort()
    return .init(initialJoin:initialJoin,preparation:preparationReport,status:status,vertexCount:positions.count,triangleCount:mesh.triangles.count,constraintCount:mesh.links.count,pinnedCount:pinTargets.filter {$0 != nil}.count,
      elapsedSeconds:elapsedSeconds,completedFrames:completedFrames,evaluations:evaluations,totalMassKg:total,centerOfMassMm:ClothMath.point(center/total*1000),kineticEnergyJ:kinetic,potentialEnergyJ:potential,maximumSpeedMPerSecond:speed,maximumStretchRatio:stretch,minimumStructuralRatio:minimumRatio,maximumStructuralRelativeError:relativeErrors.last ?? 0,structuralP95RelativeError:relativeErrors.isEmpty ? 0:relativeErrors[Int(Double(relativeErrors.count-1)*0.95)],maximumDistanceErrorMm:error,maximumSeamGapMm:seam,maximumVertexPenetrationMm:max(0,penetration),maximumSurfacePenetrationMm:max(0,penetration,surfacePenetration),distanceForcesEstimated:completedFrames>0,maximumConstraintForceN:completedFrames>0 ? (lambdas.map {abs($0)/(h*h)}.max() ?? 0):0,lastError:lastError)
  }
  public var frame:ClothFrame {
    let positions=displaysSourcePose ? sourcePose:self.positions
    var normals=[SIMD3<Double>](repeating:.zero,count:positions.count)
    for t in mesh.triangles {let normal=simd_cross(positions[t.b]-positions[t.a],positions[t.c]-positions[t.a]);normals[t.a]+=normal;normals[t.b]+=normal;normals[t.c]+=normal}
    return .init(positionsMm:positions.map {ClothMath.point($0*1000)},preparationCandidatePositionsMm:displaysSourcePose && preparationReport?.status != .pending ? self.positions.map{ClothMath.point($0*1000)}:nil,normals:normals.map {ClothMath.point(simd_length_squared($0)>1e-20 ? simd_normalize($0):SIMD3<Double>(0,1,0))},velocitiesMPerSecond:velocities.map(ClothMath.point),pinnedVertices:pinTargets.indices.filter {pinTargets[$0] != nil},diagnostics:diagnostics)
  }
}
