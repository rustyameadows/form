import AppKit
import FormCore

/// Shared, appearance-preserving vector paints before any ink/material interpretation.
struct PhysicalVectorClip {var path:CGPath,evenOdd:Bool}
struct PhysicalVectorPaint {
  var path:CGPath,evenOdd:Bool,color:String,swatchID:UUID?,clips:[PhysicalVectorClip]
  var elementID:UUID?,title:String?
  func filledRegion() -> CGPath {
    var result=path.normalized(using:evenOdd ? .evenOdd:.winding)
    for clip in clips {result=result.intersection(clip.path.normalized(using:clip.evenOdd ? .evenOdd:.winding))}
    return result
  }
}
struct PhysicalVectorIssue {var message:String,elementID:UUID?,title:String?}

/// One collector supplies print colorants and decoration preparation. It never turns
/// unsupported appearance into a guessed silhouette or mutates editable source.
@MainActor struct PhysicalVectorPlan {
  var paints:[PhysicalVectorPaint]=[]
  var issues:[PhysicalVectorIssue]=[]
  init(artwork:Artwork,width:Double,height:Double,assets:URL,clipToFrame:Bool=false) throws {
    var art=try BooleanGeometry.materialized(artwork).withInheritedLanguage
    art=try ArtworkProduction.filtered(art,roles:[.print]).artwork
    let tree=ArtworkRenderTree(art,assets:assets,production:true,excluding:[])
    var paints:[PhysicalVectorPaint]=[],issues:[PhysicalVectorIssue]=[]
    func issue(_ message:String,_ element:ArtworkElement?=nil) {issues.append(.init(message:message,elementID:element?.id,title:element?.title))}
    func world(_ path:CGPath,_ transform:Affine2)->CGPath {var t=transform.cg;return path.copy(using:&t) ?? path}
    var boundary:[PhysicalVectorClip]=[]
    if clipToFrame {boundary.append(.init(path:CGPath(rect:.init(x:0,y:0,width:width,height:height),transform:nil),evenOdd:false))}
    if let value=art.boundary {
      var element=ArtworkElement(kind:"path",x:0,y:0,width:value.width,height:value.height);element.path=value
      boundary.append(.init(path:VectorGeometry.path(element),evenOdd:value.evenOdd))
    }
    func append(_ path:CGPath,evenOdd:Bool=false,color:String,swatchID:UUID?,clips:[PhysicalVectorClip],element:ArtworkElement?=nil) throws {
      guard !path.isEmpty else{return}
      guard paints.count<100000 else{throw FormError.invalid("Physical vector output supports at most 100,000 paints per page.")}
      paints.append(.init(path:path,evenOdd:evenOdd,color:color,swatchID:swatchID,clips:clips,elementID:element?.id,title:element?.title))
    }
    func active(_ layers:[ArtworkPaintLayer])->[ArtworkPaintLayer] {
      layers.filter{$0.enabled && $0.effectivePaint.opacity>0 && ($0.stroke==nil || ($0.stroke?.enabled != false && ($0.stroke?.width ?? 0)>0))}
    }
    func supported(_ layers:[ArtworkPaintLayer],element:ArtworkElement)->Bool {
      guard layers.allSatisfy({$0.paint.kind=="solid"}) else {
        issue("Image and gradient paint stacks are not supported by this flat physical vector preparation.",element);return false
      }
      guard layers.allSatisfy({$0.effectivePaint.opacity==1 && ($0.paint.blendMode ?? "normal")=="normal"}) else {
        issue("Physical vector paint stacks require opaque, normal-blend solid paints; use explicit ink tints instead of partial opacity.",element);return false
      }
      return true
    }
    let background=art.backgroundOpacity ?? 1
    if background>0 {
      if background != 1 {issue("Partial background opacity is not supported in opaque physical vector output.")}
      else {try append(CGPath(rect:.init(x: -art.bleed,y: -art.bleed,width:width+art.bleed*2,height:height+art.bleed*2),transform:nil),color:art.background,swatchID:art.backgroundSwatchID,clips:boundary)}
    }
    for name in FontCatalog.missing(in:art) {issue("Install or intentionally replace missing font \(name) before outlining physical text.")}
    func visit(_ parent:UUID?,clips:[PhysicalVectorClip]) throws {
      for e in tree.children[parent] ?? [] where tree.visible(e) {
        if e.hasActiveEffects || (e.blendMode ?? "normal") != "normal" || (e.opacity ?? 1) != 1 {
          issue("Physical vector output requires opaque, normal-blend artwork without blur or shadow effects.",e);continue
        }
        var masks=clips
        if let id=e.clipID,let mask=tree.byID[id] {
          guard e.clipMode==nil || e.clipMode=="outline" else{issue("Alpha and luminance masks are not supported by opaque physical vector preparation; use a geometric outline mask.",e);continue}
          guard ["rectangle","ellipse","polygon","star","path"].contains(mask.kind) else{issue("Use geometric vector masks or convert this mask to a path first.",mask);continue}
          masks.append(.init(path:world(VectorGeometry.path(mask),art.worldTransform(mask)),evenOdd:mask.path?.evenOdd==true))
        }
        if e.kind=="group" {try visit(e.id,clips:masks);continue}
        guard e.kind != "image" else{issue("Images are not supported by this vector preparation; they are never replaced with guessed cut silhouettes.",e);continue}
        let transform=art.worldTransform(e)
        if e.kind=="text",TextPaintRenderer.usesPaints(e) {
          // Resolve linked-story paints exactly as the live text renderer does.
          // Filtering each shaped run retains its declared ink/swatch identity.
          var text=e
          if let story=e.storyFrame?.resolved?.story {
            text.paintStack=story.paintStack;text.textRuns=story.textRuns;text.color=story.color;text.fillSwatchID=story.fillSwatchID
          }
          var groups:[[ArtworkPaintLayer]?]=[text.paintStack]
          for span in text.textRuns ?? [] {
            let stack=span.paintStack ?? text.paintStack
            if !groups.contains(where:{$0==stack}) {groups.append(stack)}
          }
          guard groups.compactMap({$0}).allSatisfy({supported(active($0),element:e)}) else{continue}
          if TypographyEngine.overflows(e) {issue("Text is overset or wider than its frame. Add capacity before physical output.",e);continue}
          do {
            for stack in groups {
              let layers=stack.map(active)
              if layers?.isEmpty==true {continue}
              if stack==nil {
                guard text.fillEnabled != false,(text.fillOpacity ?? 1)>0 else{continue}
                guard (text.fillOpacity ?? 1)==1 else{issue("Partial fill opacity is not a solid material or an explicit ink tint.",e);continue}
              }
              let runs=try TypographyEngine.outlinePaintRuns(text,matchingPaintStack:stack,filtering:true)
              if let layers {
                for layer in layers {for run in runs {
                  guard !run.path.isEmpty else{continue}
                  let path:CGPath
                  if let stroke=layer.stroke {
                    var shape=try VectorGeometry.element(from:run.path,color:layer.paint.color);shape.stroke=stroke
                    path=world(try StrokeGeometry.path(shape),shape.localTransform)
                  }else{path=run.path}
                  let swatchID=layer.stroke==nil ? run.swatchID:layer.stroke?.swatchID
                  try append(world(path,transform),color:layer.paint.color,swatchID:swatchID,clips:masks,element:e)
                }}
              }else{
                for run in runs {try append(world(run.path,transform),color:run.color,swatchID:run.swatchID,clips:masks,element:e)}
              }
            }
          }catch{issue(error.localizedDescription,e)}
          continue
        }
        if let stack=e.paintStack {
          // A present stack completely owns vector appearance, including an
          // empty stack. Legacy fill, gradient and stroke are dormant metadata.
          let layers=active(stack)
          guard supported(layers,element:e) else{continue}
          guard ["rectangle","ellipse","line","polygon","star","path"].contains(e.kind) else{issue("Convert this artwork to supported vector paths before physical output.",e);continue}
          for layer in layers {
            do {
              if let stroke=layer.stroke {
                var shape=e;shape.paintStack=nil;shape.stroke=stroke
                try append(world(try StrokeGeometry.path(shape),transform),color:layer.paint.color,swatchID:stroke.swatchID,clips:masks,element:e)
              }else if e.kind != "line" {
                try append(world(VectorGeometry.path(e),transform),evenOdd:e.path?.evenOdd==true,color:layer.paint.color,swatchID:e.fillSwatchID,clips:masks,element:e)
              }
            }catch{issue(error.localizedDescription,e)}
          }
          continue
        }
        if e.gradient != nil,e.fillEnabled != false,(e.fillOpacity ?? 1)>0 {issue("Gradient paints are not supported by this flat vector preparation.",e);continue}
        let fill=e.fillOpacity ?? 1
        if fill>0,fill != 1,e.fillEnabled != false {issue("Partial fill opacity is not a solid material or an explicit ink tint.",e);continue}
        if e.kind=="text" {
          guard e.fillEnabled != false,fill>0 else{continue}
          if TypographyEngine.overflows(e) {issue("Text is overset or wider than its frame. Add capacity before physical output.",e);continue}
          do {
            if let context=e.storyFrame?.resolved {try GlyphEngine.validateOutput(context.story.sourceElement.inheritingLanguage(context.language),outlines:true)}
            else {try GlyphEngine.validateOutput(e,outlines:true)}
            for run in try TypographyEngine.outlinePaintRuns(e) {try append(world(run.path,transform),color:run.color,swatchID:run.swatchID,clips:masks,element:e)}
          }catch{issue(error.localizedDescription,e)}
          continue
        }
        guard ["rectangle","ellipse","line","polygon","star","path"].contains(e.kind) else{issue("Convert this artwork to supported vector paths before physical output.",e);continue}
        if e.fillEnabled != false,e.kind != "line",fill>0 {try append(world(VectorGeometry.path(e),transform),evenOdd:e.path?.evenOdd==true,color:e.color,swatchID:e.fillSwatchID,clips:masks,element:e)}
        if let stroke=e.visibleStroke {
          guard (stroke.opacity ?? 1)==1 else{issue("Partial stroke opacity is not supported; use a solid paint or explicit ink tint.",e);continue}
          do {try append(world(StrokeGeometry.path(e),transform),color:stroke.color,swatchID:stroke.swatchID,clips:masks,element:e)}
          catch {issue(error.localizedDescription,e)}
        }
      }
    }
    try visit(nil,clips:boundary);self.paints=paints;self.issues=issues
  }
}
