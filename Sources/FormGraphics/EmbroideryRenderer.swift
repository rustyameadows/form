import AppKit
import FormCore

@MainActor public enum EmbroideryRenderer {
  /// Draws actual generated commands in millimeters, centered at the hoop origin.
  public static func draw(_ program:EmbroideryProgram,context:CGContext,showJumps:Bool = true,through:Int? = nil) {
    let count=min(program.commands.count,max(0,through ?? program.commands.count))
    var previous=Point2()
    for command in program.commands.prefix(count) {
      let point=command.point
      context.setLineDash(phase:0,lengths:[])
      if command.action == .stitch || command.action == .jump {
        if command.action == .stitch || showJumps {
          let color=FormColor.color(program.design.threads[command.threadIndex].color)
          context.setStrokeColor((command.action == .jump ? NSColor.secondaryLabelColor.withAlphaComponent(0.55):color).cgColor)
          context.setLineWidth(command.action == .jump ? 0.12:(program.design.process?.threadDiameter ?? 0.22))
          if command.action == .jump {context.setLineDash(phase:0,lengths:[0.7,0.5])}
          context.move(to:.init(x:previous.x,y:previous.y));context.addLine(to:.init(x:point.x,y:point.y));context.strokePath()
        }
      } else if command.action == .trim,showJumps {
        context.setStrokeColor(NSColor.systemOrange.cgColor);context.setLineWidth(0.15)
        context.move(to:.init(x:point.x-0.4,y:point.y-0.4));context.addLine(to:.init(x:point.x+0.4,y:point.y+0.4))
        context.move(to:.init(x:point.x-0.4,y:point.y+0.4));context.addLine(to:.init(x:point.x+0.4,y:point.y-0.4));context.strokePath()
      }
      previous=point
    }
    context.setLineDash(phase:0,lengths:[])
  }
  public static func svg(_ program:EmbroideryProgram,showJumps:Bool = true)throws -> String {
    try program.validate()
    func escape(_ value:String)->String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:"\"",with:"&quot;")}
    func number(_ value:Double)->String {String(format:"%.3f",locale:Locale(identifier:"en_US_POSIX"),value)}
    let w=program.design.hoopWidth,h=program.design.hoopHeight
    var result="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(number(w))mm\" height=\"\(number(h))mm\" viewBox=\"\(number(-w/2)) \(number(-h/2)) \(number(w)) \(number(h))\"><title>\(escape(program.name)) — actual needle commands</title>"
    let metadata=String(decoding:try JSONEncoder.form.encode(program),as:UTF8.self)
    result += "<metadata id=\"form-embroidery-program\">\(escape(metadata))</metadata>"
    result += "<rect x=\"\(number(-w/2))\" y=\"\(number(-h/2))\" width=\"\(number(w))\" height=\"\(number(h))\" fill=\"none\" stroke=\"#B0B4B2\" stroke-width=\"0.2\" data-form-role=\"hoop\"/>"
    var previous=Point2()
    for (index,command) in program.commands.enumerated() {
      let point=command.point
      if command.action == .stitch || command.action == .jump && showJumps {
        let jump=command.action == .jump,color=jump ? "#888888":program.design.threads[command.threadIndex].color
        let width=jump ? "0.12":number(program.design.process?.threadDiameter ?? 0.22)
        let purpose=command.purpose.map {" data-purpose=\""+$0.rawValue+"\""} ?? ""
        result += "<path data-command=\"\(command.action.rawValue)\" data-index=\"\(index)\" data-thread=\"\(command.threadIndex)\" d=\"M\(number(previous.x)) \(number(previous.y))L\(number(point.x)) \(number(point.y))\" fill=\"none\" stroke=\"\(escape(color))\" stroke-width=\"\(width)\"\(purpose)\(jump ? " stroke-dasharray=\"0.7 0.5\"":"")/>"
      } else if [.trim,.colorChange,.end].contains(command.action) {
        result += "<g data-command=\"\(command.action.rawValue)\" data-index=\"\(index)\" data-thread=\"\(command.threadIndex)\" data-x=\"\(command.x)\" data-y=\"\(command.y)\"/>"
      }
      previous=point
    }
    return result+"</svg>"
  }
}
