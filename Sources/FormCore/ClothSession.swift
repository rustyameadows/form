import Foundation
import CryptoKit

/// Only this initial definition belongs in a document. Current positions,
/// velocities, playback state and background work remain session-local.
public struct ClothStudy:Codable,Equatable,Sendable {
  public var mesh:ClothMesh
  public var settings:ClothSettings
  public var colliders:[ClothCollider]
  public init(mesh:ClothMesh,settings:ClothSettings = .init(),colliders:[ClothCollider] = []) {
    self.mesh=mesh;self.settings=settings;self.colliders=colliders
  }
  public func validate()throws {_ = try ClothSolver(mesh:mesh,settings:settings,colliders:colliders)}
  public var digest:String {get throws {
    try validate()
    return SHA256.hash(data:try JSONEncoder.form.encode(self)).map {String(format:"%02x",$0)}.joined()
  }}
  public static let unsupportedPrintReason="Cloth is an open flexible surface, not a closed printable solid. Create and validate an explicit solid before slicing."
}

/// The revision is supplied by the owning document controller. It must change
/// for relevant geometry/material/UV edits, including document Undo/Redo.
public struct ClothSourceIdentity:Equatable,Sendable {
  public var projectID:UUID
  public var objectID:UUID
  public var revision:String
  public init(projectID:UUID,objectID:UUID,revision:String) {self.projectID=projectID;self.objectID=objectID;self.revision=revision}
}
public struct ClothWorkToken:Equatable,Sendable {
  fileprivate var owner:UUID
  fileprivate var generation:UInt64
  fileprivate var sequence:UInt64
}
public struct ClothWorkItem:Sendable {
  public let token:ClothWorkToken
  public let frames:Int
  fileprivate var state:ClothSolver
  /// May run off the document/UI actor. It holds a value snapshot, never the
  /// document or a live SceneKit node. A failed solve retains its valid frame.
  public func compute()->ClothWorkResult {
    var copy=state
    do {try copy.advance(frames:frames);return .init(token:token,state:copy,error:nil)}
    catch {return .init(token:token,state:copy,error:error.localizedDescription)}
  }
}
public struct ClothWorkResult:Sendable {
  public let token:ClothWorkToken
  fileprivate var state:ClothSolver
  public let error:String?
  public var frame:ClothFrame {state.frame}
}

/// Single-owner, demand-driven runtime. Keep it on the owning app actor.
/// Work snapshots are Sendable; only a matching outstanding token can publish.
/// Reading a frame never advances time or writes a document/history entry.
public struct ClothSession:Sendable {
  private let owner=UUID()
  private var generation:UInt64=0
  private var sequence:UInt64=0
  private var pending:ClothWorkToken?
  private var solver:ClothSolver?
  public private(set) var source:ClothSourceIdentity?
  public private(set) var studyDigest:String?
  public var frame:ClothFrame? {solver?.frame}
  public var mesh:ClothMesh? {solver?.mesh}
  public var hasPendingWork:Bool {pending != nil}
  public init() {}
  /// A valid changed definition resets to its declared initial state. Invalid
  /// replacement input leaves the current simulation and outstanding work intact.
  @discardableResult public mutating func bind(_ identity:ClothSourceIdentity,study:ClothStudy)throws -> Bool {
    guard !identity.revision.isEmpty,identity.revision.utf8.count<=256 else {throw FormError.invalid("Cloth source needs a bounded nonempty revision identity.")}
    let digest=try study.digest
    if source==identity,studyDigest==digest {return false}
    let replacement=try ClothSolver(mesh:study.mesh,settings:study.settings,colliders:study.colliders)
    invalidateWork();source=identity;studyDigest=digest;solver=replacement;return true
  }
  /// Call when closing, changing project, deleting the object, or invalidating
  /// a source before its replacement is available. Late results cannot revive it.
  public mutating func clear() {invalidateWork();solver=nil;source=nil;studyDigest=nil}
  public mutating func start()throws {
    guard var state=solver else {throw FormError.invalid("Choose a configured cloth study first.")}
    if state.isRunning {return}
    try state.start();invalidateWork();solver=state
  }
  public mutating func stop() {invalidateWork();solver?.stop()}
  public mutating func reset() {invalidateWork();solver?.reset()}
  /// Explicit Undo/Redo hook even when restored settings match an earlier digest.
  public mutating func sourceHistoryChanged() {reset()}
  public mutating func pin(_ vertex:Int,toMm target:Vector3)throws {
    guard var state=solver else {throw FormError.invalid("Choose a configured cloth study first.")}
    try state.pin(vertex,toMm:target);invalidateWork();solver=state
  }
  public mutating func unpin(_ vertex:Int)throws {
    guard var state=solver else {throw FormError.invalid("Choose a configured cloth study first.")}
    try state.unpin(vertex);invalidateWork();solver=state
  }
  public mutating func prepare(frames:Int = 1)throws -> ClothWorkItem {
    guard let state=solver,state.isRunning else {throw FormError.invalid("Start the cloth study before requesting steps.")}
    guard pending==nil else {throw FormError.invalid("One bounded cloth step is already pending. Stop it or wait for its result.")}
    try state.validateAdvanceRequest(frames:frames)
    sequence &+= 1
    let token=ClothWorkToken(owner:owner,generation:generation,sequence:sequence);pending=token
    return .init(token:token,frames:frames,state:state)
  }
  /// False means stale/duplicate/foreign work. It has no effect on the current
  /// frame, status or pending current-generation work.
  @discardableResult public mutating func accept(_ result:ClothWorkResult)->Bool {
    guard pending==result.token,result.token.owner==owner,result.token.generation==generation else {return false}
    pending=nil;solver=result.state;return true
  }
  @discardableResult public mutating func step(frames:Int = 1)throws -> ClothFrame {
    let result=try prepare(frames:frames).compute()
    guard accept(result),let frame else {throw FormError.invalid("The cloth source changed while the step was calculated.")}
    if let error=result.error {throw FormError.invalid(error)}
    return frame
  }
  private mutating func invalidateWork() {generation &+= 1;pending=nil}
}
