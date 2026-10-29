import ChangelogKit
import SwiftUI
import VisionKit

/// Sign-in by token, until OAuth comes (Changelog 1.0). The owner makes a
/// token in Release Notes' Settings and pastes it, or scans its QR code.
struct SignInView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openURL) private var openURL
  @State private var pasted = ""
  @State private var problem: String?
  @State private var checking = false
  @State private var scanning = false

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      Form {
        Section {
          Text("Changelog sends notes, and soon photos and dates, into your Release Notes. It can read back only the notes it sent, never the rest.")
          Text("Make a token in Release Notes under Settings, Connections, with Add notes and Activity ticked. Then paste it here or scan its code.")
            .foregroundStyle(.secondary)
        }
        Section {
          SecureField("rn_…", text: $pasted)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .onSubmit { check(pasted) }
          Button("Paste token") {
            if let text = UIPasteboard.general.string { check(text) }
          }
          if DataScannerViewController.isSupported {
            Button("Scan its code") { scanning = true }
          }
        } footer: {
          if let problem { Text(problem).foregroundStyle(.orange) }
        }
        Section {
          Button("Sign in") { check(pasted) }
            .disabled(checking || pasted.isEmpty)
          Button("Open Release Notes Settings") { openURL(Links.settings) }
        }
        #if DEBUG
        Section {
          Picker("Server", selection: $model.server) {
            Text("Release Notes").tag(APIClient.production)
            Text("Dev server").tag(APIClient.devServer)
          }
        } header: {
          Text("Development")
        } footer: {
          Text("The dev server prints a token for its fictional account when it starts.")
        }
        #endif
      }
      .navigationTitle("Changelog")
      .overlay { if checking { ProgressView() } }
      .sheet(isPresented: $scanning) {
        CodeScanner { code in
          scanning = false
          check(code)
        }
        .ignoresSafeArea()
      }
    }
  }

  private func check(_ raw: String) {
    checking = true
    Task {
      problem = await model.signIn(with: raw)
      checking = false
      if problem != nil { pasted = "" }
    }
  }
}

/// The camera, reading one QR code and handing over its text.
struct CodeScanner: UIViewControllerRepresentable {
  let found: (String) -> Void

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                            isHighlightingEnabled: true)
    scanner.delegate = context.coordinator
    try? scanner.startScanning()
    return scanner
  }

  func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (String) -> Void
    private var done = false
    init(found: @escaping (String) -> Void) { self.found = found }

    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      for case .barcode(let code) in items {
        guard !done, let text = code.payloadStringValue, TokenFormat.extract(text) != nil else { continue }
        done = true
        scanner.stopScanning()
        found(text)
      }
    }
  }
}
