import AppKit
import CryptoKit
import FormCore
import FormGeometry
import LabRendering
import simd

/// Captures one isolated object with the same native materials and lighting as
/// the table. The transparent PNG is independent of the table camera and pose.
@MainActor enum ObjectViewRendering {
  static func render(object: ProductObject, project: Project, assets: URL,
                     azimuth: Double, elevation: Double, frameSize: CGSize,
                     pixels: Int = 2048) async throws -> Data {
    guard azimuth.isFinite, elevation.isFinite, frameSize.width.isFinite,
      frameSize.height.isFinite, frameSize.width > 0, frameSize.height > 0,
      (64...4096).contains(pixels) else {
      throw FormError.invalid("Choose finite view angles, a positive frame, and 64–4096 output pixels.")
    }
    try Task.checkCancellation()
    let solids=try await SolidRecipeGeometry.prepareFullSources(project:project,objectIDs:[object.id])
    let values = try renderables(object: object, project: project, assets: assets,solidSurface:solids[object.id])
    let width: Int, height: Int
    if frameSize.width >= frameSize.height {
      width = pixels; height = max(1, Int((Double(pixels) * Double(frameSize.height / frameSize.width)).rounded()))
    } else {
      height = pixels; width = max(1, Int((Double(pixels) * Double(frameSize.width / frameSize.height)).rounded()))
    }
    let camera = try camera(for: values, azimuth: azimuth, elevation: elevation,
                            aspect: Double(width) / Double(height))
    let renderer = try RealityKitSceneRenderer(frame: .init(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    defer { renderer.reset() }
    for value in values where value.visible {
      try Task.checkCancellation()
      try await renderer.upsertAsync(value)
    }
    try renderer.setCamera(camera)
    let image = try await renderer.capture(width: width, height: height, transparent: true, camera: camera)
    try Task.checkCancellation()
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
      throw FormError.invalid("Could not encode the rendered object view.")
    }
    return png
  }

  static func renderables(object: ProductObject, project: Project, assets: URL,solidSurface:SolidSurface?=nil) throws -> [SceneRenderablePayload] {
    if let reference = object.meshAsset {
      let document = try ModelAssetCoordinator.readAsset(reference, assets: assets)
      let scene = try MeshAssetSceneAdapter.prepare(document: document, reference: reference)
      var image: CGImage?, revision = "none"
      if let art = project.surfaceArtwork(object) {
        let rendered = GeometryFactory.artworkImage(art, width: object.artworkSize.x,
          depth: object.artworkSize.y, assets: assets, textureLimit: 2048)
        image = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if let bytes = try? art.renderCacheData() {
          revision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
      }
      let appearance = try MeshAssetSceneAdapter.appearance(scene, reference: reference,
        artwork: image, artworkRevision: revision)
      return MeshAssetSceneAdapter.renderables(appearance, objectID: object.id,
        scalePercent: object.parameters["scalePercent"] ?? 100)
    }
    if object.cadRepresentation != nil {
      var local = object; local.position = .init(); local.rotation = 0
      let prepared = try CADSceneAdapter.prepare(for: local, assets: assets)
      return try CADSurfaceAppearance.apply(prepared, object: local, project: project,
        assets: assets, materials: project.materials + FormCore.Material.presets)
    }
    let prepared:SolidSurface?
    if let definition=project.recipe(object.recipeID)?.solid {
      prepared=try solidSurface ?? SolidRecipeGeometry.cachedSurface(definition,parameters:object.parameters)
      guard prepared != nil else{throw FormError.invalid("The full-detail solid view is still preparing.")}
    }else{prepared=nil}
    guard prepared?.isEditingPreview != true else{throw FormError.invalid("Rendered object views require the full-detail solid source.")}
    let scene = MeshScene()
    scene.rootNode.addChildNode(GeometryFactory.object(object, project: project, assets: assets,solidSurface:prepared,solidRevision:prepared.map{_ in "full-object-view"}))
    return GeometryPayloadAdapter().renderables(scene: scene)
  }

  /// Fit the projected object in the existing placement's aspect ratio without
  /// changing its dimensions. Its angle-independent sphere matches vector views.
  static func camera(for values: [SceneRenderablePayload], azimuth: Double,
                     elevation: Double, aspect: Double) throws -> SceneCameraPayload {
    guard azimuth.isFinite, elevation.isFinite, aspect.isFinite, aspect > 0 else {
      throw FormError.invalid("The object view camera has invalid dimensions.")
    }
    let a = azimuth * .pi / 180, e = elevation * .pi / 180
    let right = SIMD3<Double>(cos(a), 0, -sin(a))
    let up = SIMD3<Double>(-sin(a)*sin(e), cos(e), -cos(a)*sin(e))
    let outward = simd_cross(right, up)
    var framing = ObjectViewFraming()
    for value in values where value.visible {
      let transform = value.transform.matrixMM
      // Match the vector engine's referenced triangles; unused import vertices
      // must not shift the object frame or change its scale.
      for part in value.mesh.parts {
        for index in part.triangleIndices {
          guard Int(index) < value.mesh.positionsMM.count else {
            throw FormError.invalid("The object contains invalid render geometry.")
          }
          let v = transform * SIMD4(value.mesh.positionsMM[Int(index)], 1)
          try framing.include(.init(v.x, v.y, v.z))
        }
      }
    }
    let fixedFrame = try framing.bounds()
    let span = ObjectViewFraming.diameterPadding * fixedFrame.radius * max(1, 1 / aspect)
    let distance = max(1, fixedFrame.radius + span)
    let eye = fixedFrame.center + outward * distance
    return SceneCameraPayload(worldFromCameraMM: .init(SIMD4(right,0), SIMD4(up,0),
      SIMD4(outward,0), SIMD4(eye,1)), projection: .orthographic(verticalSpanMM: span),
      nearMM: max(0.000001, span * 0.0001), farMM: distance * 2 + span + 1)
  }
}
