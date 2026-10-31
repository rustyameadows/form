import AppKit
import FormCore
import LabRendering
import simd

/// Editing-only, world-aligned handles. Geometry and input share the renderer's
/// camera projection; every screen point here is native AppKit (+Y up).
struct StudioTransformGizmo {
  enum Handle:String,CaseIterable {case x,y,z,yaw}
  struct Axis {
    let handle:Handle,tip:CGPoint,world:SIMD3<Double>,endOn:Bool
  }
  let centerMM:SIMD3<Double>,center:CGPoint,camera:SceneCameraPayload,viewport:CGSize
  let millimetersPerPoint:Double,lengthMM:Double,axes:[Axis],ring:[CGPoint],ringFallback:Bool
  init?(centerMM:SIMD3<Double>,camera:SceneCameraPayload,viewport:CGSize) {
    guard let raw=SceneProjection.project(centerMM,camera:camera,viewport:viewport),viewport.width>0,viewport.height>0 else{return nil}
    self.centerMM=centerMM;self.camera=camera;self.viewport=viewport
    let origin=CGPoint(x:raw.x,y:viewport.height-raw.y);center=origin
    let local=simd_inverse(camera.worldFromCameraMM)*SIMD4(centerMM,1)
    switch camera.projection {
    case .perspective(let degrees):millimetersPerPoint=2*(-local.z)*tan(degrees*Double.pi/360)/viewport.height
    case .orthographic(let span):millimetersPerPoint=span/viewport.height
    }
    guard millimetersPerPoint.isFinite,millimetersPerPoint>0 else{return nil}
    lengthMM=84*millimetersPerPoint
    func screen(_ p:SIMD3<Double>)->CGPoint? {
      SceneProjection.project(p,camera:camera,viewport:viewport).map{.init(x:$0.x,y:viewport.height-$0.y)}
    }
    var items=[Axis]()
    for (handle,world) in [(Handle.x,SIMD3<Double>(1,0,0)),(.y,.init(0,1,0)),(.z,.init(0,0,1))] {
      guard let tip=screen(centerMM+world*lengthMM) else{continue}
      let endOn=hypot(tip.x-center.x,tip.y-center.y)<12
      items.append(.init(handle:handle,tip:endOn ? center:tip,world:world,endOn:endOn))
    }
    guard items.count==3 else{return nil};axes=items
    var points=[CGPoint]()
    for i in 0...72 {
      let angle=Double(i)*2*Double.pi/72
      if let point=screen(centerMM+SIMD3(cos(angle),0,-sin(angle))*lengthMM*0.76) {points.append(point)}
    }
    let low=points.map(\.y).min() ?? 0,high=points.map(\.y).max() ?? 0
    let outwardY=camera.worldFromCameraMM.columns.2.y
    ringFallback=points.count != 73 || high-low<18 || abs(outwardY)<0.1
    if ringFallback {
      points=(0...72).map {i in let a=Double(i)*2*Double.pi/72;return .init(x:origin.x+cos(a)*64,y:origin.y+sin(a)*64)}
    }
    ring=points
  }
  func axis(_ handle:Handle)->Axis? {axes.first{$0.handle==handle}}
  func handlePoint(_ handle:Handle)->CGPoint? {
    if handle == .yaw {
      return ([9,27,45,63]+Array(ring.indices)).filter{ring.indices.contains($0)}.map{ring[$0]}.first{hitTest($0) == .yaw}
    }
    return axis(handle)?.tip
  }
  func hitTest(_ point:CGPoint)->Handle? {
    // Caps outrank crossing lines/rings. An end-on axis remains a distinct
    // labeled depth control even when its 3D projection has zero length.
    for axis in axes.sorted(by:{$0.endOn && !$1.endOn}) where hypot(point.x-axis.tip.x,point.y-axis.tip.y)<=10 {return axis.handle}
    var closest:(Handle,Double)?
    for axis in axes where !axis.endOn {
      let distance=Self.distance(point,from:center,to:axis.tip)
      if distance<6,closest==nil || distance<closest!.1 {closest=(axis.handle,distance)}
    }
    if let closest{return closest.0}
    for i in ring.indices.dropFirst() where Self.distance(point,from:ring[i-1],to:ring[i])<7 {return .yaw}
    return nil
  }
  /// Closest point on a world axis to the pointer ray. Near-parallel views use
  /// a bounded screen-depth gesture, never divide by a vanishing projection.
  func axisParameter(_ handle:Handle,at point:CGPoint)->Double? {
    guard let axis=axis(handle) else{return nil}
    if !axis.endOn,let ray=ray(point) {
      let c=simd_dot(axis.world,ray.direction),denominator=1-c*c,w=centerMM-ray.originMM
      if denominator>0.01 {
        let value=(c*simd_dot(ray.direction,w)-simd_dot(axis.world,w))/denominator
        if value.isFinite {return value}
      }
    }
    let vector:CGPoint=handle == .x ? .init(x:1,y:0):handle == .y ? .init(x:0,y:1):.init(x:0,y:-1)
    return ((point.x-center.x)*vector.x+(point.y-center.y)*vector.y)*millimetersPerPoint
  }
  func yawAngle(at point:CGPoint)->Double? {
    if ringFallback {return atan2(point.y-center.y,point.x-center.x)}
    guard let ray=ray(point),let hit=SceneProjection.intersect(ray,planePointMM:centerMM,normal:.init(0,1,0)) else{return nil}
    let delta=hit-centerMM
    guard delta.x*delta.x+delta.z*delta.z>1e-12 else{return nil}
    return atan2(-delta.z,delta.x)
  }
  private func ray(_ point:CGPoint)->SceneRay? {SceneProjection.ray(camera:camera,atTopLeft:.init(x:point.x,y:viewport.height-point.y),viewport:viewport)}
  private static func distance(_ p:CGPoint,from a:CGPoint,to b:CGPoint)->Double {
    let dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy
    guard length>1e-12 else{return hypot(p.x-a.x,p.y-a.y)}
    let t=max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length))
    return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
  }
  @MainActor func draw() {
    NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
    let path=NSBezierPath();if let first=ring.first {path.move(to:first);for point in ring.dropFirst(){path.line(to:point)}}
    NSColor.white.withAlphaComponent(0.8).setStroke();path.lineWidth=4;path.stroke()
    NSColor.systemGreen.withAlphaComponent(0.9).setStroke();path.lineWidth=1.8;path.stroke()
    for axis in axes {
      let color: NSColor=axis.handle == .x ? .systemRed:axis.handle == .y ? .systemGreen:.systemBlue
      let line=NSBezierPath();line.move(to:center);line.line(to:axis.tip)
      NSColor.white.withAlphaComponent(0.9).setStroke();line.lineWidth=5;line.stroke()
      color.setStroke();line.lineWidth=2.6;line.stroke()
      if axis.endOn {
        NSColor.white.setFill();NSBezierPath(ovalIn:.init(x:center.x-7,y:center.y-7,width:14,height:14)).fill()
        let cap=NSBezierPath(ovalIn:.init(x:center.x-6,y:center.y-6,width:12,height:12));cap.lineWidth=2;color.setStroke();cap.stroke()
        color.setFill();NSBezierPath(ovalIn:.init(x:center.x-2,y:center.y-2,width:4,height:4)).fill()
      }else {
        let angle=atan2(axis.tip.y-center.y,axis.tip.x-center.x),arrow=NSBezierPath()
        arrow.move(to:axis.tip)
        arrow.line(to:.init(x:axis.tip.x-11*cos(angle-0.4),y:axis.tip.y-11*sin(angle-0.4)))
        arrow.line(to:.init(x:axis.tip.x-11*cos(angle+0.4),y:axis.tip.y-11*sin(angle+0.4)));arrow.close();color.setFill();arrow.fill()
      }
      let label=axis.handle.rawValue.uppercased()+(axis.endOn ? " ·":"")
      let location=axis.endOn ? CGPoint(x:center.x+9,y:center.y-17):CGPoint(x:axis.tip.x+5,y:axis.tip.y+4)
      (label as NSString).draw(at:location,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.semibold),.foregroundColor:color,.strokeColor:NSColor.white.withAlphaComponent(0.9),.strokeWidth:-3])
    }
    if let point=ring.first {
      ("Y ↻" as NSString).draw(at:.init(x:point.x+6,y:point.y-14),withAttributes:[.font:NSFont.systemFont(ofSize:9,weight:.semibold),.foregroundColor:NSColor.systemGreen,.strokeColor:NSColor.white,.strokeWidth:-3])
    }
  }
}

/// Native overlay above the existing renderer, never part of scene/capture data.
@MainActor final class StudioTransformGizmoOverlay:NSView {
  weak var tableView:TableSceneView?
  override var isOpaque:Bool {false}
  override func hitTest(_ point:NSPoint)->NSView? {nil}
  override func draw(_ dirtyRect:NSRect) {tableView?.presentationInteraction?.presentationGizmo?.draw()}
}
