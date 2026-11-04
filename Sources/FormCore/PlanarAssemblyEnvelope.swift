import Foundation

/// One closed physical envelope for dimensions, fit sections and final display grounding.
/// The pure panel poser remains independent of attachments, preventing recursive resolution.
public struct PlanarAssemblyEnvelope:Codable,Equatable,Sendable {
  /// Bounds after the additive assembly-root grounding offset has been applied.
  public var minimumMM:Vector3,maximumMM:Vector3
  /// The unshifted coordinates used by resolved panel transforms and anchored wire paths.
  public var panelFrameMinimumMM:Vector3,panelFrameMaximumMM:Vector3
  /// Apply once to the entire assembly render root, never independently to pieces.
  public var groundOffsetMM:Vector3
  public var sizeMM:Vector3 {.init(maximumMM.x-minimumMM.x,maximumMM.y-minimumMM.y,maximumMM.z-minimumMM.z)}
  public static func resolve(_ source:PaperConstruction)throws->PlanarAssemblyEnvelope {
    try source.stock.validate()
    var closed=source;closed.foldPercent=100;closed.openingPercent=0
    if closed.explosionPercent != nil {closed.explosionPercent=0}
    let net=try closed.authored?.net() ?? PaperConstructionEngine.net(closed)
    let poses:[PaperResolvedPanel]
    if closed.authored?.components?.isEmpty == false {poses=try PlanarComponentPoseResolver.resolve(closed,net:net,amount:1).panels}
    else{poses=try closed.resolvedPanels(foldPercent:100)}
    let values=try closed.authored?.poseValues(fold:100,opening:0,explosion:0) ?? [:]
    let matrices=Dictionary(uniqueKeysWithValues:poses.map{($0.panelID,$0.flatToWorld)})
    var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    func include(_ point:Vector3,radius:Double=0) {
      low = .init(min(low.x,point.x-radius),min(low.y,point.y-radius),min(low.z,point.z-radius))
      high = .init(max(high.x,point.x+radius),max(high.y,point.y+radius),max(high.z,point.z+radius))
    }
    for panel in net.panels {
      guard let matrix=matrices[panel.id] else{throw FormError.invalid("The physical envelope cannot find cut-piece face '\(panel.id)'.")}
      for point in try panel.physicalBoundarySamples(stock:panel.resolvedStock(fallback:source.stock),variables:values,worldMatrix:matrix) {
        include(PaperRigidMatrix.point(matrix,point))
      }
    }
    if let definition=closed.authored,definition.jointAttachments?.isEmpty == false {
      let attachments=try definition.resolveJointAttachments(stock:closed.stock,validateEngagement:true)
      for staple in attachments.staples {
        for ring in try PlanarWireSection.corners(pointsMM:staple.pointsMM,widthMM:staple.wireWidthMM,depthMM:staple.wireDepthMM) {
          for point in ring {include(point)}
        }
      }
    }
    guard [low.x,low.y,low.z,high.x,high.y,high.z].allSatisfy(\.isFinite) else{throw FormError.invalid("The closed assembly envelope has no finite physical material.")}
    let offset=Vector3(0,max(0,-low.y),0)
    return .init(minimumMM:.init(low.x,low.y+offset.y,low.z),maximumMM:.init(high.x,high.y+offset.y,high.z),panelFrameMinimumMM:low,panelFrameMaximumMM:high,groundOffsetMM:offset)
  }
}
