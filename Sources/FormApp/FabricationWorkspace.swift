import AppKit
import FormCore
import SwiftUI

struct FabricationWorkspace:View {
  @EnvironmentObject var store:StudioStore
  @ObservedObject var guide:FabricationGuide
  private var objects:[ProductObject]{store.project?.objects.filter{$0.hasTablePresentation} ?? []}
  var body:some View {
    GeometryReader {g in
      HStack(spacing:0) {
        stepRail.frame(width:g.size.width>1100 ? 205:165)
        Divider()
        VStack(alignment:.leading,spacing:0) {
          ScrollView {
            VStack(alignment:.leading,spacing:24) {
              EnvironmentPageHeading(eyebrow:"Fabricate · step \(guide.step.rawValue+1) of 5",title:title,detail:detail)
              stepContent
              if let issue=guide.issue {Label(issue,systemImage:"exclamationmark.circle").font(.system(size:12)).foregroundStyle(Palette.accent).fixedSize(horizontal:false,vertical:true)}
            }.padding(28).frame(maxWidth:820,alignment:.leading).frame(maxWidth:.infinity,alignment:.center)
          }
          Divider()
          HStack {
            Button("Back"){if let value=FabricationStep(rawValue:guide.step.rawValue-1){guide.step=value}}.disabled(guide.step == .object)
            Spacer()
            if guide.step != .review {Button("Continue to "+(FabricationStep(rawValue:guide.step.rawValue+1)?.title.lowercased() ?? "review")){guide.next()}.buttonStyle(.borderedProminent).tint(Palette.ink).disabled(!guide.canContinue).accessibilityLabel("Continue fabrication guide")}
            else {Label("Local preparation · no machine job sent",systemImage:"doc.badge.checkmark").font(.system(size:11)).foregroundStyle(Palette.secondary)}
          }.padding(20)
        }.frame(minWidth:380,maxWidth:.infinity,maxHeight:.infinity)
        if g.size.width>1130 {Divider();summary.frame(width:290)}
      }.background(Palette.paper)
    }.onAppear{guide.reconcile()}.onChange(of:store.primary?.id){_,_ in guide.reconcile()}.onChange(of:store.project?.id){_,_ in guide.reconcile()}.onChange(of:store.revision){_,_ in guide.reconcile()}
  }
  private var title:String {
    switch guide.step {case .object:return "What are we making?";case .process:return "Choose how to make it.";case .material:return guide.paper != nil ? "Choose the paper.":"Choose the material.";case .prepare:return "Prepare this version.";case .review:return "Review before making."}
  }
  private var detail:String {
    switch guide.step {
    case .object:return "Choose a project object. Its design stays connected through every preparation step."
    case .process:return "These routes are available from the selected source. Choose the one you intend to use."
    case .material:return guide.paper != nil ? "The construction declares paper stock. Review and edit what you will actually use; opening this view does not confirm it.":"Design appearance and production material are separate choices. Review the declaration, then confirm it for this preparation."
    case .prepare:return "Use physical dimensions, review the arrangement, and resolve errors before exporting."
    case .review:return "Export local files from the current source. Prove the material and process with a physical sample."
    }
  }
  private var stepRail:some View {
    VStack(alignment:.leading,spacing:10) {
      SectionLabel("MAKE SOMETHING").padding(.bottom,16)
      ForEach(FabricationStep.allCases) {step in
        Button {guide.step=step} label:{
          HStack(alignment:.top,spacing:10) {
            Text(String(step.rawValue+1)).font(.system(size:11,weight:.medium,design:.monospaced)).frame(width:25,height:25)
              .background(guide.step==step ? Palette.accent:Color.clear,in:Circle()).foregroundStyle(guide.step==step ? Color.white:Palette.secondary).overlay(Circle().stroke(Palette.line))
            VStack(alignment:.leading,spacing:5) {Text(step.title).font(.system(size:12,weight:guide.step==step ? .semibold:.medium));Text(step.detail).font(.system(size:10)).foregroundStyle(Palette.secondary)}
            Spacer(minLength:0)
          }.padding(.vertical,11)
        }.buttonStyle(.plain).accessibilityLabel("Fabricate step "+step.title)
      }
      Spacer()
      Divider()
      Button("Materials & equipment…"){store.showingLibrary=true}.font(.system(size:11)).buttonStyle(.plain)
      Button("Production archives…"){store.presentFabrication(.jobs)}.font(.system(size:11)).buttonStyle(.plain)
      Button("Collection production…"){store.presentFabrication(.collection)}.font(.system(size:11)).buttonStyle(.plain)
    }.padding(20)
  }
  @ViewBuilder private var stepContent:some View {
    switch guide.step {
    case .object:
      LazyVGrid(columns:[GridItem(.adaptive(minimum:205),spacing:14)],spacing:14) {
        ForEach(objects) {object in
          Button {store.selectWorkingObject(object.id)} label:{
            VStack(alignment:.leading,spacing:15) {
              ProductSchematic(object:object).frame(height:125)
              Text(object.name).font(.system(size:13,weight:.medium)).lineLimit(2)
              Text(store.project?.recipe(object.recipeID)?.name ?? object.recipeID).font(.system(size:11)).foregroundStyle(Palette.secondary)
              Label(store.primary?.id==object.id ? "Selected source":"Use this object",systemImage:store.primary?.id==object.id ? "checkmark.circle.fill":"plus.circle").font(.system(size:10)).foregroundStyle(store.primary?.id==object.id ? Palette.accent:Palette.secondary)
            }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color.white.opacity(0.7),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(store.primary?.id==object.id ? Palette.accent:Palette.line))
          }.buttonStyle(.plain).accessibilityLabel("Make "+object.name)
        }
      }
      if objects.isEmpty {ContentUnavailableView("Start with a design",systemImage:"cube.transparent",description:Text("Add an object in Form before preparing it for making."))}
      if guide.paper != nil {Stepper("Prototype quantity: \(guide.quantity)",value:$guide.quantity,in:1...64).font(.system(size:12))}
    case .process:
      if guide.object==nil {chooseSource}
      else {
        ForEach(guide.processes) {process in
          Button {guide.choose(process)} label:{
            HStack(alignment:.top,spacing:18) {
              Image(systemName:process.symbol).font(.system(size:27,weight:.ultraLight)).frame(width:52,height:56)
              VStack(alignment:.leading,spacing:7) {Text(process.title).font(.system(size:15,weight:.medium));Text(process.explanation).font(.system(size:11)).foregroundStyle(Palette.secondary).fixedSize(horizontal:false,vertical:true)}
              Spacer(minLength:0)
              Image(systemName:guide.process==process ? "checkmark.circle.fill":"circle").foregroundStyle(guide.process==process ? Palette.accent:Palette.secondary)
            }.padding(20).background(Color.white.opacity(0.7),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(guide.process==process ? Palette.accent:Palette.line))
          }.buttonStyle(.plain).accessibilityLabel("Fabrication process "+process.title)
        }
        if guide.processes.isEmpty {Text("No supported preparation route is available for this source. Choose a resolved component or artwork sheet.").foregroundStyle(Palette.secondary)}
      }
    case .material:
      if guide.process==nil {chooseProcess}
      else if guide.paper != nil {paperMaterial}
      else {generalMaterial}
    case .prepare:
      if !guide.materialConfirmed {confirmStock}
      else if let object=guide.object,guide.process == .paper {
        paperSide(object)
        HStack(alignment:.top,spacing:18) {
          VStack(alignment:.leading,spacing:14) {
            SectionLabel("PHYSICAL SHEETS")
            number("Sheet width",text:$guide.sheetWidth,unit:"mm");number("Sheet height",text:$guide.sheetHeight,unit:"mm")
            number("Margin",text:$guide.margin,unit:"mm");number("Between blanks",text:$guide.gap,unit:"mm")
            Stepper("\(guide.quantity) prototypes",value:$guide.quantity,in:1...64)
            Button("Update layout"){do{try guide.applyLayout();guide.issue=nil}catch{guide.issue=error.localizedDescription}}
          }.frame(width:220)
          PaperConstructionPreview(object:object,representation:.sheet).frame(minHeight:330).clipShape(RoundedRectangle(cornerRadius:8))
        }.font(.system(size:12))
        ProcessSequence(process:.paper)
      }else if let process=guide.process {
        ProcessSequence(process:process)
        Text(process.explanation).font(.system(size:13)).foregroundStyle(Palette.secondary)
        Button("Open "+process.title){guide.openPreparation()}.buttonStyle(.borderedProminent).tint(Palette.ink)
        Text("The dedicated preparation window contains the detailed controls and real preview for this process. Return here to review your next steps.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      }
    case .review:
      if !guide.materialConfirmed {confirmStock}
      else if let object=guide.object,let process=guide.process {
        HStack(spacing:18) {ProductSchematic(object:object).frame(width:120,height:140);VStack(alignment:.leading,spacing:8){Text(object.name).font(.system(size: 19, weight: .semibold));Text(process.title).font(.system(size:13));Label("Material declaration confirmed for this session",systemImage:"checkmark.circle").font(.system(size:11)).foregroundStyle(Palette.secondary)}}
        if process == .paper,let d=guide.paper {
          paperSide(object)
          if let layout=try? PaperOutput.layout(store:store,definition:d) {Text("\(layout.placements.count) blanks · \(layout.sheetCount) sheets · \(Int(layout.sheetSize.x)) × \(Int(layout.sheetSize.y)) mm").font(.system(size:14,weight:.medium))}
          if let report=try? d.preflight(){ForEach(report.issues){issue in Label(issue.message,systemImage:issue.severity == .error ? "xmark.circle":"exclamationmark.circle").font(.system(size:11)).foregroundStyle(issue.severity == .error ? Palette.ink:Palette.secondary)}}
          HStack {Button("Cut & crease SVG…"){exportPaper(object,"svg")};Button("Sheet proof PDF…"){exportPaper(object,"pdf")};Button("Production packet…"){exportPaper(object,"packet")}.buttonStyle(.borderedProminent).tint(Palette.ink)}
        }else {Button("Open "+process.title){guide.openPreparation()}.buttonStyle(.borderedProminent).tint(Palette.ink)}
        ProcessSequence(process:process)
      }else {chooseProcess}
    }
  }
  private var chooseSource:some View {VStack(alignment:.leading,spacing:12){Text("Choose the object first.");Button("Choose what to make"){guide.step = .object}}}
  private var chooseProcess:some View {VStack(alignment:.leading,spacing:12){Text("Choose a supported process first.");Button("Choose process"){guide.step = .process}}}
  private var confirmStock:some View {VStack(alignment:.leading,spacing:12){Label("Material has not been confirmed, or its declaration changed.",systemImage:"exclamationmark.circle");Button("Review material"){guide.step = .material}}.font(.system(size:12))}
  private var paperMaterial:some View {
    VStack(alignment:.leading,spacing:20) {
      HStack(alignment:.top,spacing:24) {
        VStack(alignment:.leading,spacing:12) {
          PaperStockSwatch().frame(width:150,height:190)
          Text("FROM PROJECT").font(.system(size:9,weight:.semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
          Text("The saved construction declares this stock. Confirm it or edit the values to match your actual sheet.").font(.system(size:11)).foregroundStyle(Palette.secondary).frame(width:155)
        }
        VStack(alignment:.leading,spacing:14) {
          TextField("Stock name",text:$guide.stockName).textFieldStyle(.roundedBorder).accessibilityLabel("Production paper stock name")
          number("Caliper",text:$guide.caliper,unit:"mm")
          number("Basis weight",text:$guide.gsm,unit:"GSM")
          Picker("Grain",selection:$guide.grain){Text("Unknown · needs review").tag(PaperStock.Grain.unknown);Text("Parallel to net height").tag(PaperStock.Grain.parallelHeight);Text("Parallel to net width").tag(PaperStock.Grain.parallelWidth)}
          number("Sheet width",text:$guide.sheetWidth,unit:"mm");number("Sheet height",text:$guide.sheetHeight,unit:"mm")
          Toggle("I have measured / verified this stock",isOn:$guide.measured).font(.system(size:11))
          Text("Caliper affects the construction. Applying stock updates it as one undoable edit while preserving artwork coordinates.").font(.system(size:10)).foregroundStyle(Palette.secondary)
        }.font(.system(size:12))
      }.padding(22).background(Color.white.opacity(0.8),in:RoundedRectangle(cornerRadius:10)).overlay(RoundedRectangle(cornerRadius:10).stroke(Palette.line))
      HStack {Button("Reload project stock"){guide.reloadMaterial()};Spacer();Button(guide.materialConfirmed ? "Stock confirmed":"Apply & confirm stock"){guide.confirmMaterial()}.buttonStyle(.borderedProminent).tint(Palette.ink).accessibilityLabel("Apply and confirm production material")}
      Text("Unknown grain or unmeasured stock remains visible in preflight. Confirmation records your choice; it does not certify the material.").font(.system(size:11)).foregroundStyle(Palette.secondary)
    }
  }
  private var generalMaterial:some View {
    VStack(alignment:.leading,spacing:18) {
      Label("From the selected design",systemImage:"link").font(.system(size:11)).foregroundStyle(Palette.secondary)
      if guide.process == .print3D {
        SectionLabel("ACTUAL FILAMENT & PRINTER")
        Picker("Printer",selection:$guide.printerID){Text("Choose a saved printer").tag(UUID?.none);ForEach(store.library.printers){printer in Text(printer.name).tag(Optional(printer.id))}}
        Picker("Filament",selection:$guide.filamentID){Text("Choose a saved filament").tag(UUID?.none);ForEach(store.library.filaments){filament in Text(filament.name+" · "+filament.polymer).tag(Optional(filament.id))}}
        Text("These are explicit production choices from your library. Confirming them saves this object's print setup; it does not slice, upload or print.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      }else if let object=guide.object,object.patternAssembly != nil {
        Text("This assembly uses the fabric snapshots on its original pattern panels.").font(.system(size:12))
        ForEach(object.patternAssembly?.panels ?? [],id:\.panel){panel in Text(panel.material.name+String(format:" · %.0f GSM",panel.densityGSM)).font(.system(size:12))}
        Button("Edit original construction"){store.showEnvironment(.function)}
      }else {
        Picker("Design material",selection:$guide.materialID){ForEach(store.materials){material in Text(material.name).tag(material.id)}}
        Text("This is the design's material declaration. Printer filament, thread, roll stock and process settings are selected in the dedicated preparation window.").font(.system(size:11)).foregroundStyle(Palette.secondary)
      }
      Button("Edit material, filament & equipment library…"){store.showingLibrary=true}
      Button(guide.materialConfirmed ? "Declaration confirmed":"Apply & confirm declaration"){guide.confirmMaterial()}.buttonStyle(.borderedProminent).tint(Palette.ink)
    }.padding(24).background(Color.white.opacity(0.7),in:RoundedRectangle(cornerRadius:10))
  }
  private func number(_ title:String,text:Binding<String>,unit:String)->some View {
    HStack{Text(title);Spacer();TextField(title,text:text).font(Palette.numericFont).textFieldStyle(.roundedBorder).frame(width:85).accessibilityLabel("Fabrication "+title);Text(unit).foregroundStyle(Palette.secondary).frame(width:33,alignment:.leading)}.font(.system(size:12))
  }
  private func paperSide(_ object:ProductObject)->some View {
    VStack(alignment:.leading,spacing:7) {
      Picker("Proof / SVG artwork side",selection:Binding(get:{store.paperInside},set:{store.setPaperInside($0,object:object)})){Text("Outside").tag(false);Text("Inside · registered layout").tag(true)}.frame(maxWidth:420)
      Text("The packet includes both available artwork sources. A single proof or SVG uses the selected side.").font(.system(size:10)).foregroundStyle(Palette.secondary)
    }
  }
  private var summary:some View {
    ScrollView {VStack(alignment:.leading,spacing:20) {
      SectionLabel("PREPARATION SUMMARY")
      if let object=guide.object {
        ProductSchematic(object:object).frame(height:170)
        Text(object.name).font(.system(size: 18, weight: .semibold))
        Text(guide.process?.title ?? "Process · not chosen").font(.system(size:12))
        Divider()
        if let d=guide.paper {
          Text(d.stock.name).font(.system(size:12,weight:.medium))
          Text(String(format:"%.2f mm · %@",d.stock.thicknessMM,d.stock.verified ? "measured declaration":"unverified declaration")).font(.system(size:11)).foregroundStyle(Palette.secondary)
          PaperConstructionPreview(object:object,representation:.dieline).frame(height:185).clipShape(RoundedRectangle(cornerRadius:7))
          Text("\(guide.quantity) prototypes").font(.system(size:12))
        }
        Label(guide.materialConfirmed ? "Declaration confirmed":"Material needs confirmation",systemImage:guide.materialConfirmed ? "checkmark.circle":"circle.dashed").font(.system(size:11)).foregroundStyle(Palette.secondary)
        Divider()
        if let process=guide.process {ProcessSequence(process:process,compact:true)}
      }else {Text("Choose a source object to begin.").font(.system(size:12)).foregroundStyle(Palette.secondary)}
    }.padding(24)}
  }
  private func exportPaper(_ object:ProductObject,_ format:String){do{try guide.applyLayout();store.exportPaperDialog(object:object,format:format)}catch{guide.issue=error.localizedDescription}}
}

struct ProcessSequence:View {
  let process:GuidedProcess
  var compact=false
  private var steps:[(String,String)] {
    switch process {case .paper:return [("printer","Print"),("scissors","Cut"),("line.diagonal","Crease"),("shippingbox","Assemble")];case .print3D:return [("cube.transparent","Orient"),("square.stack.3d.up","Slice"),("doc","Review")];case .pattern,.layout:return [("ruler","Measure"),("rectangle.split.3x1","Arrange"),("scissors","Cut")];case .embroidery:return [("point.topleft.down.to.point.bottomright.curvepath","Stitches"),("eye","Review"),("doc","Export")];case .page,.decoration:return [("square.and.pencil","Artwork"),("ruler","Size"),("doc","Export")]}
  }
  var body:some View {
    HStack(spacing:compact ? 9:20) {
      ForEach(Array(steps.enumerated()),id:\.offset) {index,item in
        VStack(spacing:10) {Image(systemName:item.0).font(.system(size:compact ? 19:27,weight:.ultraLight)).frame(height:36);Text(item.1).font(.system(size:compact ? 9:11,weight:.medium)).lineLimit(1).minimumScaleFactor(0.75)}.frame(maxWidth:.infinity)
        if index<steps.count-1 {Image(systemName:"arrow.right").font(.system(size:9)).foregroundStyle(Palette.secondary)}
      }
    }.padding(.vertical,18)
  }
}
struct ProductSchematic:View {
  let object:ProductObject
  var body:some View {
    GeometryReader {g in
      if !PaperConstruction.isPaper(object) && object.recipeID != "box" {
        Image(systemName:Recipe.builtins.first(where:{$0.id==object.recipeID})?.symbol ?? "cube.transparent").font(.system(size:min(g.size.width,g.size.height)*0.55,weight:.ultraLight)).foregroundStyle(Palette.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)
      }else {
      let w=min(g.size.width*0.5,g.size.height*0.57),h=min(g.size.height*0.72,w*1.7),x=(g.size.width-w)/2,y=(g.size.height-h)/2,d=w*0.25
      Canvas {context,_ in
        let front=Path(CGRect(x:x,y:y+d,width:w,height:h-d))
        var side=Path();side.move(to:.init(x:x+w,y:y+d));side.addLines([.init(x:x+w+d,y:y),.init(x:x+w+d,y:y+h-d),.init(x:x+w,y:y+h)]);side.closeSubpath()
        var top=Path();top.move(to:.init(x:x,y:y+d));top.addLines([.init(x:x+d,y:y),.init(x:x+w+d,y:y),.init(x:x+w,y:y+d)]);top.closeSubpath()
        context.fill(front,with:.color(Color(nsColor:NSColor(hex:object.color ?? "#FFFFFF"))))
        context.fill(side,with:.color(.black.opacity(0.12)));context.fill(top,with:.color(.white.opacity(0.8)))
        for path in [front,side,top] {context.stroke(path,with:.color(Palette.secondary.opacity(0.5)),lineWidth:0.7)}
      }
      }
    }.accessibilityLabel("Illustrative product schematic · "+object.name)
  }
}
struct PaperStockSwatch:View {
  var body:some View {
    Canvas {context,size in
      let rect=CGRect(origin:.zero,size:size);context.fill(Path(roundedRect:rect,cornerRadius:5),with:.color(Color(nsColor:NSColor(hex:"#F2F2F2"))))
      for i in 0..<850 {let x=Double((i*73)%997)/997*size.width,y=Double((i*139)%991)/991*size.height;context.fill(Path(ellipseIn:.init(x:x,y:y,width:0.7,height:0.7)),with:.color(.black.opacity(0.06)))}
      var corner=Path();corner.move(to:.init(x:size.width-42,y:size.height));corner.addLines([.init(x:size.width,y:size.height-42),.init(x:size.width,y:size.height)]);corner.closeSubpath();context.fill(corner,with:.color(.black.opacity(0.07)))
    }.accessibilityLabel("Illustrative uncoated paper swatch")
  }
}
