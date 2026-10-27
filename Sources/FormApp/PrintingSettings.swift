import AppKit
import FormCore
import SwiftUI

struct PrintingSettingsView: View {
  @EnvironmentObject var store: StudioStore
  @Environment(\.dismiss) var dismiss
  @ObservedObject var printing: PrintCoordinator
  @State private var tab = "Filaments"
  @State private var selectedFilament: UUID?
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text("The printing studio").font(.system(size: 28, weight: .regular, design: .default))
          Text("Your filaments, your machines, your local workflow.").font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      Picker("Printing settings", selection: $tab) {
        Text("Filament library").tag("Filaments")
        Text("Local printers").tag("Printers")
        Text("Slicing engine").tag("Engine")
      }.pickerStyle(.segmented).labelsHidden()
      if tab == "Filaments" {
        HStack(alignment: .top, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(store.library.filaments) { filament in
              Button {
                selectedFilament = filament.id
              } label: {
                HStack(spacing: 9) {
                  Circle().fill(Color(nsColor: NSColor(hex: filament.color))).frame(
                    width: 21, height: 21)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(filament.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Text("\(filament.polymer) · \(Int(filament.remainingGrams)) g remaining").font(
                      .system(size: 9)
                    ).foregroundStyle(Palette.secondary)
                  }
                  Spacer()
                }.padding(9).background(
                  (selectedFilament ?? store.library.filaments.first?.id) == filament.id
                    ? Color.white : .clear, in: RoundedRectangle(cornerRadius: 8))
              }.buttonStyle(.plain)
            }
            Button {
              let profile = FilamentProfile(name: "New filament")
              store.library.filaments.append(profile)
              store.saveLibrary()
              selectedFilament = profile.id
            } label: {
              Label("Add filament", systemImage: "plus").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(Palette.accent).padding(.top, 10)
          }.frame(width: 230)
          Divider()
          if let profile = store.library.filaments.first(where: { $0.id == selectedFilament })
            ?? store.library.filaments.first
          {
            FilamentEditor(profile: profile).id(profile.id)
          }
        }
      } else if tab == "Printers" {
        PrinterSettingsPanel(printing: printing, monitor: printing.monitor)
      } else {
        EngineSettingsPanel(printing: printing)
      }
      Spacer(minLength: 0)
    }.padding(28).frame(width: 790, height: 620).background(Palette.paper)
  }
}

struct FilamentEditor: View {
  @EnvironmentObject var store: StudioStore
  @State private var draft: FilamentProfile
  @State private var message: String?
  init(profile: FilamentProfile) { _draft = State(initialValue: profile) }
  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      SectionLabel("SPOOL & MATERIAL")
      TextField("Filament name", text: $draft.name).font(
        .system(size: 17, weight: .medium, design: .default)
      ).textFieldStyle(.roundedBorder)
      HStack {
        TextField("Manufacturer", text: $draft.vendor).textFieldStyle(.roundedBorder)
        Picker("Material", selection: $draft.polymer) {
          ForEach(["PLA", "PETG", "ABS", "ASA", "TPU", "PC", "PA"], id: \.self) { Text($0) }
        }.labelsHidden().frame(width: 105)
      }.font(.system(size: 11))
      ColorPicker(
        "Color",
        selection: Binding(
          get: { Color(nsColor: NSColor(hex: draft.color)) },
          set: { draft.color = NSColor($0).hexString }), supportsOpacity: false
      ).font(.system(size: 11))
      HStack {
        PrintNumber("Diameter", value: $draft.diameter, unit: "mm", range: 1.5...3)
        PrintNumber("Density", value: $draft.density, unit: "g/cc", range: 0.5...3)
      }
      Divider()
      SectionLabel("PRINT PROFILE")
      HStack {
        PrintNumber("Nozzle", value: $draft.nozzleTemperature, unit: "°C", range: 150...320)
        PrintNumber("Bed", value: $draft.bedTemperature, unit: "°C", range: 0...120)
      }
      PrintNumber(
        "Max volumetric flow", value: $draft.maxVolumetricSpeed, unit: "mm³/s", range: 1...50)
      Divider()
      SectionLabel("STUDIO INVENTORY")
      HStack {
        PrintNumber("Remaining", value: $draft.remainingGrams, unit: "g", range: 0...10000)
        PrintNumber("Cost / kg", value: $draft.costPerKg, unit: "$", range: 0...1000)
      }
      TextField("Notes, supplier, finish, drying preferences…", text: $draft.notes, axis: .vertical)
        .lineLimit(2...3).textFieldStyle(.roundedBorder).font(.system(size: 11))
      HStack {
        if let message { Text(message).font(.system(size: 10)).foregroundStyle(Palette.accent) }
        Spacer()
        Button("Save filament") {
          do {
            try draft.validate()
            if let index = store.library.filaments.firstIndex(where: { $0.id == draft.id }) {
              store.library.filaments[index] = draft
            }
            store.saveLibrary()
            message = "Saved to LAB Library"
          } catch { message = error.localizedDescription }
        }.buttonStyle(.borderedProminent).tint(Palette.ink)
      }
    }.frame(maxWidth: .infinity)
  }
}

struct PrinterSettingsPanel: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var printing: PrintCoordinator
  @ObservedObject var monitor: BambuMonitor
  @State private var draft = PrinterProfile()
  @State private var code = ""
  @State private var message: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 17) {
      HStack {
        SectionLabel("BAMBU LAB · LOCAL CONNECTION")
        Spacer()
        Label(
          monitor.connected ? "Connected" : "Not connected",
          systemImage: monitor.connected ? "checkmark.circle.fill" : "circle.dotted"
        ).font(.system(size: 11)).foregroundStyle(
          monitor.connected ? Palette.ink : Palette.secondary)
      }
      HStack {
        TextField("Printer name", text: $draft.name).textFieldStyle(.roundedBorder)
        Picker(
          "Saved printer",
          selection: Binding(
            get: { draft.id },
            set: { id in
              if let printer = store.library.printers.first(where: { $0.id == id }) {
                draft = printer
                code = ""
              }
            })
        ) { ForEach(store.library.printers) { Text($0.name).tag($0.id) } }.labelsHidden().frame(
          width: 200)
      }
      HStack {
        LabeledField("Local IP or hostname", text: $draft.host, prompt: "192.168.1.100")
        LabeledField(
          "Printer serial number", text: $draft.serial, prompt: "From the printer's Device settings"
        )
      }
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 7) {
          Text("LAN access code").font(.system(size: 10, weight: .medium))
          SecureField(
            PrinterCredentials.read(draft.id) == nil
              ? "8-character code from printer" : "Saved in Keychain · enter to replace",
            text: $code
          ).textFieldStyle(.roundedBorder)
        }
        Picker("Nozzle", selection: $draft.nozzleDiameter) {
          ForEach([0.2, 0.4, 0.6, 0.8], id: \.self) { Text(String(format: "%.1f mm", $0)).tag($0) }
        }.font(.system(size: 11)).frame(width: 150)
      }
      HStack {
        Text("Build volume: 256 × 256 × 256 mm").font(.system(size: 11, design: .monospaced))
          .foregroundStyle(Palette.secondary)
        Spacer()
        Picker("Plate", selection: $draft.plate) {
          Text("Textured PEI Plate").tag("Textured PEI Plate")
          Text("Smooth PEI Plate / High Temp Plate").tag("High Temp Plate")
        }.labelsHidden().frame(width: 230)
      }
      HStack {
        Button("Save printer") { save() }
        Button("Test local connection") {
          if save() {
            printing.updateConfiguration { $0.printerID = draft.id }
            printing.connectPrinter()
          }
        }
        if monitor.connected { Button("Disconnect") { monitor.disconnect() } }
        Spacer()
        Button("Add another P1S") {
          let value = PrinterProfile()
          store.library.printers.append(value)
          store.saveLibrary()
          draft = value
          code = ""
        }
      }
      if let message { Text(message).font(.system(size: 11)).foregroundStyle(Palette.accent) }
      Divider()
      HStack(spacing: 28) {
        PrinterReadout(title: "NOZZLE", value: monitor.report["nozzle_temper"], suffix: "°C")
        PrinterReadout(title: "BED", value: monitor.report["bed_temper"], suffix: "°C")
        PrinterReadout(title: "PROGRESS", value: monitor.report["mc_percent"], suffix: "%")
        Spacer()
      }
      Text(monitor.status).font(.system(size: 11)).foregroundStyle(Palette.secondary)
      if let fingerprint = monitor.pendingFingerprint {
        VStack(alignment: .leading, spacing: 8) {
          Text("Verify this printer's certificate fingerprint before trusting it:").font(
            .system(size: 11))
          Text(fingerprint).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
          Button("Trust this certificate & reconnect") {
            draft.trustedCertificateSHA256 = fingerprint
            if save() {
              printing.updateConfiguration { $0.printerID = draft.id }
              printing.connectPrinter()
            }
          }.font(.system(size: 11))
        }.padding(12).background(
          Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      }
      Text(
        "Use the IP, serial, and LAN access code shown by your printer. Available LAN features depend on firmware and network mode. LAB receives status over TLS; it does not upload files, heat, move, calibrate, or start prints in this build."
      ).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
    }.onAppear {
      draft =
        store.library.printers.first { $0.id == printing.configuration.printerID } ?? store.library
        .printers.first ?? .init()
    }
  }
  @discardableResult private func save() -> Bool {
    do {
      try draft.validate()
      if !code.isEmpty {
        try PrinterCredentials.save(code, printerID: draft.id)
        code = ""
      }
      if let i = store.library.printers.firstIndex(where: { $0.id == draft.id }) {
        store.library.printers[i] = draft
      } else {
        store.library.printers.append(draft)
      }
      store.saveLibrary()
      message = "Printer settings saved. Access code stays in Keychain."
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
}

struct LabeledField: View {
  let title: String
  @Binding var text: String
  let prompt: String
  init(_ title: String, text: Binding<String>, prompt: String) {
    self.title = title
    _text = text
    self.prompt = prompt
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.system(size: 10, weight: .medium))
      TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
    }
  }
}
struct PrinterReadout: View {
  let title: String
  let value: Any?
  let suffix: String
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title)
      Text(verbatim: value.map { String(describing: $0) + suffix } ?? "—").font(
        .system(size: 24, weight: .regular, design: .default))
    }
  }
}

struct EngineSettingsPanel: View {
  @EnvironmentObject var store: StudioStore
  @ObservedObject var printing: PrintCoordinator
  var body: some View {
    VStack(alignment: .leading, spacing: 21) {
      HStack(spacing: 13) {
        Image(systemName: "square.3.layers.3d").font(.system(size: 29, weight: .light))
          .foregroundStyle(Palette.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text("OrcaSlicer, inside your workflow.").font(
            .system(size: 22, weight: .regular, design: .default))
          Text("Native LAB controls. Real local Orca slicing.").font(.system(size: 12))
            .foregroundStyle(Palette.secondary)
        }
      }
      Divider()
      if let engine = printing.engineURL {
        Label(
          "Engine available · \(OrcaEngine.version(engine))", systemImage: "checkmark.circle.fill"
        ).foregroundStyle(Palette.ink).font(.system(size: 12))
        Text(engine.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          .foregroundStyle(Palette.secondary)
      } else {
        Label("Choose an OrcaSlicer app to enable slicing", systemImage: "circle.dotted").font(
          .system(size: 12))
      }
      Button("Locate OrcaSlicer.app…") {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
          if FileManager.default.isExecutableFile(
            atPath: url.appendingPathComponent("Contents/MacOS/OrcaSlicer").path)
          {
            store.library.orcaAppPath = url.path
            store.saveLibrary()
            printing.objectWillChange.send()
          } else {
            store.error = "Choose the official OrcaSlicer application bundle."
          }
        }
      }
      Text(
        "LAB resolves the engine's printer, process, and filament presets, then prepares your selected component and slices it on this Mac. The layer preview, estimates, STL, G-code, and 3MF remain local."
      ).font(.system(size: 13)).foregroundStyle(Palette.secondary).lineSpacing(5)
      Text(
        "OrcaSlicer is a separate AGPL-3.0 application. Its code and networking plugin are not linked into LAB. Local development uses the checksum-verified official 2.4.2 release; compatible installations can be selected here."
      ).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineSpacing(3)
      Link(
        "Official OrcaSlicer releases",
        destination: URL(string: "https://github.com/OrcaSlicer/OrcaSlicer/releases")!
      ).font(.system(size: 12)).tint(Palette.accent)
      Text("Preparation mode: no files are uploaded and no print jobs can be sent.").font(
        .system(size: 11, weight: .medium)
      ).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
        .white, in: RoundedRectangle(cornerRadius: 9))
    }.padding(.top, 10)
  }
}
