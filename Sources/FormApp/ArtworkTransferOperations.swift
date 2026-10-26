import AppKit
import CoreFoundation
import FormCore
import FormGraphics

@MainActor struct PreparedArtworkTransfer {
  var bundle:ArtworkTransferBundle,projectID:UUID,projectEpoch:UUID,objectID:UUID,scopeID:UUID?,offset:Point2
  var report:ArtworkTransferPreflight.Report
}

extension StudioStore {
  func invalidateArtworkTransferProject() {
    artworkTransferProjectEpoch=UUID()
    artworkSession.cancelArtworkTransfer()
  }
  func captureArtworkTransfer(objectID:UUID,ids:Set<UUID>)throws->ArtworkTransferBundle {
    guard let project else{throw FormError.missing("Open a project to copy artwork.")}
    let folder=repository.url(for:project.id).appendingPathComponent("Assets")
    let bundle=try ArtworkTransferGraph.capture(project:project,objectID:objectID,ids:ids,readAsset:{name,limit in
      guard let bytes=try ArtworkTransferIO.readAsset(directory:folder,name:name,limit:limit) else{throw FormError.missing("The original asset is missing: \(name).")};return bytes
    })
    _ = try ArtworkTransferPreflight.validate(bundle);return bundle
  }
  func prepareArtworkTransfer(_ bundle:ArtworkTransferBundle,objectID:UUID,scopeID:UUID?=nil,offset:Point2 = .init(10,10))throws->PreparedArtworkTransfer {
    guard let project else{throw FormError.missing("Open a paste destination.")}
    let report=try ArtworkTransferPreflight.validate(bundle)
    let folder=repository.url(for:project.id).appendingPathComponent("Assets")
    _ = try ArtworkTransferGraph.plan(bundle,into:project,objectID:objectID,scopeID:scopeID,offset:offset,existingAsset:{name,limit in try ArtworkTransferIO.readAsset(directory:folder,name:name,limit:limit)})
    return .init(bundle:bundle,projectID:project.id,projectEpoch:artworkTransferProjectEpoch,objectID:objectID,scopeID:scopeID,offset:offset,report:report)
  }
  func canonicalTransferBlobs(_ prepared:PreparedArtworkTransfer)throws->[String:Data] {
    var result=[String:Data]()
    for asset in prepared.bundle.metadata.assets {let data=prepared.bundle.blobs[asset.sourceName]!;if let prior=result[asset.portableName],prior != data {throw FormError.invalid("Portable asset identities collide.")};result[asset.portableName]=data}
    return result
  }
  /// The only editor handoff. All input and the initial destination were checked.
  /// Replan after commit so a lagging live text draft cannot be overwritten.
  func commitArtworkTransfer(_ prepared:PreparedArtworkTransfer,publication:ArtworkTransferPublication?,source:String,
    beforePublish:((String,Int)throws->Void)?=nil,afterPublish:(()throws->Void)?=nil,validateContext:(()throws->Void)?=nil)throws->[String:Any] {
    do {
      try validateContext?()
      guard let beforeHandoff=project,beforeHandoff.id==prepared.projectID,artworkTransferProjectEpoch==prepared.projectEpoch else{throw FormError.invalid("The paste project changed before editor handoff.")}
      let folder=repository.url(for:beforeHandoff.id).appendingPathComponent("Assets")
      // Staging may have suspended while a target was deleted, locked or changed.
      // Reject its current invalid context without ending another live editor.
      _ = try ArtworkTransferGraph.plan(prepared.bundle,into:beforeHandoff,objectID:prepared.objectID,scopeID:prepared.scopeID,offset:prepared.offset,existingAsset:{name,limit in try ArtworkTransferIO.readAsset(directory:folder,name:name,limit:limit)})
      try validateContext?()
      finishArtworkEditing()
      try validateContext?()
      guard let current=project,current.id==prepared.projectID,artworkTransferProjectEpoch==prepared.projectEpoch else{throw FormError.invalid("The paste destination changed during editor handoff.")}
      let plan=try ArtworkTransferGraph.plan(prepared.bundle,into:current,objectID:prepared.objectID,scopeID:prepared.scopeID,offset:prepared.offset,existingAsset:{name,limit in try ArtworkTransferIO.readAsset(directory:folder,name:name,limit:limit)})
      if !plan.assetWrites.isEmpty {guard let publication else{throw FormError.invalid("Portable asset staging is missing.")};try publication.publish(plan.assetWrites,beforeEach:beforePublish)}
      try afterPublish?()
      try engine.edit("Pasted portable artwork",source:source) {$0=try plan.applying(to:$0)}
      publication?.finish("committed")
      let missing=FontLibraryCatalog.usage(plan.project).filter{$0["available"] as? Bool==false}
      return ["selected_elements":plan.selection.map(\.uuidString),"added_component_objects":plan.addedComponentIDs.map(\.uuidString),"imported_assets":plan.assetWrites.keys.sorted(),"published_assets":publication?.published.map{$0.name} ?? [],"reused_assets":Set(plan.assetMap.values).subtracting(Set(plan.assetWrites.keys)).union(publication?.reused ?? []).sorted(),"journal":publication?.journal as Any? ?? NSNull(),"source_project_id":prepared.bundle.metadata.projectID.uuidString,"missing_font_assignments":missing,"decoded_pixels":prepared.report.rasterPixels,"vector_elements":prepared.report.vectorElements,"opaque_provenance_assets":prepared.report.opaqueProvenance]
    }catch {if let publication {throw publication.failure(error)};throw error}
  }
  func importArtworkTransfer(_ prepared:PreparedArtworkTransfer,source:String,validateContext:(()throws->Void)?=nil)async throws->[String:Any] {
    let blobs=try canonicalTransferBlobs(prepared),folder=repository.url(for:prepared.projectID).appendingPathComponent("Assets")
    let checkpoint=artworkTransferStageCheckpoint
    let stage:ArtworkTransferPublication?
    if blobs.isEmpty {stage=nil}else{
      let job=Task.detached(priority:.userInitiated){try ArtworkTransferPublication.prepare(directory:folder,blobs:blobs)}
      stage=try await withTaskCancellationHandler(operation:{try await job.value},onCancel:{job.cancel()})
    }
    if let checkpoint {await checkpoint()}
    do {try Task.checkCancellation();try validateContext?();return try commitArtworkTransfer(prepared,publication:stage,source:source,validateContext:validateContext)}catch{if let stage {throw stage.failure(error)};throw error}
  }
  func artworkTransferArguments(_ args:[String:Any])throws->(String,UUID,URL,UUID?,Point2,Set<UUID>) {
    guard Set(args.keys).isSubset(of:["command","object_id","transfer_path","element_ids","scope_id","offset_x","offset_y","_source"]),let command=args["command"] as? String,ArtworkTransferCommands.names.contains(command),let raw=args["object_id"] as? String,let id=UUID(uuidString:raw),let path=args["transfer_path"] as? String,path.hasPrefix("/"),URL(fileURLWithPath:path).pathExtension.lowercased()=="formart",!path.contains("\0") else{throw FormError.invalid("Portable file transfer requires a command, object_id and absolute transfer_path; unknown arguments are rejected.")}
    let scope:UUID?
    if let raw=args["scope_id"] {guard command==ArtworkTransferCommands.importName,let text=raw as? String,let id=UUID(uuidString:text) else{throw FormError.invalid("scope_id is an import-only group UUID.")};scope=id}else{scope=nil}
    var offset=Point2(10,10)
    if args["offset_x"] != nil || args["offset_y"] != nil {
      guard command==ArtworkTransferCommands.importName,let x=args["offset_x"] as? NSNumber,let y=args["offset_y"] as? NSNumber,CFGetTypeID(x) != CFBooleanGetTypeID(),CFGetTypeID(y) != CFBooleanGetTypeID(),x.doubleValue.isFinite,y.doubleValue.isFinite else{throw FormError.invalid("Imports accept both finite millimeter offsets together.")};offset = .init(x.doubleValue,y.doubleValue)
    }
    let ids:Set<UUID>
    if let value=args["element_ids"] {guard command==ArtworkTransferCommands.exportName,let raw=value as? [String],!raw.isEmpty,raw.count<=2048 else{throw FormError.invalid("element_ids is an export-only selection.")};ids=Set(raw.compactMap(UUID.init(uuidString:)));guard ids.count==raw.count else{throw FormError.invalid("Use distinct source element UUIDs.")}}else{ids=[]}
    return(command,id,URL(fileURLWithPath:path),scope,offset,ids)
  }
  func artworkTransferCall(_ args:[String:Any])throws->Any {
    let(command,id,path,scope,offset,requested)=try artworkTransferArguments(args)
    if command==ArtworkTransferCommands.exportName {
      guard let project,let object=project.objects.first(where:{$0.id==id}),let art=project.editableArtwork(object) else{throw FormError.missing("Choose an artwork source.")}
      let ids=requested.isEmpty ? Set(art.elements.map(\.id)):requested,bundle=try captureArtworkTransfer(objectID:id,ids:ids),data=try bundle.encoded()
      try ArtworkTransferFile.writeNew(data,to:path)
      return ["path":path.path,"bytes":data.count,"sha256":ArtworkTransferBundle.digest(data),"source_project_id":project.id.uuidString,"source_schema":bundle.metadata.sourceSchema,"source_snapshot":"committed project source","read_only":true]
    }
    let bundle=try ArtworkTransferBundle.decode(ArtworkTransferFile.read(path)),prepared=try prepareArtworkTransfer(bundle,objectID:id,scopeID:scope,offset:offset),blobs=try canonicalTransferBlobs(prepared)
    let stage=try blobs.isEmpty ? nil:ArtworkTransferPublication.prepare(directory:repository.url(for:prepared.projectID).appendingPathComponent("Assets"),blobs:blobs)
    return try commitArtworkTransfer(prepared,publication:stage,source:args["_source"] as? String ?? "Codex")
  }
  func artworkTransferCallAsync(_ args:[String:Any])async throws->Any {
    guard let initialProjectID=project?.id else{throw FormError.missing("Open an artwork project first.")}
    let initialProjectEpoch=artworkTransferProjectEpoch
    let(command,id,path,scope,offset,requested)=try artworkTransferArguments(args)
    if command==ArtworkTransferCommands.exportName {
      guard let snapshot=project,let object=snapshot.objects.first(where:{$0.id==id}),let art=snapshot.editableArtwork(object) else{throw FormError.missing("Choose an artwork source.")}
      let ids=requested.isEmpty ? Set(art.elements.map(\.id)):requested,bundle=try captureArtworkTransfer(objectID:id,ids:ids),data=try bundle.encoded()
      try await Task.detached(priority:.userInitiated){try ArtworkTransferFile.writeNew(data,to:path)}.value
      return ["path":path.path,"bytes":data.count,"sha256":ArtworkTransferBundle.digest(data),"source_project_id":snapshot.id.uuidString,"source_schema":bundle.metadata.sourceSchema,"source_snapshot":"committed project source","read_only":true]
    }
    let job=Task.detached(priority:.userInitiated){try ArtworkTransferBundle.decode(ArtworkTransferFile.read(path))},bundle=try await job.value
    guard project?.id==initialProjectID,artworkTransferProjectEpoch==initialProjectEpoch else{throw FormError.invalid("The destination project changed while reading its transfer file.")}
    let prepared=try prepareArtworkTransfer(bundle,objectID:id,scopeID:scope,offset:offset)
    return try await importArtworkTransfer(prepared,source:"Codex")
  }
}
