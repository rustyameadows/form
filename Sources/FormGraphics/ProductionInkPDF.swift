import AppKit
import FormCore

private final class InkPDFObjects {
  var objects:[Data]=[]
  func reserve()->Int {objects.append(Data());return objects.count}
  func set(_ id:Int,_ text:String) {objects[id-1]=Data(text.utf8)}
  func add(_ text:String)->Int {let id=reserve();set(id,text);return id}
  func stream(_ data:Data,entries:String="")->Int {
    let id=reserve();var value=Data("<< /Length \(data.count) \(entries) >>\nstream\n".utf8);value.append(data);value.append(Data("\nendstream".utf8));objects[id-1]=value;return id
  }
  func document(root:Int,info:Int) throws -> Data {
    var data=Data("%PDF-1.7\n%âãÏÓ\n".utf8),offsets:[Int]=[0]
    for (index,object) in objects.enumerated() {
      guard data.count+object.count<=512000000 else{throw FormError.invalid("Production PDF exceeds the 512MB output bound.")}
      offsets.append(data.count);data.append(Data("\(index+1) 0 obj\n".utf8));data.append(object);data.append(Data("\nendobj\n".utf8))
    }
    let xref=data.count;data.append(Data("xref\n0 \(offsets.count)\n0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() {data.append(Data(String(format:"%010d 00000 n \n",offset).utf8))}
    data.append(Data("trailer\n<< /Size \(offsets.count) /Root \(root) 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8));return data
  }
}

/// A bounded opaque vector writer. It does not flatten transparency into spot ink.
@MainActor public enum ProductionInkPDF {
  public static func preflight(project:Project,pages:[InkPrintPage],assets:URL)->[String:Any] {ProductionInkPlan(project:project,pages:pages,assets:assets).report}
  public static func export(project:Project,pages:[InkPrintPage],assets:URL,mode:InkOutputMode,title:String="FORM production inks") throws -> (data:Data,report:[String:Any]) {
    guard mode == .composite || mode == .plates else{throw FormError.invalid("Choose composite or plates for production ink PDF data.")}
    let plan=ProductionInkPlan(project:project,pages:pages,assets:assets)
    guard plan.canExport,let profile=plan.profile else{
      throw FormError.invalid(plan.issues.filter{$0["severity"] as? String=="error"}.compactMap{$0["message"] as? String}.joined(separator:"\n"))
    }
    let count=mode == .plates ? plan.pages.count*plan.colorants.count:plan.pages.count
    guard count<=1000 else{throw FormError.invalid("Production ink output supports at most 1,000 physical PDF pages. Export a smaller page/ink set.")}
    let pdf=InkPDFObjects(),catalog=pdf.reserve(),pageTree=pdf.reserve()
    let icc=pdf.stream(profile.data,entries:"/N 4 /Alternate /DeviceCMYK")
    var spaces="/Process [/ICCBased \(icc) 0 R]",aliases:[String:String]=[:]
    for (index,name) in plan.spots.keys.sorted().enumerated() {
      let ink=plan.spots[name]!,function=pdf.add("<< /FunctionType 2 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] /C0 [0 0 0 0] /C1 [\(ink.components.values.map(number).joined(separator:" "))] /N 1 >>")
      let alias="Ink\(index)";aliases[name]=alias
      spaces+=" /\(alias) [/Separation /\(pdfName(name)) [/ICCBased \(icc) 0 R] \(function) 0 R]"
    }
    var pageIDs:[Int]=[],labels:[String]=[],segmentCount=0
    for page in plan.pages {
      let variants:[Int?]=mode == .plates ? plan.colorants.indices.map{Optional($0)}:[nil]
      for channel in variants {
        let source=page.source,bleed=source.artwork.bleed,factor=TypographyEngine.pointsPerMM
        var commands=["q \(number(factor)) 0 0 \(number(-factor)) \(number(bleed*factor)) \(number((source.height+bleed)*factor)) cm /KO gs"]
        for primitive in page.primitives {
          commands.append("q")
          for clip in primitive.clips {commands.append(try path(clip.path,count:&segmentCount));commands.append(clip.evenOdd ? "W* n":"W n")}
          if let channel {
            let coverage:Double
            switch primitive.paint {
            case .process(let components):coverage=channel<4 ? components[channel]:0
            case .spot(let ink):coverage=channel>=4 && plan.colorants[channel]==ink.spotName ? ink.tint:0
            }
            commands.append("\(number(1-coverage)) g")
          } else {
            switch primitive.paint {
            case .process(let components):commands.append("/Process cs \(components.map(number).joined(separator:" ")) scn")
            case .spot(let ink):commands.append("/\(aliases[ink.spotName!]!) cs \(number(ink.tint)) scn")
            }
          }
          commands.append(try path(primitive.path,count:&segmentCount));commands.append(primitive.evenOdd ? "f*":"f");commands.append("Q")
        }
        commands.append("Q")
        let contents=pdf.stream(Data(commands.joined(separator:"\n").utf8))
        let media="[0 0 \(number((source.width+2*bleed)*factor)) \(number((source.height+2*bleed)*factor))]"
        let trim="[\(number(bleed*factor)) \(number(bleed*factor)) \(number((source.width+bleed)*factor)) \(number((source.height+bleed)*factor))]"
        let pageID=pdf.add("<< /Type /Page /Parent \(pageTree) 0 R /MediaBox \(media) /CropBox \(media) /TrimBox \(trim) /BleedBox \(media) /Resources << /ColorSpace << \(spaces) >> /ExtGState << /KO << /Type /ExtGState /OP false /op false /OPM 0 >> >> >> /Contents \(contents) 0 R >>")
        pageIDs.append(pageID);labels.append(source.name+(channel.map{" / "+plan.colorants[$0]} ?? " / Composite"))
      }
    }
    pdf.set(pageTree,"<< /Type /Pages /Count \(pageIDs.count) /Kids [\(pageIDs.map{"\($0) 0 R"}.joined(separator:" "))] >>")
    let pageLabels=labels.enumerated().map{"\($0.offset) << /P \(pdfString($0.element)) >>"}.joined(separator:" ")
    pdf.set(catalog,"<< /Type /Catalog /Pages \(pageTree) 0 R /PageLabels << /Nums [\(pageLabels)] >> >>")
    let info=pdf.add("<< /Title \(pdfString(title)) /Creator \(pdfString("FORM · opaque production ink vectors")) /Subject \(pdfString("ICC-SHA256-"+profile.reference.sha256+"; no PDF/X certification")) >>")
    var report=plan.report;report["mode"]=mode.rawValue;report["pdf_pages"]=pageIDs.count;report["page_labels"]=labels;report["path_segments"]=segmentCount
    return(try pdf.document(root:catalog,info:info),report)
  }
  static func pdfName(_ text:String)->String {
    text.utf8.map{byte in
      (33...126).contains(byte) && !Array("#%()/<>[]{}".utf8).contains(byte) ? String(UnicodeScalar(byte)):String(format:"#%02X",byte)
    }.joined()
  }
  static func pdfString(_ text:String)->String {"<FEFF"+text.utf16.map{String(format:"%04X",$0)}.joined()+">"}
  /// PDF numbers have no exponent syntax. Expand Swift's shortest representation
  /// instead of rounding away small but explicitly declared component values.
  static func number(_ value:Double)->String {
    if value==0 {return "0"}
    let text=String(value)
    guard let e=text.firstIndex(where:{$0=="e" || $0=="E"}) else{return text.hasSuffix(".0") ? String(text.dropLast(2)):text}
    var mantissa=String(text[..<e]);let sign=mantissa.hasPrefix("-") ? "-":""
    if !sign.isEmpty {mantissa.removeFirst()}
    let exponent=Int(text[text.index(after:e)...])!,pieces=mantissa.split(separator:".",omittingEmptySubsequences:false)
    let digits=pieces.joined(),point=pieces[0].count+exponent
    if point<=0 {return sign+"0."+String(repeating:"0",count: -point)+digits}
    if point>=digits.count {return sign+digits+String(repeating:"0",count:point-digits.count)}
    let index=digits.index(digits.startIndex,offsetBy:point);return sign+String(digits[..<index])+"."+String(digits[index...])
  }
  private static func path(_ path:CGPath,count:inout Int) throws -> String {
    var commands:[String]=[],current=CGPoint.zero,start=CGPoint.zero,seen=0
    func p(_ point:CGPoint)->String {number(Double(point.x))+" "+number(Double(point.y))}
    path.applyWithBlock {raw in
      seen+=1;guard seen<=2000000 else{return}
      let e=raw.pointee
      switch e.type {
      case .moveToPoint:current=e.points[0];start=current;commands.append(p(current)+" m")
      case .addLineToPoint:current=e.points[0];commands.append(p(current)+" l")
      case .addCurveToPoint:commands.append((0..<3).map{p(e.points[$0])}.joined(separator:" ")+" c");current=e.points[2]
      case .addQuadCurveToPoint:
        let q=e.points[0],end=e.points[1],a=CGPoint(x:current.x+(q.x-current.x)*2/3,y:current.y+(q.y-current.y)*2/3),b=CGPoint(x:end.x+(q.x-end.x)*2/3,y:end.y+(q.y-end.y)*2/3)
        commands.append([a,b,end].map(p).joined(separator:" ")+" c");current=end
      case .closeSubpath:commands.append("h");current=start
      @unknown default:break
      }
    }
    count+=seen;guard count<=2000000 else{throw FormError.invalid("Production ink output exceeds two million path segments; export a smaller page/ink set.")}
    return commands.joined(separator:"\n")
  }
}
