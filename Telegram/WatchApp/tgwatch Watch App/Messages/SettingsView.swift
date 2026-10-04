import SwiftUI

/// App settings, opened from the gear on the chat list. Fork only.
struct SettingsView: View {
    @Environment(TDClient.self) private var client
    @State private var speech = SpeechRecognizer.shared
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Picker("Model", selection: $speech.model) {
                    ForEach(SpeechRecognizer.Model.allCases) { model in
                        Text(model.title).tag(model)
                    }
                }
                .disabled(isBusy)
                Picker("Language", selection: $speech.language) {
                    ForEach(SpeechRecognizer.Language.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                status
                actionButton
            } header: {
                Text("Voice transcription")
            } footer: {
                Text("Whisper runs on the watch: voice messages are transcribed without Premium and without sending audio anywhere. Tiny is faster, Base is more accurate.")
            }

            if speech.isDownloaded {
                Section("Try it") {
                    Button {
                        speech.testOnLatestVoiceNote(using: client)
                    } label: {
                        if speech.isTesting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Recognizing…")
                            }
                        } else {
                            Label("Latest voice message", systemImage: "waveform")
                        }
                    }
                    .disabled(speech.isTesting || isBusy)
                    if let result = speech.testResult {
                        Text(result).font(.caption)
                    }
                }
            }

            if !speech.stats.isEmpty {
                Section("Measurements") {
                    ForEach(speech.stats, id: \.self) { line in
                        Text(line).font(.caption2)
                    }
                    Text("Memory now: \(SpeechRecognizer.memoryFootprint())").font(.caption2)
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Delete the \(speech.model.title) model?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { speech.deleteModel() }
        }
    }

    private var isBusy: Bool {
        switch speech.state {
        case .downloading, .loading: return true
        default: return false
        }
    }

    @ViewBuilder
    private var status: some View {
        switch speech.state {
        case .notDownloaded:
            Label("Not downloaded", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading… \(Int(fraction * 100))%")
                ProgressView(value: fraction)
            }
        case .loading:
            HStack {
                ProgressView().controlSize(.small)
                Text("Preparing the model…")
            }
        case .ready:
            Label("Ready · \(speech.downloadedSize ?? "")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if speech.isDownloaded {
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete model", systemImage: "trash")
            }
            .disabled(isBusy)
        } else {
            Button {
                speech.download()
            } label: {
                Label("Download \(speech.model.title)", systemImage: "arrow.down.circle.fill")
            }
            .disabled(isBusy)
        }
    }
}
