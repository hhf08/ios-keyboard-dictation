import AVFoundation
import Speech
import SwiftUI

struct ContentView: View {
    @State private var microphone = AVAudioSession.sharedInstance().recordPermission
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var text = ""
    @State private var speechCheck = ""
    @State private var speechTask: SFSpeechRecognitionTask?

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Permissions") {
                    LabeledContent("Microphone", value: microphoneLabel)
                    LabeledContent("Speech recognition", value: speechLabel)
                    Button("Grant permissions", action: requestPermissions)
                    Button("Check Apple Speech in this app", action: checkSpeech)
                    if !speechCheck.isEmpty { Text(speechCheck).font(.footnote) }
                }

                Section("2. Enable the keyboard") {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → Dictation Demo, then turn on Allow Full Access.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("3. Try it") {
                    TextField("Switch to the Dictation Demo keyboard here", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                    Text("Tap Dictate on the keyboard, speak, then tap Stop. Audio is captured by a hidden WKWebView inside the keyboard, so you never leave this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Keyboard Dictation")
        }
    }

    private var microphoneLabel: String {
        switch microphone {
        case .granted: "Granted"
        case .denied: "Denied"
        default: "Not requested"
        }
    }

    private var speechLabel: String {
        switch speech {
        case .authorized: "Granted"
        case .denied: "Denied"
        case .restricted: "Restricted"
        default: "Not requested"
        }
    }

    /// Feeds a second of silence to the recognizer to tell a simulator-wide Speech failure
    /// apart from one specific to the keyboard extension sandbox.
    private func checkSpeech() {
        speechCheck = "Checking…"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            speechCheck = "No recognizer for en-US"
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        memset(buffer.int16ChannelData![0], 0, 32_000)
        speechTask = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let error {
                    speechCheck = "Speech error: \(error.localizedDescription)"
                } else if result?.isFinal == true {
                    speechCheck = "Speech works in the app."
                }
            }
        }
        request.append(buffer)
        request.endAudio()
    }

    private func requestPermissions() {
        AVAudioSession.sharedInstance().requestRecordPermission { _ in
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async {
                    microphone = AVAudioSession.sharedInstance().recordPermission
                    speech = SFSpeechRecognizer.authorizationStatus()
                }
            }
        }
    }
}
