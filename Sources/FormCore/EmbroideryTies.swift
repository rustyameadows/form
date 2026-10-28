import Foundation

/// Backtracking locks follow an existing stitched segment. They never invent a
/// new route through the fabric, and are opt-in rather than machine defaults.
public enum EmbroideryTies {
  public static func applying(to program:EmbroideryProgram)throws -> EmbroideryProgram {
    guard let process=program.design.process,process.tieIn || process.tieOff else {return program}
    try program.validate()
    var result=program,resultCommands:[EmbroideryCommand]=[],previous=Point2(),lastSegment:(Point2,Point2)?,lastNeedle:EmbroideryCommand?,needsTieIn=true,hasNeedle=false
    func append(_ command:EmbroideryCommand)throws {
      guard resultCommands.count<200000 else {throw FormError.invalid("Tie stitches exceed the 200000-command budget.")}
      resultCommands.append(command)
    }
    func lock(_ anchor:Point2,toward:Point2,source:EmbroideryCommand,purpose:EmbroideryCommand.Purpose)throws {
      let dx=toward.x-anchor.x,dy=toward.y-anchor.y,length=hypot(dx,dy)
      guard length>0 else {return}
      let ratio=min(1,process.tieLength*10/length)
      let x=Int((anchor.x+dx*ratio).rounded(.toNearestOrEven)),y=Int((anchor.y+dy*ratio).rounded(.toNearestOrEven))
      guard x != Int(anchor.x) || y != Int(anchor.y) else {throw FormError.invalid("A tie cannot be represented on the 0.1 mm needle grid.")}
      for _ in 0..<process.tieRepeats {
        try append(.init(.stitch,x:x,y:y,threadIndex:source.threadIndex,regionID:source.regionID,purpose:purpose))
        try append(.init(.stitch,x:Int(anchor.x),y:Int(anchor.y),threadIndex:source.threadIndex,regionID:source.regionID,purpose:purpose))
      }
    }
    for (index,command) in program.commands.enumerated() {
      let point=Point2(Double(command.x),Double(command.y))
      if command.action == .stitch {
        try append(command)
        if previous != point {lastSegment=(previous,point)}
        lastNeedle=command
        hasNeedle=true
        if needsTieIn,process.tieIn {
          var candidate:Point2?
          for next in program.commands.dropFirst(index+1) {
            guard next.action == .stitch else {break}
            if next.x != command.x || next.y != command.y {candidate = .init(Double(next.x),Double(next.y));break}
          }
          if let candidate {try lock(point,toward:candidate,source:command,purpose:.tieIn);needsTieIn=false}
        }
      } else {
        if [.trim,.colorChange,.end].contains(command.action) {
          if hasNeedle,process.tieIn,needsTieIn {throw FormError.invalid("A requested tie-in has no nonzero stitch segment to follow. Enlarge or remove the point-only source.")}
          if hasNeedle,process.tieOff,lastSegment==nil {throw FormError.invalid("A requested tie-off has no nonzero stitch segment to follow. Enlarge or remove the point-only source.")}
          if hasNeedle,process.tieOff,let (start,end)=lastSegment,end==point,let lastNeedle {
            try lock(point,toward:start,source:lastNeedle,purpose:.tieOff)
          }
          needsTieIn=true;hasNeedle=false;lastSegment=nil
        }
        try append(command)
      }
      previous=point
    }
    result.commands=resultCommands
    try result.validate();return result
  }
}
