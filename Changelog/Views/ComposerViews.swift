import ChangelogKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Photos, the camera, a voice memo and Here, beside Commit. The file
/// buttons show only for a token that can add files.
struct ComposerTools: View {
  @Environment(AppModel.self) private var model
  @State private var picks: [PhotosPickerItem] = []
  @State private var camera = false
  @State private var recording = false

  var body: some View {
    // Each button a 44-point square to tap, which keeps the symbols about
    // as far apart as the 18 points between them did.
    HStack(spacing: 0) {
      if model.canAddFiles {
        Group {
          PhotosPicker(selection: $picks, maxSelectionCount: max(1, model.roomForFiles), matching: .images,
                       preferredItemEncoding: .compatible) {
            Image(systemName: "photo.on.rectangle").tappable()
          }
          .accessibilityLabel("Add photos")
          Button { camera = true } label: { Image(systemName: "camera").tappable() }
            .accessibilityLabel("Take a photo")
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
          Button { recording = true } label: { Image(systemName: "mic").tappable() }
            .accessibilityLabel("Record a voice memo")
        }
        .disabled(model.roomForFiles == 0)
      }
      if model.locating {
        ProgressView().tappable().accessibilityLabel("Finding where you are")
      } else {
        Button { Task { await model.locate() } } label: {
          Image(systemName: model.placeLabel == nil ? "location" : "location.fill").tappable()
        }
        .accessibilityLabel(model.placeLabel == nil ? "Add where I am" : "Find where I am again")
      }
    }
    .buttonStyle(.borderless)
    .font(.title3)
    .onChange(of: picks) { _, items in
      guard !items.isEmpty else { return }
      picks = []
      Task {
        for item in items { await model.addPhoto(try? await item.loadTransferable(type: Data.self)) }
      }
    }
    .fullScreenCover(isPresented: $camera) {
      CameraView { data in
        camera = false
        if let data { Task { await model.addPhoto(data) } }
      }
      .ignoresSafeArea()
    }
    .sheet(isPresented: $recording) {
      RecorderView().presentationDetents([.medium])
    }
  }
}

/// The draft's files, each with a way to take it off.
struct AttachmentStrip: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(model.draftFiles) { file in
          ZStack(alignment: .topTrailing) {
            Group {
              if let thumbnail = model.thumbnails[file.id] {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
              } else {
                Image(systemName: file.isRecording ? "waveform" : "doc")
                  .font(.title2)
                  .foregroundStyle(.secondary)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .background(.quaternary)
              }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 8))
            Button { model.remove(file) } label: {
              Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .padding(2)
            .accessibilityLabel("Take off \(file.name)")
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel(file.name)
        }
      }
    }
  }
}

/// The draft's place: the neighbourhood or city, a business nearby to pick,
/// or none.
struct PlaceMenu: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    if let label = model.placeLabel {
      Menu {
        if let here = model.here {
          Picker("Place", selection: Binding(get: { model.venue }, set: { model.pick(venue: $0) })) {
            Text(here.place.district.map { "\($0), \(here.place.name)" } ?? here.place.name).tag(String?.none)
            ForEach(here.nearby, id: \.self) { nearby in
              Text(nearby.name).tag(Optional(nearby.name))
            }
          }
        } else {
          Text("Named when it sends")
        }
        Button("Leave the place off", systemImage: "location.slash", role: .destructive) { model.clearPlace() }
      } label: {
        Label(label, systemImage: "location.fill").lineLimit(1)
      }
      .font(.caption)
      .buttonStyle(.borderless)
      .accessibilityLabel("Place: \(label)")
    }
  }
}

/// The camera, for one photo. The photo comes back as a JPEG with the
/// camera's metadata (the moment it was taken).
struct CameraView: UIViewControllerRepresentable {
  let done: (Data?) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(done: done) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    let done: (Data?) -> Void

    init(done: @escaping (Data?) -> Void) { self.done = done }

    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      let image = info[.originalImage] as? UIImage
      done(image.flatMap { Self.jpeg($0, metadata: info[.mediaMetadata] as? [String: Any]) })
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }

    static func jpeg(_ image: UIImage, metadata: [String: Any]?) -> Data? {
      guard let cgImage = image.cgImage else { return image.jpegData(compressionQuality: 0.85) }
      let out = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
        return nil
      }
      var properties = metadata ?? [:]
      properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation(image.imageOrientation).rawValue
      properties[kCGImageDestinationLossyCompressionQuality as String] = 0.85
      CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
      return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
  }
}

private extension CGImagePropertyOrientation {
  init(_ orientation: UIImage.Orientation) {
    switch orientation {
    case .up: self = .up
    case .down: self = .down
    case .left: self = .left
    case .right: self = .right
    case .upMirrored: self = .upMirrored
    case .downMirrored: self = .downMirrored
    case .leftMirrored: self = .leftMirrored
    case .rightMirrored: self = .rightMirrored
    @unknown default: self = .up
    }
  }
}

/// A voice memo, recording from the moment it opens.
struct RecorderView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var recorder = Recorder()

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        switch recorder.state {
        case .denied:
          Text("The microphone is off for Changelog. Allow it in the Settings app to record a voice memo.")
            .multilineTextAlignment(.center)
        case .failed:
          Text("This phone couldn't record just now.")
        case .idle, .recording:
          TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .minuteSecond)))
              .font(.system(.largeTitle, design: .monospaced))
              .accessibilityLabel("Recording")
          }
          Button {
            if let data = recorder.finish() { Task { await model.addRecording(data) } }
            dismiss()
          } label: {
            Label("Add to the note", systemImage: "stop.circle.fill").font(.title3)
          }
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(recorder.state != .recording)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .navigationTitle("Voice memo")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            recorder.cancel()
            dismiss()
          }
        }
      }
      .task { await recorder.start() }
      .onDisappear { recorder.cancel() }
      .interactiveDismissDisabled(recorder.state == .recording)
    }
  }
}

private extension View {
  /// At least the 44 points square Apple asks a tap target to be, all of it
  /// tappable, the symbol in the middle.
  nonisolated func tappable() -> some View {
    frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
  }
}
