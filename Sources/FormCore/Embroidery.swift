import Foundation

public struct EmbroideryThread:Codable,Equatable,Sendable {
  public var name:String
  public var color:String
  public var brand:String?
  public var catalog:String?
  public init(name:String,color:String) {self.name=name;self.color=color}
}

public struct EmbroideryRegion:Codable,Equatable,Identifiable,Sendable {
  public enum Method:String,Codable,CaseIterable,Sendable {case running,satin,fill}
  public var id:UUID
  public var elementIDs:[UUID]
  public var method:Method
  public var threadIndex:Int
  public var stitchLength:Double
  public var spacing:Double
  public var satinWidth:Double
  public var angle:Double
  public init(elementIDs:[UUID],method:Method,threadIndex:Int = 0) {
    id=UUID();self.elementIDs=elementIDs;self.method=method;self.threadIndex=threadIndex
    stitchLength=2.5;spacing=0.4;satinWidth=2.8;angle=0
  }
  private enum CodingKeys:String,CodingKey {case id,elementIDs,method,threadIndex,stitchLength,spacing,satinWidth,angle}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    id=try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID()
    elementIDs=try c.decode([UUID].self,forKey:.elementIDs)
    method=try c.decodeIfPresent(Method.self,forKey:.method) ?? .running
    threadIndex=try c.decodeIfPresent(Int.self,forKey:.threadIndex) ?? 0
    stitchLength=try c.decodeIfPresent(Double.self,forKey:.stitchLength) ?? 2.5
    spacing=try c.decodeIfPresent(Double.self,forKey:.spacing) ?? 0.4
    satinWidth=try c.decodeIfPresent(Double.self,forKey:.satinWidth) ?? 2.8
    angle=try c.decodeIfPresent(Double.self,forKey:.angle) ?? 0
  }
}

/// Regenerable digitizing intent. Needle commands are derived, never substituted
/// for the original editable artwork or assumed to be physically sew-out verified.
public struct EmbroideryDesign:Codable,Equatable,Sendable {
  public var hoopWidth:Double
  public var hoopHeight:Double
  public var margin:Double
  public var trimJumpThreshold:Double
  public var maximumStitches:Int
  public var threads:[EmbroideryThread]
  public var regions:[EmbroideryRegion]
  public init(threads:[EmbroideryThread],regions:[EmbroideryRegion]) {
    hoopWidth=100;hoopHeight=100;margin=5;trimJumpThreshold=4;maximumStitches=100000
    self.threads=threads;self.regions=regions
  }
  private enum CodingKeys:String,CodingKey {case hoopWidth,hoopHeight,margin,trimJumpThreshold,maximumStitches,threads,regions}
  public init(from decoder:Decoder)throws {
    let c=try decoder.container(keyedBy:CodingKeys.self)
    hoopWidth=try c.decodeIfPresent(Double.self,forKey:.hoopWidth) ?? 100
    hoopHeight=try c.decodeIfPresent(Double.self,forKey:.hoopHeight) ?? 100
    margin=try c.decodeIfPresent(Double.self,forKey:.margin) ?? 5
    trimJumpThreshold=try c.decodeIfPresent(Double.self,forKey:.trimJumpThreshold) ?? 4
    maximumStitches=try c.decodeIfPresent(Int.self,forKey:.maximumStitches) ?? 100000
    threads=try c.decode([EmbroideryThread].self,forKey:.threads)
    regions=try c.decode([EmbroideryRegion].self,forKey:.regions)
  }
  public func validate()throws {
    guard [hoopWidth,hoopHeight,margin,trimJumpThreshold].allSatisfy(\.isFinite),
      (20...500).contains(hoopWidth),(20...500).contains(hoopHeight),(0.5...50).contains(margin),
      margin*2 < min(hoopWidth,hoopHeight),(0.5...100).contains(trimJumpThreshold),
      (1...100000).contains(maximumStitches),(1...32).contains(threads.count),(1...128).contains(regions.count),
      Set(regions.map(\.id)).count==regions.count else {throw FormError.invalid("Embroidery needs a 20–500 mm hoop, at least 0.5 mm clearance, 1–32 threads, 1–128 regions, and at most 100000 stitches.")}
    for thread in threads {
      try validateColor(thread.color)
      guard !thread.name.isEmpty,thread.name.count<=160,(thread.brand?.count ?? 0)<=160,(thread.catalog?.count ?? 0)<=160 else {throw FormError.invalid("Use bounded thread names and catalog references.")}
    }
    for region in regions {
      guard !region.elementIDs.isEmpty,region.elementIDs.count<=256,Set(region.elementIDs).count==region.elementIDs.count,
        threads.indices.contains(region.threadIndex),[region.stitchLength,region.spacing,region.satinWidth,region.angle].allSatisfy(\.isFinite),
        (0.4...10).contains(region.stitchLength),(0.15...5).contains(region.spacing),
        (0.5...10).contains(region.satinWidth),abs(region.angle)<=36000 else {throw FormError.invalid("Use existing thread indices, 0.4–10 mm stitch length, 0.15–5 mm row spacing, and 0.5–10 mm satin width.")}
    }
  }
}

public struct EmbroideryCommand:Codable,Equatable,Sendable {
  public enum Action:String,Codable,Sendable {case stitch,jump,trim,colorChange,end}
  public var action:Action
  /// Absolute coordinates in tenths of a millimeter; positive Y follows artwork down.
  public var x:Int
  public var y:Int
  public var threadIndex:Int
  public var regionID:UUID?
  public init(_ action:Action,x:Int,y:Int,threadIndex:Int,regionID:UUID? = nil) {
    self.action=action;self.x=x;self.y=y;self.threadIndex=threadIndex;self.regionID=regionID
  }
  public var point:Point2 {.init(Double(x)/10,Double(y)/10)}
}

public struct EmbroideryProgram:Codable,Equatable,Sendable {
  public var name:String
  public var sourceDigest:String
  public var design:EmbroideryDesign
  public var commands:[EmbroideryCommand]
  public init(name:String,sourceDigest:String,design:EmbroideryDesign,commands:[EmbroideryCommand]) {
    self.name=name;self.sourceDigest=sourceDigest;self.design=design;self.commands=commands
  }
  public var stitchCount:Int {commands.filter {$0.action == .stitch}.count}
  public var threadOrder:[Int] {
    var result:[Int]=[]
    for command in commands {
      if result.isEmpty || command.action == .colorChange {result.append(command.threadIndex)}
    }
    return result
  }
  public var bounds:Rect2 {
    let points=commands.filter {$0.action == .stitch || $0.action == .jump}.map(\.point)
    guard let first=points.first else {return .init(0,0,0,0)}
    return points.dropFirst().reduce(.init(first.x,first.y,0,0)) {$0.union(.init($1.x,$1.y,0,0))}
  }
  public func validate()throws {
    try design.validate()
    guard !commands.isEmpty,commands.count<=200000,commands.last?.action == .end,
      stitchCount>0,stitchCount<=design.maximumStitches else {throw FormError.invalid("The stitch program is empty, unfinished, or exceeds its bounded stitch count.")}
    let limitX=(design.hoopWidth/2-design.margin)*10,limitY=(design.hoopHeight/2-design.margin)*10
    var last=Point2(),ended=false,currentThread=commands[0].threadIndex
    for command in commands {
      guard !ended,design.threads.indices.contains(command.threadIndex),abs(Double(command.x))<=limitX+1e-8,
        abs(Double(command.y))<=limitY+1e-8 else {throw FormError.invalid("Needle movement exceeds the selected hoop's usable area or uses an invalid thread.")}
      if command.action == .colorChange {currentThread=command.threadIndex}
      else if command.threadIndex != currentThread {throw FormError.invalid("A thread change needs an explicit color-change command.")}
      if command.action == .stitch, hypot(Double(command.x)-last.x,Double(command.y)-last.y)>101.5 {
        throw FormError.invalid("A generated stitch is longer than the supported 10 mm limit.")
      }
      if command.action == .trim || command.action == .colorChange || command.action == .end {
        guard Double(command.x)==last.x,Double(command.y)==last.y else {throw FormError.invalid("Thread-control commands must retain the current needle position.")}
      }
      last = .init(Double(command.x),Double(command.y));ended=command.action == .end
    }
  }
}
