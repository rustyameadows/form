import Foundation

extension ArtworkElement {
  /// Includes inactive paints: enabling a retained fill must not reveal a missing asset.
  public var paintLayers: [ArtworkPaintLayer] {
    (paintStack ?? []) + (textRuns ?? []).flatMap { $0.paintStack ?? [] }
  }
  public var renderedAssetNames: Set<String> {
    var names=Set(paintLayers.compactMap { $0.paint.asset })
    if let asset { names.insert(asset) }
    return names
  }
}

extension Artwork {
  public var renderedAssetNames: Set<String> {
    elements.reduce(into:Set<String>()) { $0.formUnion($1.renderedAssetNames) }
  }
}

public enum ArtworkPaintValidation {
  public static func validate(_ element:ArtworkElement) throws {
    let stacks=[element.paintStack].compactMap{$0}+(element.textRuns ?? []).compactMap(\.paintStack)
    guard !stacks.isEmpty else{return}
    guard element.kind == "text" || (element.kind == "group" && element.booleanOperation != nil) || ["rectangle","ellipse","polygon","star","path","line"].contains(element.kind),
      (element.textRuns?.count ?? 0)<=8192,stacks.allSatisfy({$0.count<=16}) else {
      throw FormError.invalid("Editable paint stacks support 16 paints on text or vector shapes.")
    }
    var distinct=Set<Data>()
    for stack in stacks {
      distinct.insert(try JSONEncoder.form.encode(stack))
      guard distinct.count<=64 else{throw FormError.invalid("A text layer supports at most 64 distinct paint stacks.")}
    }
    for data in distinct {
      let stack=try JSONDecoder.form.decode([ArtworkPaintLayer].self,from:data)
      for layer in stack {
        if let stroke=layer.stroke,stroke.alignment != nil && stroke.alignment != "center",element.kind != "text",!element.supportsAlignedStroke {
          throw FormError.invalid("Aligned painted strokes require closed vector geometry.")
        }
        let paint=layer.paint
        guard ["solid","gradient","image"].contains(paint.kind),paint.opacity.isFinite,(0...1).contains(paint.opacity),
          AppearanceCommands.blendModes.contains(paint.blendMode ?? "normal") else{throw FormError.invalid("Invalid paint source, opacity or blend mode.")}
        try validateColor(paint.color)
        guard paint.kind == "gradient" || paint.gradient == nil,
          paint.kind == "image" || (paint.asset == nil && paint.imageTransform == nil && paint.imageRepeat == nil && paint.imageAdjustments == nil) else{
          throw FormError.invalid("Paint data does not match its source kind.")
        }
        if paint.kind == "gradient",paint.gradient == nil{throw FormError.invalid("A gradient paint needs its stops and geometry.")}
        if paint.kind == "image" {
          guard let name=paint.asset,!name.isEmpty,!name.contains("/"),!name.contains(".."),name.utf8.count<=500,
            ["png","jpg","jpeg","tif","tiff","gif","bmp","webp","heic","heif"].contains(URL(fileURLWithPath:name).pathExtension.lowercased()) else{
            throw FormError.invalid("An image paint needs a local raster asset.")
          }
        }
        if let t=paint.imageTransform {
          guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy({$0.isFinite && abs($0)<=100000}),t.inverse != nil else{
            throw FormError.invalid("Image paint transforms must be finite and invertible.")
          }
        }
        // Reuse the normal gradient/stroke/image validators without recursive
        // paint stacks, so every import/edit/transfer has the same rules.
        var sample=ArtworkElement(kind:"rectangle",x:0,y:0,width:100,height:100)
        sample.gradient=paint.gradient
        sample.stroke=layer.stroke
        try validateArtworkDetails(.init(elements:[sample]))
        if paint.kind == "image" {
          sample.kind="image";sample.stroke=nil;sample.gradient=nil;sample.asset=paint.asset;sample.imageAdjustments=paint.imageAdjustments
          try ImageCommands.validate(sample)
        }
      }
    }
  }
}
