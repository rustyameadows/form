import Foundation

public enum AffinitiesStudy {
  public static let sourceName = "AFFINITIES / 8 × 10 in"
  public static let alternateName = "AFFINITIES / Outlined alternate"
  public static let assignedFonts = ["Baskerville", "Menlo-Regular", "Skia"]

  public static func make() throws -> Project {
    let original = try JSONSerialization.jsonObject(with: Data(AffinitiesStudyData.json.utf8))
    var mapping: [UUID: UUID] = [:]
    func reidentify(_ value: Any) -> Any {
      func fresh(_ raw: String) -> String {
        guard let id = UUID(uuidString: raw) else { return raw }
        if mapping[id] == nil { mapping[id] = UUID() }
        return mapping[id]!.uuidString
      }
      if let raw = value as? String { return fresh(raw) }
      if let values = value as? [Any] { return values.map(reidentify) }
      if let values = value as? [String: Any] {
        return Dictionary(
          uniqueKeysWithValues: values.map { (fresh($0.key), reidentify($0.value)) })
      }
      return value
    }
    let data = try JSONSerialization.data(withJSONObject: reidentify(original))
    var project = try JSONDecoder.form.decode(Project.self, from: data)
    project.createdAt = Date()
    project.updatedAt = project.createdAt
    project.history = [.init("Created AFFINITIES from the verified native composition study.")]
    project.notes = [
      .init(
        "Begin with the editable 8 × 10 inch original in Canvas. Its display wordmark uses Baskerville with independent ligatures, tracking, leading and manual pair spacing. The folio uses Skia's real variable axes; the small labels use Menlo-Regular."
      ),
      .init(
        "Font assignments are retained exactly. If a face is unavailable on this Mac, the editable preview can use fallback without changing the assignment. Review Document fonts before editing or exporting type. No fonts are bundled with this study.",
        kind: "question"),
      .init(
        "The independent green alternate contains real editable Core Text outlines captured during the verified workflow, with its original text retained as a hidden recoverable layer. These paths remain valid when the original face is unavailable; they are not substitute-font outlines."
      ),
      .init(
        "The oak and graphite editions share the original source at actual size. Edit its wordmark or the masked landscape and both physical faces update. The alternate remains independent. Inspect the circular mask, rotate its group, or select a Bézier node inside it; shared Undo restores those edits."
      ),
      .init(
        "The source frame is exactly 203.2 × 254 mm. Export SVG/PDF at actual size, or PNG at a declared DPI. Material blocks are presentation editions, not a print or cutting job."
      ),
    ]
    project.camera = .init()
    project.camera.azimuth = 0.22
    project.camera.elevation = 0.90
    project.camera.distance = 18
    project.camera.target = .init(0, 0.06, 0)
    project.schemaVersion = project.minimumSchemaVersion
    try project.validateArtworkLinks()
    return project
  }
}
extension Samples {
  public static func affinities() throws -> Project { try AffinitiesStudy.make() }
}
