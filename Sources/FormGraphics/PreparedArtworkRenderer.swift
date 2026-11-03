import AppKit
import FormCore

extension ArtworkRenderer {
  private static var preparedFontGeneration = 0
  public static var displayFontGeneration: Int { preparedFontGeneration }
  static func invalidatePreparedFonts() { preparedFontGeneration &+= 1 }

  /// An immutable editable-artwork snapshot with reusable vector geometry and
  /// hierarchy indexes. No raster preview is substituted for document content.
  @MainActor public final class Prepared {
    private let source: Artwork
    private let assets: URL
    private let production: Bool
    private let excluding: Set<UUID>
    private var generation: Int
    private var artwork: Artwork
    private var tree: ArtworkRenderTree
    public private(set) var preparations = 1

    public init(_ source: Artwork, assets: URL, production: Bool = false,
      excluding: Set<UUID> = []) throws {
      self.source = source; self.assets = assets; self.production = production; self.excluding = excluding
      generation = ArtworkRenderer.preparedFontGeneration
      artwork = try BooleanGeometry.materialized(source).withInheritedLanguage
      tree = ArtworkRenderTree(artwork, assets: assets, production: production, excluding: excluding, cullsToClip: true)
    }
    public var diagnostics: [String: Int] {
      ["preparations": preparations, "vector_paths": tree.vectorPathBuilds,
       "bounds": tree.boundsBuilds, "drawn_elements": tree.drawnElements, "culled_elements": tree.culledElements]
    }
    public func draw(width: Double, height: Double, effectScale: Double? = nil, unbounded: Bool = false) {
      guard let context = NSGraphicsContext.current?.cgContext else { return }
      if generation != ArtworkRenderer.preparedFontGeneration {
        guard let current = try? BooleanGeometry.materialized(source).withInheritedLanguage else { return }
        artwork = current
        tree = ArtworkRenderTree(current, assets: assets, production: production, excluding: excluding, cullsToClip: true)
        generation = ArtworkRenderer.preparedFontGeneration; preparations += 1
      }
      tree.resetDrawMetrics()
      ArtworkRenderer.drawPrepared(artwork, tree: tree, width: width, height: height,
        context: context, effectScale: effectScale, unbounded: unbounded)
    }
  }
}
