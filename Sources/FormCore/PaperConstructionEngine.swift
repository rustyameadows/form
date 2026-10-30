import Foundation

public enum PaperConstructionEngine {
  public static func definition(for object:ProductObject)throws->PaperConstruction {
    guard PaperConstruction.isPaper(object) else{throw FormError.invalid("Choose a constructed envelope or carton.")}
    var source=object.paperConstruction ?? defaults(recipeID:object.recipeID)
    if source.authored != nil {
      // Validate the accepted stock/source pair before deriving a new value;
      // corrupt caliper metadata must not be silently repaired on read.
      try validate(source)
      source=applying(object.parameters,to:source)
      let caliper=try source.authored!.number(source.authored!.stockThickness)
      if source.stock.plies != nil,abs(caliper-source.stock.resolvedThicknessMM)>1e-9 {
        throw FormError.invalid("Authored stock caliper must equal its bonded ply total; update the source parameter and plies atomically.")
      }
      source.stock.thicknessMM=caliper
      let net=try source.authored!.net()
      source.dimensions = .init(width:object.parameters["width"] ?? net.size.x,
        height:object.parameters["height"] ?? net.size.y,depth:object.parameters["depth"] ?? max(1,source.stock.thicknessMM))
    }
    if PaperConstruction.recipeIDs.contains(object.recipeID){source=applying(object.parameters,to:source)}
    try validate(source);return source
  }
  public static func defaults(recipeID:String)->PaperConstruction {
    recipeID=="tuckCarton" ? .init(kind:.straightTuckCarton,dimensions:.init(width:64,height:138,depth:38),stock:.init(thicknessMM:0.45),clearanceMM:1,glueTabMM:14,topFlapMM:23,bottomFlapMM:23,cornerRadiusMM:3):.init(kind:.envelope,dimensions:.init(width:216,height:275,depth:12))
  }
  public static func parameters(_ s:PaperConstruction)->[String:Double]{
    if let authored=s.authored {return authored.values.merging(["fold":s.foldPercent,"opening":s.openingPercent]){_,new in new}}
    return ["width":s.dimensions.width,"height":s.dimensions.height,"depth":s.dimensions.depth,"stock":s.stock.thicknessMM,"clearance":s.clearanceMM,"glueTab":s.glueTabMM,"topFlap":s.topFlapMM,"bottomFlap":s.bottomFlapMM,"cornerRadius":s.cornerRadiusMM,"fold":s.foldPercent,"opening":s.openingPercent]
  }
  public static func applying(_ values:[String:Double],to original:PaperConstruction)->PaperConstruction {
    var s=original
    if var authored=original.authored {
      for i in authored.parameters.indices {if let v=values[authored.parameters[i].name]{authored.parameters[i].value=v}}
      s.authored=authored
    }
    if let v=values["width"]{s.dimensions.width=v};if let v=values["height"]{s.dimensions.height=v};if let v=values["depth"]{s.dimensions.depth=v};if let v=values["stock"]{s.stock.thicknessMM=v};if let v=values["clearance"]{s.clearanceMM=v};if let v=values["glueTab"]{s.glueTabMM=v};if let v=values["topFlap"]{s.topFlapMM=v};if let v=values["bottomFlap"]{s.bottomFlapMM=v};if let v=values["cornerRadius"]{s.cornerRadiusMM=v};if let v=values["fold"]{s.foldPercent=v};if let v=values["opening"]{s.openingPercent=v};return s
  }
  public static func validate(_ s:PaperConstruction)throws {
    try s.stock.validate()
    guard (s.finishes?.count ?? 0)<=128,Set((s.finishes ?? []).map(\.id)).count==(s.finishes?.count ?? 0) else {
      throw FormError.invalid("Keep at most 128 uniquely identified paper finish assignments.")
    }
    for finish in s.finishes ?? [] {try finish.validate()}
    guard s.annotations.count<=256,Set(s.annotations.map(\.id)).count==s.annotations.count,s.annotations.allSatisfy({($0.panelID?.utf8.count ?? 0)<=256&&($0.edgeID?.utf8.count ?? 0)<=256&&($0.view.map{["panels","dieline","assembled"].contains($0)} ?? true)&&$0.text.utf8.count<=4096&&($0.position.map{$0.x.isFinite&&$0.y.isFinite&&abs($0.x)<=10000&&abs($0.y)<=10000} ?? true)}) else{throw FormError.invalid("Keep paper annotations bounded, finite and uniquely identified.")}
    if s.kind == .authored {
      guard s.version==1,let authored=s.authored,s.foldPercent.isFinite,(0...100).contains(s.foldPercent),
        s.openingPercent.isFinite,(0...100).contains(s.openingPercent),s.annotations.count<=256,
        s.stock.name.utf8.count<=256,s.stock.notes.utf8.count<=2048,
        s.insideArtwork==nil || s.insideArtworkSourceID==nil else {throw FormError.invalid("Invalid authored construction state.")}
      _ = try authored.net()
      guard abs(try authored.number(authored.stockThickness)-s.stock.resolvedThicknessMM)<=1e-9 else {
        throw FormError.invalid("Authored stockThickness must equal the declared stock's resolved total caliper.")
      }
      if let art=s.insideArtwork{try validateArtwork(art)}
      return
    }
    guard s.authored==nil else{throw FormError.invalid("Authored geometry requires the authored construction kind.")}
    let d=s.dimensions,values=[d.width,d.height,d.depth,s.stock.thicknessMM,s.clearanceMM,s.glueTabMM,s.topFlapMM,s.bottomFlapMM,s.cornerRadiusMM,s.foldPercent,s.openingPercent]
    guard s.version==1,values.allSatisfy(\.isFinite),(30...1200).contains(d.width),(40...1600).contains(d.height),(1...600).contains(d.depth),(0.08...2).contains(s.stock.thicknessMM),(0...20).contains(s.clearanceMM),(6...60).contains(s.glueTabMM),(8...150).contains(s.topFlapMM),(8...150).contains(s.bottomFlapMM),(0...20).contains(s.cornerRadiusMM),(0...100).contains(s.foldPercent),(0...100).contains(s.openingPercent),d.depth<=d.width,d.depth<=d.height*0.8,s.glueTabMM<d.width/2,s.topFlapMM<d.height/2,s.bottomFlapMM<d.height/2 else{throw FormError.invalid("Paper dimensions, stock and flap sizes must be finite and form a physically bounded net. Depth cannot exceed width or 80% of height; glue/tuck flaps must be smaller than half their body dimension.")}
    if let art=s.insideArtwork{try validateArtwork(art)}
    guard s.insideArtwork==nil || s.insideArtworkSourceID==nil else{throw FormError.invalid("Use one inside artwork source; inline and linked inside artwork cannot coexist.")}
  }
  private static func rectangle(_ x:Double,_ y:Double,_ width:Double,_ height:Double)->[Point2]{[.init(x,y),.init(x+width,y),.init(x+width,y+height),.init(x,y+height)]}
  private static func area(_ p:[Point2])->Double{guard p.count>=3 else{return 0};return abs(p.indices.reduce(0){sum,i in let b=p[(i+1)%p.count];return sum+p[i].x*b.y-b.x*p[i].y})/2}
  private static func intersectionArea(_ subject:[Point2],_ clip:[Point2])->Double {
    guard subject.count>=3,clip.count>=3 else{return 0};var output=subject
    let signed=clip.indices.reduce(0){sum,i in let b=clip[(i+1)%clip.count];return sum+clip[i].x*b.y-b.x*clip[i].y},orientation=signed>=0 ? 1.0:-1.0
    for i in clip.indices{
      let a=clip[i],b=clip[(i+1)%clip.count],input=output;output=[];guard let last=input.last else{return 0}
      func side(_ p:Point2)->Double{orientation*((b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x))}
      func crossing(_ p:Point2,_ q:Point2)->Point2{let u=side(p),v=side(q),t=u/(u-v);return .init(p.x+(q.x-p.x)*t,p.y+(q.y-p.y)*t)}
      var previous=last,wasInside=side(last)>=(-1e-8)
      for point in input{let inside=side(point)>=(-1e-8);if inside != wasInside{output.append(crossing(previous,point))};if inside{output.append(point)};previous=point;wasInside=inside}
    };return area(output)
  }
  /// Fixed sampling per tip corner preserves semantic segment identities across ordinary dimension edits.
  private static func flap(_ x:Double,_ hingeY:Double,_ width:Double,_ length:Double,_ direction:Double,_ radius:Double,inset:Double)->[Point2]{
    var vertices=[Point2(x,hingeY),.init(x+width,hingeY),.init(x+width-inset,hingeY+direction*length),.init(x+inset,hingeY+direction*length)]
    if direction<0{vertices.reverse()}
    guard radius>1e-8 else{return vertices}
    var result:[Point2]=[]
    for i in vertices.indices{
      let current=vertices[i],previous=vertices[(i+vertices.count-1)%vertices.count],next=vertices[(i+1)%vertices.count]
      guard abs(current.y-hingeY)>1e-8 else{result.append(current);continue}
      let ax=previous.x-current.x,ay=previous.y-current.y,bx=next.x-current.x,by=next.y-current.y,al=hypot(ax,ay),bl=hypot(bx,by),ux=ax/al,uy=ay/al,vx=bx/bl,vy=by/bl,angle=acos(min(1,max(-1,ux*vx+uy*vy))),t=min(radius/tan(angle/2),al*0.28,bl*0.28),r=t*tan(angle/2),bisector=hypot(ux+vx,uy+vy)
      guard bisector>1e-9,r>1e-9 else{result.append(current);continue}
      let cx=current.x+(ux+vx)/bisector*r/sin(angle/2),cy=current.y+(uy+vy)/bisector*r/sin(angle/2),start=atan2(current.y+uy*t-cy,current.x+ux*t-cx),end=atan2(current.y+vy*t-cy,current.x+vx*t-cx)
      var sweep=end-start;while sweep<=0{sweep+=2 * .pi};if sweep>Double.pi{sweep-=2 * .pi}
      for step in 0...12{let a=start+sweep*Double(step)/12;result.append(.init(cx+r*cos(a),cy+r*sin(a)))}
    };return result
  }
  public static func net(_ s:PaperConstruction)throws->PaperNet {
    try validate(s)
    if let authored=s.authored{return try authored.net()}
    let stock=s.stock.thicknessMM,w=s.dimensions.width+stock,h=s.dimensions.height+stock,d=s.dimensions.depth+stock,g=s.glueTabMM,top=d+s.topFlapMM,bottom=top+h,netWidth=2*(w+d)+g,netHeight=top+h+d+s.bottomFlapMM
    var panels:[PaperPanel]=[],folds:[PaperFold]=[],joins:[PaperJoin]=[]
    func add(_ id:String,_ name:String,_ role:PaperPanel.Role,_ polygon:[Point2],parent:String?=nil,start:Point2?=nil,end:Point2?=nil,angle:Double=0){let foldID=parent.map{"fold.\($0).\(id)"};panels.append(.init(id:id,name:name,role:role,polygon:polygon,parentID:parent,foldID:foldID));if let parent,let start,let end,let foldID{folds.append(.init(id:foldID,parentPanelID:parent,childPanelID:id,start:start,end:end,angleDegrees:angle))}}
    add("front","Front",.body,rectangle(0,top,w,h))
    add("side-right","Right side",.side,rectangle(w,top,d,h),parent:"front",start:.init(w,top),end:.init(w,bottom),angle:-90)
    add("back","Back",.body,rectangle(w+d,top,w,h),parent:"side-right",start:.init(w+d,top),end:.init(w+d,bottom),angle:-90)
    add("side-left","Left side",.side,rectangle(2*w+d,top,d,h),parent:"back",start:.init(2*w+d,top),end:.init(2*w+d,bottom),angle:-90)
    add("glue","Side glue seam",.glue,flap(2*(w+d),top,g,h,1,min(s.cornerRadiusMM,2),inset:min(g*0.2,3)),parent:"side-left",start:.init(2*(w+d),top),end:.init(2*(w+d),bottom),angle:-90)
    // The side seam is a rectangular/trapezoid strip along the full body height.
    panels[panels.count-1].polygon=[.init(2*(w+d),top),.init(netWidth-2,top+min(8,h/8)),.init(netWidth-2,bottom-min(8,h/8)),.init(2*(w+d),bottom)]
    let backX=w+d
    add("top-bridge","Top closure",.tuck,rectangle(backX,top-d,w,d),parent:"back",start:.init(backX,top),end:.init(backX+w,top),angle:-90)
    add("top-tuck",s.kind == .envelope ? "Envelope closing flap":"Top tuck tab",.tuck,flap(backX,top-d,w,s.topFlapMM,-1,s.cornerRadiusMM,inset:min(w*0.1,12)),parent:"top-bridge",start:.init(backX,top-d),end:.init(backX+w,top-d),angle:-90)
    add("bottom-bridge","Bottom closure",.bottomClosure,rectangle(backX,bottom,w,d),parent:"back",start:.init(backX,bottom),end:.init(backX+w,bottom),angle:90)
    add("bottom-tuck",s.kind == .envelope ? "Bottom glue flap":"Bottom tuck tab",s.kind == .envelope ? .glue:.tuck,flap(backX,bottom+d,w,s.bottomFlapMM,1,s.cornerRadiusMM,inset:min(w*0.1,12)),parent:"bottom-bridge",start:.init(backX,bottom+d),end:.init(backX+w,bottom+d),angle:90)
    joins.append(.init(id:"join.side-glue",name:"Side seam",firstPanelID:"glue",secondPanelID:"front",overlapMM:g-2,notes:"Bond to the inside of the front panel; keep adhesive off the printed exterior."))
    joins.append(.init(id:"join.bottom",name:s.kind == .envelope ? "Bonded bottom closure":"Bottom tuck",firstPanelID:"bottom-tuck",secondPanelID:"front",kind:s.kind == .envelope ? "glue":"tuck",overlapMM:s.bottomFlapMM,notes:"Prototype the fold allowance and closure retention on actual stock."))
    joins.append(.init(id:"join.top-tuck",name:"Opening flap",firstPanelID:"top-tuck",secondPanelID:"front",kind:"tuck",overlapMM:s.topFlapMM))
    if s.kind == .straightTuckCarton {
      let dust=min(w*0.42,d*1.15),inset=min(4,d*0.12),clearance=min(0.6,d*0.03)
      for (id,x) in [("right",w),("left",2*w+d)] {
        add("dust-top-"+id,"Top "+id+" dust flap",.dust,flap(x+clearance,top,d-2*clearance,dust,-1,min(s.cornerRadiusMM,2),inset:inset),parent:"side-"+id,start:.init(x+clearance,top),end:.init(x+d-clearance,top),angle:-90)
        add("dust-bottom-"+id,"Bottom "+id+" dust flap",.dust,flap(x+clearance,bottom,d-2*clearance,dust,1,min(s.cornerRadiusMM,2),inset:inset),parent:"side-"+id,start:.init(x+clearance,bottom),end:.init(x+d-clearance,bottom),angle:90)
      }
    }
    var edges:[PaperEdge]=[],emitted=Set<String>()
    for panel in panels{for i in panel.polygon.indices{
      let a=panel.polygon[i],b=panel.polygon[(i+1)%panel.polygon.count],dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy),length2=dx*dx+dy*dy
      guard length>1e-7 else{continue};var intervals:[(Double,Double)]=[]
      for fold in folds {
        let crossA=dx*(fold.start.y-a.y)-dy*(fold.start.x-a.x),crossB=dx*(fold.end.y-a.y)-dy*(fold.end.x-a.x)
        guard abs(crossA)/length<1e-7,abs(crossB)/length<1e-7 else{continue}
        let u=((fold.start.x-a.x)*dx+(fold.start.y-a.y)*dy)/length2,v=((fold.end.x-a.x)*dx+(fold.end.y-a.y)*dy)/length2,lo=max(0,min(u,v)),hi=min(1,max(u,v))
        if hi-lo>1e-9{intervals.append((lo,hi))}
      }
      intervals.sort{$0.0<$1.0};var cursor=0.0,pieces:[(Double,Double)]=[]
      for interval in intervals{if interval.0>cursor+1e-9{pieces.append((cursor,interval.0))};cursor=max(cursor,interval.1)};if cursor<1-1e-9{pieces.append((cursor,1))}
      for (part,span) in pieces.enumerated(){let p=Point2(a.x+dx*span.0,a.y+dy*span.0),q=Point2(a.x+dx*span.1,a.y+dy*span.1);guard hypot(q.x-p.x,q.y-p.y)>1e-7 else{continue};let first=String(format:"%.6f,%.6f",p.x,p.y),second=String(format:"%.6f,%.6f",q.x,q.y),key=[first,second].sorted().joined(separator:"|");if emitted.insert(key).inserted{edges.append(.init(id:panel.id+".cut."+String(i)+"."+String(part),panelID:panel.id,start:p,end:q))}}
    }}
    let net=PaperNet(size:.init(netWidth,netHeight),panels:panels,folds:folds,joins:joins,cutEdges:edges)
    guard panels.allSatisfy({$0.polygon.count>=3&&$0.polygon.count<=128&&area($0.polygon)>0.01&&$0.polygon.allSatisfy{$0.x.isFinite&&$0.y.isFinite&&$0.x>=(-1e-6)&&$0.y>=(-1e-6)&&$0.x<=netWidth+1e-6&&$0.y<=netHeight+1e-6}}) else{throw FormError.invalid("This paper construction produced an invalid or overlapping flap extent. Reduce flap length or radius.")}
    for i in panels.indices{for j in panels.indices where j>i{let a=panels[i].bounds,b=panels[j].bounds;if a.x+a.width>b.x+1e-7&&b.x+b.width>a.x+1e-7&&a.y+a.height>b.y+1e-7&&b.y+b.height>a.y+1e-7,intersectionArea(panels[i].polygon,panels[j].polygon)>1e-5{throw FormError.invalid("Paper panels overlap in the flat net: \(panels[i].id) and \(panels[j].id). Reduce flap extent.")}}}
    return net
  }
  private static let identity:[Double]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
  private static func multiply(_ a:[Double],_ b:[Double])->[Double]{var out=[Double](repeating:0,count:16);for r in 0..<4{for c in 0..<4{out[r*4+c]=(0..<4).reduce(0){$0+a[r*4+$1]*b[$1*4+c]}}};return out}
  private static func translation(_ x:Double,_ y:Double,_ z:Double)->[Double]{[1,0,0,x,0,1,0,y,0,0,1,z,0,0,0,1]}
  private static func rotate(axis:Vector3,radians:Double)->[Double]{let n=sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z),x=axis.x/n,y=axis.y/n,z=axis.z/n,c=cos(radians),s=sin(radians),t=1-c;return [t*x*x+c,t*x*y-s*z,t*x*z+s*y,0,t*x*y+s*z,t*y*y+c,t*y*z-s*x,0,t*x*z-s*y,t*y*z+s*x,t*z*z+c,0,0,0,0,1]}
  private static func point(_ m:[Double],_ p:Point2,z:Double)->Vector3{.init(m[0]*p.x-m[1]*p.y+m[2]*z+m[3],m[4]*p.x-m[5]*p.y+m[6]*z+m[7],m[8]*p.x-m[9]*p.y+m[10]*z+m[11])}
  public static func resolvedPanels(_ source:PaperConstruction,foldPercent:Double?=nil)throws->[PaperResolvedPanel] {
    let net=try net(source),amount=(foldPercent ?? source.foldPercent)/100
    guard amount.isFinite,(0...1).contains(amount) else{throw FormError.invalid("Paper folding is a preview percentage from 0 to 100.")}
    if source.authored?.components?.isEmpty == false {
      return try PlanarComponentPoseResolver.resolve(source,net:net,amount:amount).panels
    }
    let base:[Double]=[1,0,0,-net.size.x/2,0,0,1,source.stock.thicknessMM/2,0,-1,0,-net.size.y/2,0,0,0,1]
    let global=multiply(rotate(axis:.init(1,0,0),radians:amount * .pi/2),base)
    var matrices:[String:[Double]]=[net.rootPanelID:global],closedMatrices:[String:[Double]]=[net.rootPanelID:global],remaining=net.panels.filter{$0.id != net.rootPanelID}
    let opening=source.openingPercent/100
    func localMatrix(_ panel:PaperPanel,_ fold:PaperFold,_ amount:Double)->[Double]{let p=fold.start,axis=Vector3(fold.end.x-p.x,-fold.end.y+p.y,0);var m=multiply(translation(p.x,-p.y,0),multiply(rotate(axis:axis,radians:fold.angleDegrees * .pi/180*amount),translation(-p.x,p.y,0)))
      let layer:Double=panel.id=="glue" ? 1:panel.id=="bottom-tuck" || panel.id=="top-tuck" ? 2:panel.role == .dust ? 1:0
      let offset=source.authored != nil ? fold.layerOffsetMM ?? 0:source.stock.thicknessMM*layer
      if offset != 0{m=multiply(m,translation(0,0,-offset*amount))};return m}
    for _ in 0..<net.panels.count{if remaining.isEmpty{break};var next:[PaperPanel]=[];for panel in remaining{guard let parent=panel.parentID,let parentMatrix=matrices[parent],let parentClosed=closedMatrices[parent],let fold=net.folds.first(where:{$0.id==panel.foldID}) else{next.append(panel);continue}
      let top=source.authored != nil ? fold.opensWithTop == true:panel.id.hasPrefix("top-") || panel.id.hasPrefix("dust-top-")
      matrices[panel.id]=multiply(parentMatrix,localMatrix(panel,fold,amount*(top ? 1-opening:1)))
      closedMatrices[panel.id]=multiply(parentClosed,localMatrix(panel,fold,amount))
    };remaining=next}
    guard matrices.count==net.panels.count else{throw FormError.invalid("Paper fold hierarchy is disconnected or cyclic.")}
    var low=Vector3(.infinity,.infinity,.infinity),high=Vector3(-.infinity,-.infinity,-.infinity)
    for panel in net.panels{let m=closedMatrices[panel.id]!;for p in panel.polygon{for z in [-source.stock.thicknessMM/2,source.stock.thicknessMM/2]{let v=point(m,p,z:z);low = .init(min(low.x,v.x),min(low.y,v.y),min(low.z,v.z));high = .init(max(high.x,v.x),max(high.y,v.y),max(high.z,v.z))}}}
    let ground=translation(-(low.x+high.x)/2,-low.y,-(low.z+high.z)/2)
    return net.panels.map{.init(panelID:$0.id,flatToWorld:multiply(ground,matrices[$0.id]!))}
  }
  public static func preflight(_ s:PaperConstruction,contents:PaperDimensions?=nil)throws->PaperPreflight {
    let net=try net(s);var issues:[PaperPreflightIssue]=[]
    let panelIDs=Set(net.panels.map(\.id)),edgeIDs=Set(net.cutEdges.map(\.id)).union(net.folds.map(\.id))
    for annotation in s.annotations{
      if let panel=annotation.panelID,!panelIDs.contains(panel){issues.append(.init(id:annotation.id.uuidString+".panel",severity:.warning,code:"orphan-panel-annotation",message:"A saved note references missing panel \(panel). Its source anchor is preserved; review it instead of silently retargeting."))}
      if let edge=annotation.edgeID,!edgeIDs.contains(edge){issues.append(.init(id:annotation.id.uuidString+".edge",severity:.warning,code:"orphan-edge-annotation",message:"A saved note references an edge that changed (\(edge)). Its source anchor is preserved and needs review."))}
    }
    if !s.stock.verified{issues.append(.init(severity:.warning,code:"unverified-stock",message:"Stock caliper, grain, scoring and adhesive remain prototype assumptions; prove the construction on actual material."))}
    if s.stock.grain == .unknown{issues.append(.init(severity:.warning,code:"unknown-grain",message:"Declare grain direction before final scoring; grain and fold tooling affect cracking and springback."))}
    if s.artworkReviewRequired{issues.append(.init(severity:.warning,code:"artwork-review",message:"The net dimensions changed. Artwork retains its original physical coordinates and needs a panel/bleed placement review."))}
    if s.authored==nil,s.stock.thicknessMM>s.dimensions.depth/5{issues.append(.init(severity:.warning,code:"thick-stock",message:"Stock is thick relative to package depth. Neutral-axis allowances are a starting estimate, not a tested crease specification."))}
    if let contents{
      guard s.authored==nil else {throw FormError.invalid("Authored construction fit requires a named declared interior and actual contents_object_id; flat-net dimensions are not a usable cavity.")}
      let d=s.dimensions,c=s.clearanceMM;guard [contents.width,contents.height,contents.depth].allSatisfy({$0.isFinite&&$0>0}) else{throw FormError.invalid("Contents measurements must be finite positive millimeters.")};if contents.width+2*c>d.width || contents.height+2*c>d.height || contents.depth+2*c>d.depth{issues.append(.init(severity:.error,code:"contents-fit",message:"Declared contents plus clearance exceed usable internal dimensions."))}
    }
    let interiors=try resolvedInteriors(s)
    if s.authored != nil,interiors.isEmpty {issues.append(.init(severity:.warning,code:"interior-not-declared",message:"This authored construction has no declared usable interior. Net extents do not establish contents fit."))}
    issues.append(.init(severity:.info,code:"duplex-proof",message:"Inside artwork uses the same registered flat-net coordinates. Verify actual feed/turn orientation with a duplex proof; no machine setup is inferred."))
    return .init(issues:issues,netSize:net.size,usableInternalDimensions:s.authored==nil ? s.dimensions:nil,
      requiresArtworkReview:s.artworkReviewRequired,declaredInteriors:interiors.isEmpty ? nil:interiors)
  }
}
extension PaperNet {
  public func layout(sheetSize:Point2,marginMM:Double=10,gapMM:Double=6,count:Int=1,allowRotation:Bool=true)throws->PaperLayout {
    guard sheetSize.x.isFinite,sheetSize.y.isFinite,marginMM.isFinite,gapMM.isFinite,(50...5000).contains(sheetSize.x),(50...5000).contains(sheetSize.y),(0...200).contains(marginMM),(0...200).contains(gapMM),(1...500).contains(count),sheetSize.x>2*marginMM,sheetSize.y>2*marginMM else{throw FormError.invalid("Use a bounded physical sheet, nonnegative margins/gap and 1–500 copies.")}
    let usable=Point2(sheetSize.x-2*marginMM,sheetSize.y-2*marginMM)
    func capacity(_ rotated:Bool)->(Int,Int,Double,Double){let w=rotated ? size.y:size.x,h=rotated ? size.x:size.y;return(Int(floor((usable.x+gapMM)/(w+gapMM))),Int(floor((usable.y+gapMM)/(h+gapMM))),w,h)}
    var best=capacity(false),rotated=false;if allowRotation{let other=capacity(true);if other.0*other.1>best.0*best.1{best=other;rotated=true}}
    let perSheet=best.0*best.1
    guard perSheet>0 else{return .init(sheetSize:sheetSize,marginMM:marginMM,gapMM:gapMM,count:count,placements:[],sheetCount:0,wasteFraction:1,issues:[.init(severity:.error,code:"sheet-too-small",message:"The complete net does not fit the usable sheet at actual scale. Choose larger stock; no automatic scaling was applied.")])}
    let placements=(0..<count).map{i->PaperLayoutPlacement in let cell=i%perSheet,x=marginMM+Double(cell%best.0)*(best.2+gapMM),y=marginMM+Double(cell/best.0)*(best.3+gapMM);return .init(id:i,sheetIndex:i/perSheet,origin:.init(x,y),rotationDegrees:rotated ? 90:0,bounds:.init(x:x,y:y,width:best.2,height:best.3))}
    let sheets=(count+perSheet-1)/perSheet
    var netArea=0.0
    for panel in panels{var signedArea=0.0;for i in panel.polygon.indices{let a=panel.polygon[i],b=panel.polygon[(i+1)%panel.polygon.count];signedArea+=a.x*b.y-b.x*a.y};netArea+=abs(signedArea)/2}
    let waste=1-netArea*Double(count)/(sheetSize.x*sheetSize.y*Double(sheets))
    return .init(sheetSize:sheetSize,marginMM:marginMM,gapMM:gapMM,count:count,placements:placements,sheetCount:sheets,wasteFraction:min(1,max(0,waste)),issues:[.init(severity:.info,code:"layout-assumptions",message:"Conservative rectangular nesting at actual scale. Kerf, gripper area, grain/duplex feed and machine margins need physical confirmation.")])
  }
}
