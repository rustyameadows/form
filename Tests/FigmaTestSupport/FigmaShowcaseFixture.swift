import Foundation

extension FigmaWireFixture {
  /// A deliberately authored composition, not a real Figma file or a screenshot.
  /// All paths, textile pixels and type are generated from independent source
  /// values, then travel through the ordinary HTML/Kiwi clipboard envelope.
  public static func showcaseHTML() -> String {
    var nodes = [node(id: 1, parent: nil, type: "DOCUMENT", name: "Synthetic field studies"),
      node(id: 2, parent: 1, type: "CANVAS", name: "Systems in motion")]
    var blobs: [Data] = [], next: UInt32 = 10
    let ink: [Float] = [0.055,0.12,0.20], paper: [Float] = [0.96,0.95,0.91]
    let orange: [Float] = [0.91,0.30,0.17], blue: [Float] = [0.20,0.43,0.67]
    func color(_ rgb: [Float]) -> FigmaWireValue {
      .object(["r":.float(rgb[0]),"g":.float(rgb[1]),"b":.float(rgb[2]),"a":.float(1)])
    }
    func paint(_ rgb: [Float], opacity: Float = 1) -> FigmaWireValue {
      .object(["type":.string("SOLID"),"color":color(rgb),"opacity":.float(opacity),"visible":.bool(true)])
    }
    func matrix(_ a: Float = 1, _ d: Float = 1, _ x: Float = 0, _ y: Float = 0) -> FigmaWireValue {
      .object(["m00":.float(a),"m01":.float(0),"m02":.float(x),"m10":.float(0),"m11":.float(d),"m12":.float(y)])
    }
    func gradient(_ first: [Float], _ last: [Float], radial: Bool = false) -> FigmaWireValue {
      .object(["type":.string(radial ? "GRADIENT_RADIAL":"GRADIENT_LINEAR"),"transform":matrix(),
        "stops":.array([.object(["position":.float(0),"color":color(first)]),.object(["position":.float(1),"color":color(last)])])])
    }
    @discardableResult func add(_ kind: String, _ name: String, _ parent: UInt32, _ x: Float, _ y: Float, _ w: Float, _ h: Float,
      fields: [String:FigmaWireValue] = [:]) -> UInt32 {
      let id = next; next += 1
      var value = node(id: id, parent: parent, type: kind, name: name, x: x, y: y, width: w, height: h)
      value.merge(fields) { _, new in new }; nodes.append(value); return id
    }
    @discardableResult func frame(_ name: String, _ parent: UInt32, _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ rgb: [Float], clip: Bool = true) -> UInt32 {
      add("FRAME",name,parent,x,y,w,h,fields:["fillPaints":.array([paint(rgb)]),"cornerRadius":.float(22),"frameMaskDisabled":.bool(!clip)])
    }
    func group(_ name: String, _ parent: UInt32, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> UInt32 {
      add("FRAME",name,parent,x,y,w,h,fields:["resizeToFit":.bool(true),"frameMaskDisabled":.bool(true)])
    }
    @discardableResult func text(_ words: String, _ parent: UInt32, _ x: Float, _ y: Float, _ w: Float, _ h: Float, _ size: Float,
      _ rgb: [Float] = [0.055,0.12,0.20], bold: Bool = false, name: String? = nil) -> UInt32 {
      add("TEXT",name ?? words,parent,x,y,w,h,fields:["fontName":.object(["family":.string("Helvetica"),"style":.string(bold ? "Bold":"Regular"),
        "postscript":.string(bold ? "Helvetica-Bold":"Helvetica")]),"fontSize":.float(size),"lineHeight":.object(["value":.float(1.15),"units":.string("RAW")]),
        "textAutoResize":.string("NONE"),"textData":.object(["characters":.string(words)]),"fillPaints":.array([paint(rgb)])])
    }
    let board = frame("Systems in motion / editorial board",2,0,0,1600,1600,paper,clip:false)
    text("FORM  /  FIELD STUDIES  /  2026",board,64,38,800,24,15,bold:true)
    text("Systems in motion.",board,56,87,1490,130,106,bold:true)
    text("A visual atlas of contour, chroma and character.",board,64,211,920,32,23)
    text("EDITION 01\nDESIGNED TO BE EDITED",board,1256,201,280,48,13,bold:true)

    let contourPanel = frame("01 / Contour cartography",board,64,286,720,680,[0.88,0.90,0.88])
    text("01   CONTOUR CARTOGRAPHY",contourPanel,30,24,500,24,15,bold:true)
    text("260 curves. Every anchor remains editable.",contourPanel,30,52,600,24,16)
    let contourGroup = group("Contour field / nested paths",contourPanel,22,76,676,560)
    for index in 0..<260 {
      let t = Double(index) / 259, radius = 18 + 252 * t
      let cx = 338 + sin(t * 4) * 24, cy = 278 + cos(t * 5) * 18
      var bytes = Data()
      func command(_ code: UInt8, _ numbers: Double...) {
        bytes.append(code)
        for number in numbers { let bits = Float(number).bitPattern; bytes.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0*8)) }) }
      }
      command(1,cx+radius,cy)
      command(4,cx+radius,cy+radius*0.58,cx+radius*0.46,cy+radius*0.91,cx-radius*0.18,cy+radius*0.83)
      command(4,cx-radius*0.90,cy+radius*0.78,cx-radius*1.07,cy+radius*0.26,cx-radius*0.91,cy-radius*0.22)
      command(4,cx-radius*0.76,cy-radius*0.89,cx-radius*0.02,cy-radius*1.01,cx+radius*0.52,cy-radius*0.75)
      command(4,cx+radius*0.90,cy-radius*0.54,cx+radius,cy-radius*0.25,cx+radius,cy); command(0)
      let blob = UInt32(blobs.count); blobs.append(bytes)
      let shade: [Float] = index % 11 < 3 ? orange : [Float(0.10+t*0.13),Float(0.21+t*0.14),Float(0.30+t*0.10)]
      add("VECTOR","Contour \(index)",contourGroup,0,0,676,560,fields:["fillGeometry":.array([.object(["windingRule":.string("NONZERO"),"commandsBlob":.uint(blob)])]),
        "fillPaints":.array([]),"strokePaints":.array([paint(shade,opacity:0.72)]),"strokeWeight":.float(index % 17 == 0 ? 1.3:0.65)])
    }
    let annotation = group("Contour annotations",contourPanel,0,0,720,680)
    for index in 0..<12 {
      let x = Float(38 + index * 56)
      add("RECTANGLE","Ruler tick \(index)",annotation,x,637,1,10,fields:["fillPaints":.array([paint(ink)])])
      text(String(format:"%02d",index*5),annotation,x-6,650,32,18,10)
    }

    let chroma = frame("02 / Chromatic archive",board,816,286,720,328,[0.79,0.82,0.85])
    let imageIndex = UInt32(blobs.count); blobs.append(showcaseTextilePNG())
    add("RECTANGLE","Cropped woven field",chroma,0,0,720,328,fields:["fillPaints":.array([.object([
      "type":.string("IMAGE"),"image":.object(["dataBlob":.uint(imageIndex)]),"imageScaleMode":.string("STRETCH"),
      "transform":matrix(0.75,0.58,0.12,0.18)])])])
    let speckles = group("Overlapping chroma samples",chroma,20,50,680,260)
    for index in 0..<180 {
      let angle = Double(index) * 2.399963, radius = sqrt(Double(index)) * 12
      let x = Float(340 + cos(angle)*radius*1.8), y = Float(125 + sin(angle)*radius*0.75)
      let size = Float(6 + index % 13)
      add("ELLIPSE","Chroma sample \(index)",speckles,x,y,size,size,fields:["fillPaints":.array([paint(index % 3 == 0 ? orange:paper,opacity:0.52)])])
    }
    add("RECTANGLE","Archive title plate",chroma,20,18,330,39,fields:["cornerRadius":.float(10),"fillPaints":.array([paint(paper,opacity:0.94)])])
    text("02   CHROMATIC ARCHIVE",chroma,34,29,320,24,14,bold:true)
    text("Embedded pixels · native crop · 180 overlays",chroma,30,294,650,22,14,paper)

    let typePanel = frame("03 / Character laboratory",board,816,642,720,324,[0.90,0.87,0.80])
    text("03   CHARACTER LABORATORY",typePanel,30,22,580,24,14,bold:true)
    text("Aa",typePanel,22,44,306,244,224,ink,bold:true)
    text("Form follows\nfeeling.",typePanel,332,68,360,116,46,ink,bold:true)
    var specimen = sampleText(id:next,parent:typePanel,name:"Rich Unicode specimen",x:338,y:199); next += 1
    specimen["size"] = .object(["x":.float(330),"y":.float(82)]); nodes.append(specimen)
    let texture = group("Typographic optical texture",typePanel,0,0,720,324)
    for index in 0..<100 {
      let x = Float(20 + index * 7), h = Float(index % 5 == 0 ? 15:6)
      add("RECTANGLE","Baseline marker \(index)",texture,x,305-h,1,h,fields:["fillPaints":.array([paint(ink,opacity:0.4)])])
    }

    let spectrum = frame("04 / Spectral index",board,64,994,1472,124,ink)
    text("04   SPECTRAL INDEX",spectrum,24,17,500,25,14,paper,bold:true)
    text("256 individually editable swatches",spectrum,1110,17,350,25,13,paper)
    for index in 0..<256 {
      let phase = Double(index) / 255 * 2 * Double.pi
      let rgb: [Float] = (0..<3).map { Float(0.54 + 0.35 * sin(phase + Double($0)*2.1)) }
      add("RECTANGLE","Spectral swatch \(index)",spectrum,24+Float(index)*5.56,56,4.8,44,fields:["fillPaints":.array([paint(rgb)])])
    }
    // Two explicit gradient lenses overlap the contour field, and a sibling
    // outline mask clips their nested motif group.
    let lens = group("Overlapping gradient lenses",contourPanel,470,112,200,200)
    add("ELLIPSE","Lens boundary",lens,0,0,170,170,fields:["mask":.bool(true),"maskType":.string("OUTLINE"),"fillPaints":.array([paint(paper)])])
    add("RECTANGLE","Linear lens",lens,-20,-20,210,210,fields:["fillPaints":.array([gradient([0.96,0.75,0.35],[0.88,0.35,0.24])])])
    add("ELLIPSE","Radial lens",lens,50,45,150,150,fields:["opacity":.float(0.75),"fillPaints":.array([gradient([0.97,0.93,0.77],blue,radial:true)])])
    let threads = group("Lens nested threads",lens,0,0,170,170)
    for index in 0..<60 {
      add("RECTANGLE","Lens thread \(index)",threads,Float(index)*3-5,0,0.8,180,fields:["fillPaints":.array([paint(ink,opacity:0.23)])])
    }

    // The appearance panel exercises native stacks and a genuinely editable
    // group mask amid dense overlapping content, using the same clipboard route.
    func advanced(_ kind:String)->FigmaWireValue {
      .object(["type":.string(kind),"transform":matrix(),"stops":.array([
        .object(["position":.float(0),"color":color(orange)]),
        .object(["position":.float(0.45),"color":color(paper)]),
        .object(["position":.float(1),"color":color(blue)])])])
    }
    func shadow(_ kind:String,_ dx:Float,_ dy:Float,_ radius:Float,_ rgb:[Float])->FigmaWireValue {
      .object(["type":.string(kind),"offset":.object(["x":.float(dx),"y":.float(dy)]),"radius":.float(radius),
        "color":color(rgb),"visible":.bool(true),"blendMode":.string("MULTIPLY"),"showShadowBehindNode":.bool(false)])
    }
    let appearance=frame("05 / Editable appearance laboratory",board,64,1200,1472,336,[0.84,0.86,0.83])
    text("05   EDITABLE APPEARANCE",appearance,24,20,600,26,15,bold:true)
    text("LIVE PAINT STACK",appearance,24,67,420,20,12,bold:true)
    add("TEXT","Live stacked gradient headline",appearance,20,93,420,140,fields:[
      "fontName":.object(["family":.string("Helvetica"),"style":.string("Bold"),"postscript":.string("Helvetica-Bold")]),
      "fontSize":.float(92),"textData":.object(["characters":.string("INK / 05")]),
      "fillPaints":.array([advanced("GRADIENT_ANGULAR")]),"strokePaints":.array([paint(ink)]),"strokeWeight":.float(1.5),
      "effects":.array([shadow("DROP_SHADOW",4,7,5,blue),shadow("INNER_SHADOW",1,2,2,ink)])])
    text("Native words · angular ink · ordered shadows",appearance,24,265,430,42,15)
    let maskArea=group("Editable alpha-mask study",appearance,494,72,420,220)
    let groupMask=add("FRAME","Editable overlapping group mask",maskArea,0,0,420,220,fields:["mask":.bool(true),"maskType":.string("ALPHA"),
      "resizeToFit":.bool(true),"frameMaskDisabled":.bool(true),"opacity":.float(0.65)])
    add("ELLIPSE","Mask circular ink",groupMask,70,0,220,220,fields:["fillPaints":.array([paint(paper)])])
    add("RECTANGLE","Mask horizontal ink",groupMask,0,75,420,70,fields:["fillPaints":.array([paint(paper)])])
    add("RECTANGLE","Masked diamond field",maskArea,0,0,420,220,fields:["fillPaints":.array([advanced("GRADIENT_DIAMOND")])])
    let bars=group("Masked editable thread group",maskArea,0,0,420,220)
    for index in 0..<48 {
      add("RECTANGLE","Alpha-mask thread \(index)",bars,Float(index)*9,0,2,220,fields:["fillPaints":.array([paint(ink,opacity:0.6)])])
    }
    text("GROUP MASK / combined coverage",appearance,494,301,440,22,13,bold:true)
    let discs=group("Diamond discs / editable shadows",appearance,984,72,450,220)
    for index in 0..<8 {
      add("ELLIPSE","Diamond disc \(index)",discs,Float(index%4)*94,Float(index/4)*104,88,88,fields:[
        "fillPaints":.array([advanced(index%2 == 0 ? "GRADIENT_DIAMOND":"GRADIENT_ANGULAR")]),
        "blendMode":.string("NORMAL"),"effects":.array([shadow("DROP_SHADOW",3,5,5,blue),shadow("INNER_SHADOW",2,3,3,ink)])])
    }
    text("EDITABLE INK / effects / blend",appearance,984,301,430,22,13,bold:true)

    // One hidden source definition, repeated as linked editable instances.
    let definitionID: UInt32 = 60000
    var definition = node(id:definitionID,parent:1,type:"SYMBOL",name:"Study badge / component",width:110,height:26)
    definition["internalOnly"] = .bool(true); definition["frameMaskDisabled"] = .bool(true)
    definition["cornerRadius"] = .float(13); definition["fillPaints"] = .array([gradient([0.89,0.87,0.81],[0.82,0.84,0.81])])
    nodes.append(definition)
    var dot = node(id:60001,parent:definitionID,type:"ELLIPSE",name:"Badge indicator",x:9,y:8,width:10,height:10)
    dot["fillPaints"] = .array([paint(orange)]); nodes.append(dot)
    var badgeText = node(id:60002,parent:definitionID,type:"TEXT",name:"Badge text",x:27,y:6,width:76,height:18)
    badgeText["fontName"] = .object(["family":.string("Helvetica"),"style":.string("Bold"),"postscript":.string("Helvetica-Bold")])
    badgeText["fontSize"] = .float(10); badgeText["textData"] = .object(["characters":.string("FIELD / 01")])
    badgeText["fillPaints"] = .array([paint(ink)]); nodes.append(badgeText)
    for index in 0..<12 {
      add("INSTANCE","Linked study badge \(index)",board,64+Float(index)*123,1138,110,26,fields:["symbolData":.object(["symbolID":guid(definitionID)])])
    }
    return html(nodes:nodes,blobs:blobs)
  }

  /// Standards-compliant RGB PNG with independently assembled zlib stored
  /// blocks. Pixels are an original deterministic weave, not downloaded art.
  private static func showcaseTextilePNG() -> Data {
    let width = 128, height = 96
    var scanlines = Data()
    let palette: [[UInt8]] = [[25,54,74],[78,119,135],[190,143,103],[224,199,151]]
    for y in 0..<height {
      scanlines.append(0)
      for x in 0..<width {
        let band = ((x/9)+(y/13)) % 4, shade = ((x+y)%3 == 0) ? 12:0
        scanlines.append(contentsOf:palette[band].map { UInt8(min(255,Int($0)+shade)) })
      }
    }
    func be(_ n: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded:n >> ((3-$0)*8)) }) }
    func chunk(_ name: String, _ value: Data) -> Data {
      let content = Data(name.utf8)+value
      var crc: UInt32 = 0xffffffff
      for byte in content { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0:0xedb88320) } }
      return be(UInt32(value.count))+content+be(~crc)
    }
    let count = UInt16(scanlines.count)
    var zlib = Data([0x78,0x01,1,UInt8(truncatingIfNeeded:count),UInt8(count>>8),UInt8(truncatingIfNeeded:~count),UInt8((~count)>>8)])+scanlines
    var a: UInt32 = 1, b: UInt32 = 0
    for byte in scanlines { a=(a+UInt32(byte))%65521; b=(b+a)%65521 }
    zlib += be(b << 16 | a)
    let header = be(UInt32(width))+be(UInt32(height))+Data([8,2,0,0,0])
    return Data([137,80,78,71,13,10,26,10])+chunk("IHDR",header)+chunk("IDAT",zlib)+chunk("IEND",Data())
  }
}
