import AppKit
import FormCore
import FormGraphics
import SwiftUI

extension ArtworkSession {
  func editImage(crop: Any? = nil, adjustments: Any? = nil, reset: Bool = false) {
    guard let store, let objectID, !selection.isEmpty else { return }
    NotificationCenter.default.post(name: .formCommitArtworkFields, object: nil)
    canvas?.finishText()
    var args: [String: Any] = ["object_id": objectID.uuidString,
      "element_ids": selection.map(\.uuidString), "command": reset ? "reset" : "update"]
    args["crop"] = crop; args["adjustments"] = adjustments
    do { _ = try store.engine.call("form_edit_image",arguments: args,source: "Studio"); store.changed() }
    catch { store.error = error.localizedDescription }
  }
  func cropImage(_ crop: ImageCrop) {
    editImage(crop: ["x":crop.x,"y":crop.y,"width":crop.width,"height":crop.height])
  }
  @discardableResult func placeImages(_ urls: [URL], point: Point2? = nil, replacing: Bool = false) -> Bool {
    guard let store, let objectID else { return false }
    canvas?.finishText()
    do {
      for (offset,url) in urls.enumerated() {
        var args: [String: Any] = ["path":url.path,"object_id":objectID.uuidString]
        if replacing { guard let e = primary, e.kind == "image" else { return false }; args["element_id"] = e.id.uuidString }
        else {
          if let scopeID { args["parent_id"] = scopeID.uuidString }
          if let point { args["x"] = point.x + Double(offset)*5; args["y"] = point.y + Double(offset)*5; args["anchor"] = "center" }
          if let projection = activeProjection, !projection.isProof, scopeID == nil {
            let info = try? ImageRenderer.info(url)
            let aspect = info?.aspect ?? 1
            args["width"] = min(projection.size.x * 0.7, projection.size.y * 0.7 * aspect)
            if point == nil {
              args["x"] = projection.size.x / 2; args["y"] = projection.size.y / 2
              args["anchor"] = "center"
            }
          }
        }
        let projection = activeProjection
        let result = try store.importImage(args,source: "Studio", placement: { element in
          if element.parentID == nil, let projection, !projection.isProof,
            let inverse = projection.sourceToLocal.inverse {
            element.affine = inverse.followed(by: element.affine ?? .init())
          }
        })
        selection = Set((result["selected_elements"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
      }
      store.changed()
      return !urls.isEmpty
    } catch { store.error = error.localizedDescription; return false }
  }
}

struct ImageInspector: View {
  @ObservedObject var session: ArtworkSession
  let element: ArtworkElement
  private var info: ImageAssetInfo? {
    guard let name = element.asset else { return nil }
    return try? ImageRenderer.info(session.assets.appendingPathComponent(name))
  }
  private var crop: ImageCrop { element.imageCrop ?? .full }
  private var adjustments: ImageAdjustments { element.imageAdjustments ?? .init() }
  private var dpi: Double? {
    guard let info else { return nil }
    if let p = session.store?.project, let target = session.previewObject,
      let surface = p.surfaceArtwork(target), let e = surface.elements.first(where: { $0.id == element.id }) {
      return info.effectiveDPI(e,transform: surface.worldTransform(e))
    }
    return info.effectiveDPI(element,transform: session.art.worldTransform(element))
  }
  var body: some View {
    VStack(alignment: .leading,spacing: 10) {
      SectionLabel("IMAGE")
      if let name = element.asset,
        let thumbnail = try? ImageRenderer.bitmap(session.assets.appendingPathComponent(name),requestedEdge:128) {
        HStack(spacing:8) {
          Image(nsImage:NSImage(cgImage:thumbnail,size:.init(width:thumbnail.width,height:thumbnail.height)))
            .resizable().aspectRatio(contentMode:.fit).frame(width:60,height:44)
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius:4))
            .onDrag { session.imageDragStarts += 1; return NSItemProvider(object:session.assets.appendingPathComponent(name) as NSURL) }
            .accessibilityLabel("Original image · drag to place a copy")
          Text("Drag the original onto a frame to place another copy.")
            .font(.system(size:9)).foregroundStyle(Palette.secondary)
        }
      }
      if let info {
        Text("\(info.width) × \(info.height) px · \(info.frames > 1 ? "First of \(info.frames) frames" : "Original preserved")")
          .font(.system(size:9)).foregroundStyle(Palette.secondary)
        if let dpi {
          Text("\(Int(dpi.rounded())) effective DPI")
            .font(.system(size:10,weight:.medium)).monospacedDigit()
          if dpi < 300 {
            Label(dpi < 150 ? "Low resolution at this size" : "Below 300 DPI for fine print", systemImage:"exclamationmark.triangle")
              .font(.system(size:9)).foregroundStyle(dpi < 150 ? Palette.accent : Palette.secondary)
          }
        }
      } else {
        Text("Vector reference · no fixed pixel DPI").font(.system(size:9)).foregroundStyle(Palette.secondary)
      }
      HStack {
        Button(session.croppingImageID == element.id ? "Done cropping" : "Crop image") {
          session.croppingImageID = session.croppingImageID == element.id ? nil : element.id
          session.canvas?.window?.makeFirstResponder(session.canvas)
          session.canvas?.needsDisplay = true
        }
        Button("Replace…") { session.importImage(replacing: true) }
      }.font(.system(size:10))
      if session.croppingImageID == element.id {
        HStack {
          Button { session.cropImage(crop.zoomed(1.15)) } label: { Image(systemName:"minus.magnifyingglass") }.help("Crop zoom out").accessibilityLabel("Crop zoom out")
          Button { session.cropImage(crop.zoomed(1/1.15)) } label: { Image(systemName:"plus.magnifyingglass") }.help("Crop zoom in").accessibilityLabel("Crop zoom in")
        }
        Text("Drag the image to reposition. Scroll to zoom inside its frame. Return or Escape finishes.")
          .font(.system(size:9)).foregroundStyle(Palette.secondary)
      }
      HStack {
        Button("Fill frame") {
          if let info { session.cropImage(.filling(pixelWidth:Double(info.width),pixelHeight:Double(info.height),width:element.width,height:element.height)) }
        }.disabled(info == nil)
        Button("Fit frame to image") {
          if let info { session.update { e in e.height = e.width / info.aspect; e.imageCrop = nil } }
        }.disabled(info == nil)
      }.font(.system(size:9))
      DisclosureGroup("Crop bounds") {
        VStack(spacing:8) {
          HStack {
            ScalarArtworkField("Crop X",value:crop.x*100,unit:"%") { session.editImage(crop:["x":$0/100]) }
            ScalarArtworkField("Crop Y",value:crop.y*100,unit:"%") { session.editImage(crop:["y":$0/100]) }
          }
          HStack {
            ScalarArtworkField("Crop width",value:crop.width*100,unit:"%") { session.editImage(crop:["width":$0/100]) }
            ScalarArtworkField("Crop height",value:crop.height*100,unit:"%") { session.editImage(crop:["height":$0/100]) }
          }
          Button("Show full original") { session.editImage(crop:NSNull()) }.font(.system(size:9))
        }.padding(.top,8)
      }.font(.system(size:10))
      if info != nil {
        DisclosureGroup("Image adjustments") {
          VStack(spacing:10) {
            adjustment("Brightness",value:adjustments.brightness,range:-1...1,key:"brightness")
            adjustment("Contrast",value:adjustments.contrast,range:0...4,key:"contrast")
            adjustment("Saturation",value:adjustments.saturation,range:0...2,key:"saturation")
            Button("Reset adjustments") { session.editImage(adjustments:NSNull()) }.font(.system(size:9))
          }.padding(.top,8)
        }.font(.system(size:10))
      }
    }
  }
  private func adjustment(_ title:String,value:Double,range:ClosedRange<Double>,key:String) -> some View {
    VStack(spacing:4) {
      ScalarArtworkField(title,value:value*100,unit:"%") { session.editImage(adjustments:[key:$0/100]) }
      Slider(value:Binding(get:{value},set:{session.editImage(adjustments:[key:$0])}),in:range)
        .accessibilityLabel(title)
    }
  }
}
