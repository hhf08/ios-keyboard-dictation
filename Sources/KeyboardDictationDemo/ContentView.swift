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
                Section("第一步：授予权限") {
                    LabeledContent("麦克风", value: microphoneLabel)
                    LabeledContent("语音识别", value: speechLabel)
                    Button("授予权限", action: requestPermissions)
                    Button("在本 App 中测试语音识别", action: checkSpeech)
                    if !speechCheck.isEmpty { Text(speechCheck).font(.footnote) }
                }

                Section("第二步：启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 语音键盘，然后打开「允许完全访问」。")
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("第三步：试一试") {
                    TextField("在这里切换到语音键盘试试", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                    Text("九宫格拼音：按字母键打拼音，点上方候选词上屏，空格选第一个候选，上方一排可选具体拼音。「符号」打开标点符号页（中文、英文、表情），「123」切换数字。长按空格键说普通话，松开即结束，文字自动输入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("语音键盘")
        }
    }

    private var microphoneLabel: String {
        switch microphone {
        case .granted: "已授权"
        case .denied: "已拒绝"
        default: "未请求"
        }
    }

    private var speechLabel: String {
        switch speech {
        case .authorized: "已授权"
        case .denied: "已拒绝"
        case .restricted: "受限制"
        default: "未请求"
        }
    }

    /// Feeds a second of silence to the recognizer to tell a simulator-wide Speech failure
    /// apart from one specific to the keyboard extension sandbox.
    private func checkSpeech() {
        speechCheck = "检测中…"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) else {
            speechCheck = "不支持中文识别"
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
                    speechCheck = "语音识别出错：\(error.localizedDescription)"
                } else if result?.isFinal == true {
                    speechCheck = "语音识别正常。"
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
