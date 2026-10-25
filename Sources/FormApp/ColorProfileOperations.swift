import AppKit
import FormCore
import FormGraphics
import UniformTypeIdentifiers

extension StudioStore {
  func colorProfileCall(_ args: [String: Any]) throws -> Any {
    let command = args["command"] as? String ?? "list"
    if command == "list" {
      return ["editing_color_space": "sRGB", "profiles": ICCOutputProfile.installed().map(\.json),
        "scope": "Actual ICC conversion for RGB artwork/publication PDF; declared production inks use explicit matching-profile composite/maps. Screen, SVG, PNG and JPEG remain sRGB appearance previews.","production_ink_output_modes":["preview","composite","plates","preflight"]]
    }
    guard ["get", "set", "clear"].contains(command),
      let raw = args["object_id"] as? String, let id = UUID(uuidString: raw), let project,
      let object = project.objects.first(where: { $0.id == id })
    else { throw FormError.invalid("Choose an artwork object and list, get, set, or clear profile command.") }
    let owner = project.artworkOwner(object)
    var artwork = owner.artwork ?? .init(background: "#FFFFFF")
    func summary(_ reference: ArtworkOutputProfile?) throws -> [String: Any] {
      ["object_id": owner.id.uuidString, "editing_color_space": "sRGB",
        "pdf_output_profile": try reference.map { try jsonObject($0) } ?? NSNull()]
    }
    if command == "get" { return try summary(artwork.outputColorProfile) }
    guard !owner.locked else { throw FormError.invalid("Unlock the artwork source before changing its output profile.") }
    let profile: ICCOutputProfile?
    if command == "clear" { profile = nil }
    else {
      guard let path = args["profile_path"] as? String, path.hasPrefix("/") else {
        throw FormError.invalid("Choose an absolute local ICC profile_path, or clear the profile.")
      }
      profile = try ICCOutputProfile(url: URL(fileURLWithPath: path))
    }
    guard artwork.outputColorProfile != profile?.reference else { return try summary(artwork.outputColorProfile) }
    if let profile {
      try profile.store(in: repository.url(for: project.id).appendingPathComponent("Assets"))
    }
    artwork.outputColorProfile = profile?.reference
    try engine.edit("Artwork: PDF output profile", source: "Graphics") { p in try p.setArtwork(artwork, for: object.id) }
    return try summary(artwork.outputColorProfile)
  }
  func setOutputColorProfile(_ path: String?, objectID: UUID) {
    finishArtworkEditing()
    do {
      var args: [String: Any] = ["command": path == nil ? "clear" : "set", "object_id": objectID.uuidString]
      if let path { args["profile_path"] = path }
      _ = try colorProfileCall(args); changed()
    } catch { self.error = error.localizedDescription }
  }
  func importOutputColorProfile(objectID: UUID) {
    let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType("com.apple.colorsync-profile") ?? .data]
    panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
    panel.message = "Choose the ICC output profile supplied for your print process. FORM stores a portable copy with this artwork."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    setOutputColorProfile(url.path, objectID: objectID)
  }
  func profiledArtworkPDF(_ data: Data, artwork: Artwork, assets: URL, title: String) throws -> Data {
    guard !artwork.requiresInkOutput else{throw FormError.invalid("This physical artwork carries production ink declarations. Use the explicit production ink PDF export, or choose an RGB preview export; this route does not flatten named inks.")}
    guard let reference = artwork.outputColorProfile else { return data }
    return try ProfiledPDF.convert(data, profile: ICCOutputProfile(reference: reference, assets: assets), title: title)
  }
}
