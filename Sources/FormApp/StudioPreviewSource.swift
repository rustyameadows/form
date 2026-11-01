import FormCore
import Foundation

/// In-memory equivalent of studioDesignDigest's source boundary. Value equality
/// preserves every existing design dependency without serializing a dense
/// document whenever a scene row or selection is refreshed.
enum StudioPreviewSource {
  static func design(_ project:Project)->Project {
    var source=project
    source.camera = .init();source.studioPresentation=nil;source.collectionProduction=nil;source.history=[]
    source.createdAt=Date(timeIntervalSince1970:0);source.updatedAt=source.createdAt;source.schemaVersion=1
    return source
  }
  static func thumbnailDesign(_ project:Project)->Project {
    var source=design(project)
    // Editor-only frame placement cannot affect a saved physical still. Keep
    // this narrower key separate from the exact resolved-object cache, which
    // also returns the source records' non-rendering metadata to its callers.
    source.objects=source.objects.map(ObjectViewSourceChanges.withoutCanvasPlacement)
    return source
  }
  static func thumbnail(_ scene:StudioComposition)->StudioComposition {
    var result=scene
    // A saved still does not depend on its label, revision counter or animation.
    result.name="Scene";result.revision=1;result.motion = .init()
    return result
  }
}

/// Keeps only derived render objects, not obsolete project metadata. Root
/// placement is reapplied on a hit, so dragging an instance does not repeatedly
/// discover and duplicate its attachment family.
@MainActor final class StudioCompositionResolutionCache {
  private struct Entry {
    let instances:[StudioInstance],objects:[ProductObject],visible:Set<UUID>
  }
  private var source:Project?
  private var entries:[Entry]=[]
  private(set) var sourceRevision=0
  private(set) var builds=0
  @discardableResult func synchronize(_ project:Project)->Int {
    let next=StudioPreviewSource.design(project)
    if source != next {source=next;entries=[];sourceRevision &+= 1}
    return sourceRevision
  }
  func reset(){source=nil;entries=[];sourceRevision &+= 1}
  func resolve(_ scene:StudioComposition,in project:Project)throws->(project:Project,visible:Set<UUID>) {
    try scene.validate();synchronize(project)
    let structure=scene.instances.map{value in
      var key=value;key.name="Instance";key.positionMM = .init();key.rotationDegrees=0;return key
    }
    let entry:Entry
    if let index=entries.firstIndex(where:{$0.instances==structure}) {
      entry=entries.remove(at:index);entries.append(entry)
    }else {
      let resolved=try scene.resolved(in:project)
      entry = .init(instances:structure,objects:Array(resolved.project.objects.dropFirst(project.objects.count)),visible:resolved.visible)
      entries.append(entry);if entries.count>8 {entries.removeFirst()};builds &+= 1
    }
    let roots=Dictionary(uniqueKeysWithValues:scene.instances.map{($0.id,$0)})
    var objects=entry.objects
    for index in objects.indices {
      guard let instance=roots[objects[index].id] else{continue}
      objects[index].position=instance.positionMM;objects[index].rotation=instance.rotationDegrees;objects[index].name=instance.name
    }
    var result=project;result.objects+=objects;result.camera=scene.camera
    return (result,entry.visible)
  }
}
