import Foundation

/// Shared stock snapshots own immutable texture bytes independently of their
/// source project. Only asset names change; every optical/mapping field survives.
enum PaperStockTextureAssets {
  static func libraryDirectory(in root:URL)->URL {root.appendingPathComponent("StudioMaterialAssets",isDirectory:true)}

  static func loadLibrary(from root:URL)throws->StudioLibrary {
    let url=root.appendingPathComponent("Studio.json")
    guard FileManager.default.fileExists(atPath:url.path) else{return .init()}
    do {return try JSONDecoder.form.decode(StudioLibrary.self,from:Data(contentsOf:url))}
    catch {throw FormError.invalid("The saved material library cannot be read. Restore Studio.json before saving or applying a stock.")}
  }

  static func map(_ material:Material,_ transform:(PhysicalTextureReference)throws->PhysicalTextureReference)throws->Material {
    func optics(_ source:PhysicalAppearance?)throws->PhysicalAppearance? {
      guard var value=source else{return nil}
      for channel in value.textures.keys.sorted() {value.textures[channel]=try transform(value.textures[channel]!)}
      return value
    }
    func profile(_ source:PaperSurfaceProfile?)throws->PaperSurfaceProfile? {
      guard var value=source else{return nil}
      value.appearance=try optics(value.appearance);value.edgeAppearance=try optics(value.edgeAppearance)
      return value
    }
    var result=material
    result.appearance=try optics(result.appearance)
    if var back=result.backSurface {back.appearance=try optics(back.appearance);result.backSurface=back}
    if var stock=result.paperStock {
      stock.profile=try profile(stock.profile)
      if var plies=stock.plies {
        for index in plies.indices {plies[index].profile=try profile(plies[index].profile)}
        stock.plies=plies
      }
      result.paperStock=stock
    }
    return result
  }

  struct Plan {
    let material:Material,destination:URL
    let resources:[(reference:PhysicalTextureReference,source:URL)]

    /// Stage and verify the whole closure before publishing any new pathname.
    /// Existing immutable names are reused only after digest verification; a
    /// conflict is never overwritten. Published immutable bytes survive Undo.
    func publish()throws {
      guard !resources.isEmpty else{return}
      let fm=FileManager.default
      try fm.createDirectory(at:destination,withIntermediateDirectories:true)
      let values=try destination.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
      guard values.isDirectory==true,values.isSymbolicLink != true else {throw FormError.invalid("Material assets need an ordinary destination directory.")}
      let stage=destination.appendingPathComponent(".lab-material-stage-"+UUID().uuidString,isDirectory:true)
      try fm.createDirectory(at:stage,withIntermediateDirectories:false)
      defer {try? fm.removeItem(at:stage)}
      var writes=[PhysicalTextureReference]()
      for resource in resources {
        try Task.checkCancellation()
        let target=destination.appendingPathComponent(resource.reference.asset)
        if fm.fileExists(atPath:target.path) {
          _ = try resource.reference.verifiedURL(in:destination)
        } else {
          try fm.copyItem(at:resource.source,to:stage.appendingPathComponent(resource.reference.asset))
          _ = try resource.reference.verifiedURL(in:stage)
          writes.append(resource.reference)
        }
      }
      for reference in writes {
        try Task.checkCancellation()
        do {
          // link(2) fails if a destination appears, unlike an overwriting rename.
          try fm.linkItem(at:stage.appendingPathComponent(reference.asset),to:destination.appendingPathComponent(reference.asset))
        } catch {
          guard fm.fileExists(atPath:destination.appendingPathComponent(reference.asset).path) else{throw error}
          _ = try reference.verifiedURL(in:destination)
        }
        _ = try reference.verifiedURL(in:destination)
      }
    }
  }

  static func prepare(_ material:Material,sources:[URL],destination:URL,canonicalNames:Bool=true)throws->Plan {
    let fm=FileManager.default
    var resources=[String:(reference:PhysicalTextureReference,source:URL)](),total:Int64=0
    let portable=try map(material) {reference in
      try reference.validate()
      let ext=URL(fileURLWithPath:reference.asset).pathExtension.lowercased()
      let safeExtension = !ext.isEmpty && ext.utf8.count<=16 && ext.unicodeScalars.allSatisfy{CharacterSet.alphanumerics.contains($0)} ? ext:"texture"
      var mapped=reference
      if canonicalNames {mapped.asset="material-"+reference.sha256+"."+safeExtension}
      if let prior=resources[mapped.asset] {
        guard prior.reference.sha256==reference.sha256 else{throw FormError.invalid("A stock texture filename has conflicting content hashes.")}
        return mapped
      }
      guard resources.count<1024 else{throw FormError.invalid("A reusable stock supports at most 1024 unique texture files.")}
      guard let source=sources.first(where:{fm.fileExists(atPath:$0.appendingPathComponent(reference.asset).path)}) else {
        throw FormError.invalid("Saved stock texture ‘\(reference.asset)’ is missing. Restore or reimport it before applying this material.")
      }
      let sourceValues=try source.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
      guard sourceValues.isDirectory==true,sourceValues.isSymbolicLink != true else {
        throw FormError.invalid("Saved stock textures need an ordinary source asset directory.")
      }
      // Prefer the owning source; corruption must not silently fall back to a
      // different library/project file with the same name.
      let verified=try reference.verifiedURL(in:source)
      total+=Int64(try verified.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)
      guard total<=2_147_483_648 else{throw FormError.invalid("Reusable stock textures exceed the 2 GiB portable resource budget.")}
      let target=destination.appendingPathComponent(mapped.asset)
      if fm.fileExists(atPath:target.path) {_ = try mapped.verifiedURL(in:destination)}
      resources[mapped.asset]=(mapped,verified)
      return mapped
    }
    return .init(material:portable,destination:destination,resources:resources.keys.sorted().map{resources[$0]!})
  }

  static func application(_ material:Material,projectID:UUID,repository:ProjectRepository,fromLibrary:Bool)throws->Plan {
    let project=repository.url(for:projectID).appendingPathComponent("Assets",isDirectory:true)
    // The project fallback retains old same-project stock records saved before
    // the library acquired its independent asset store. It never hides corruption.
    let sources=fromLibrary ? [libraryDirectory(in:repository.root),project]:[project]
    return try prepare(material,sources:sources,destination:project,canonicalNames:fromLibrary)
  }
}
