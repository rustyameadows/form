import Combine
import Foundation
import FormCore

/// Shared project-scoped prompt storage for Canvas and Studio. Browsing never
/// rewrites legacy files, and a read failure cannot replace recoverable bytes.
@MainActor final class ImageGenerationPromptLibrary:ObservableObject {
  let projectID:UUID
  let file:URL
  @Published private(set) var savedPresets:[StudioGenerationPromptPreset]=[]
  @Published private(set) var error:String?
  static let didChange=Notification.Name("LAB.ImageGenerationPromptsDidChange")
  private static let maximumBytes=2*1024*1024
  private var observation:AnyCancellable?
  init(root:URL,projectID:UUID) {
    self.projectID=projectID
    file=root.appendingPathComponent("StudioAssets/GenerationPrompts").appendingPathComponent(projectID.uuidString+".json")
    reload()
    observation=NotificationCenter.default.publisher(for:Self.didChange).sink { [weak self] notification in
      guard let self,notification.userInfo?["projectID"] as? UUID==self.projectID,
        (notification.object as? ImageGenerationPromptLibrary) !== self else{return}
      self.reload()
    }
  }
  func reload() {
    do {savedPresets=try read();error=nil}
    catch {self.error="The project prompt preset file could not be read. Its existing bytes were preserved. "+error.localizedDescription}
  }
  func presets(including builtins:[StudioGenerationPromptPreset])->[StudioGenerationPromptPreset] {
    let ids=Set(savedPresets.map(\.id))
    return builtins.filter{builtin in !ids.contains(builtin.id) && !savedPresets.contains{$0.name.caseInsensitiveCompare(builtin.name) == .orderedSame}}+savedPresets
  }
  @discardableResult func save(name:String,prompt:String)throws->StudioGenerationPromptPreset {
    let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
    guard Self.valid(name:name,prompt:prompt) else {
      throw StudioGenerationError.invalid("Save a named prompt of up to 8,000 characters; names can contain up to 80 characters.")
    }
    // Re-read before every mutation: another surface may have saved a prompt
    // since this observable snapshot was constructed.
    var values=try read()
    let preset:StudioGenerationPromptPreset
    if let index=values.firstIndex(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame}) {
      values[index].prompt=prompt;preset=values[index]
    } else {
      guard values.count<32 else{throw StudioGenerationError.invalid("Keep up to 32 saved project prompts.")}
      // A user explicitly saving an unchanged builtin gets a fresh identity,
      // so it remains distinguishable from defaults embedded by legacy files.
      preset = .init(id:UUID(),name:name,prompt:prompt);values.append(preset)
    }
    try write(values);return preset
  }
  func remove(id:UUID)throws {
    var values=try read()
    guard values.contains(where:{$0.id==id}) else{throw StudioGenerationError.invalid("That saved prompt is no longer in this project.")}
    values.removeAll{$0.id==id};try write(values)
  }
  private static func valid(name:String,prompt:String)->Bool {
    !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count<=80 && name.utf8.count<=320
      && !prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && prompt.count<=8000 && prompt.utf8.count<=32_000
  }
  private func read()throws->[StudioGenerationPromptPreset] {
    guard FileManager.default.fileExists(atPath:file.path) else{return []}
    guard let size=try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size<=Self.maximumBytes else {
      throw StudioGenerationError.invalid("The project prompt file exceeds 2 MiB.")
    }
    let data=try Data(contentsOf:file)
    guard data.count<=Self.maximumBytes else{throw StudioGenerationError.invalid("The project prompt file exceeds 2 MiB.")}
    let values=try JSONDecoder.form.decode([StudioGenerationPromptPreset].self,from:data)
    guard values.count<=32,Set(values.map(\.id)).count==values.count,
      values.allSatisfy({Self.valid(name:$0.name,prompt:$0.prompt)}) else {
      throw StudioGenerationError.invalid("The project prompt file contains invalid or duplicated entries.")
    }
    // Older Studio files included unchanged builtins. They remain available in
    // Studio without appearing as user-saved Canvas prompts or needing a write.
    return values.filter{!StudioGenerationPromptPreset.builtins.contains($0)}
  }
  private func write(_ values:[StudioGenerationPromptPreset])throws {
    guard values.count<=32,Set(values.map(\.id)).count==values.count,
      values.allSatisfy({Self.valid(name:$0.name,prompt:$0.prompt)}) else{throw StudioGenerationError.invalid("The prompt collection is invalid.")}
    let data=try JSONEncoder.form.encode(values)
    guard data.count<=Self.maximumBytes else{throw StudioGenerationError.invalid("The project prompt file exceeds 2 MiB.")}
    try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:file,options:.atomic)
    savedPresets=values;error=nil
    NotificationCenter.default.post(name:Self.didChange,object:self,userInfo:["projectID":projectID])
  }
}
