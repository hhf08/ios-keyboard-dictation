import AVFoundation
import Speech
import SwiftUI

struct ContentView: View {
    @State private var microphone = AVAudioSession.sharedInstance().recordPermission
    @State private var speech = SFSpeechRecognizer.authorizationStatus()
    @State private var text = ""
    @State private var speechCheck = ""
    @State private var speechTask: SFSpeechRecognitionTask?

    @AppStorage(KeyboardSettings.Key.layout, store: KeyboardSettings.defaults) private var layout = ChineseLayout.t9.rawValue
    @AppStorage(KeyboardSettings.Key.haptics, store: KeyboardSettings.defaults) private var haptics = true
    @AppStorage(KeyboardSettings.Key.micPrewarm, store: KeyboardSettings.defaults) private var micPrewarm = false
    @AppStorage(KeyboardSettings.Key.onDevice, store: KeyboardSettings.defaults) private var onDevice = true
    @AppStorage(KeyboardSettings.Key.inlineCompat, store: KeyboardSettings.defaults) private var inlineCompat = false
    @AppStorage(KeyboardSettings.Key.holdDelay, store: KeyboardSettings.defaults) private var holdDelay = 0.2

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("麦克风", value: microphoneLabel)
                    LabeledContent("语音识别", value: speechLabel)
                    Button("授予权限", action: requestPermissions)
                    Button("在本 App 中测试语音识别", action: checkSpeech)
                    if !speechCheck.isEmpty { Text(speechCheck).font(.footnote) }
                } header: {
                    Text("第一步：授予权限")
                } footer: {
                    Text("语音输入需要麦克风和语音识别两项权限。若之前点了「不允许」，请到 设置 → 语音键盘 中重新打开。")
                }

                Section("第二步：启用键盘") {
                    Text("设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 语音键盘，然后点进「语音键盘」打开「允许完全访问」。")
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    Picker("中文键盘布局", selection: $layout) {
                        Text("九键").tag(ChineseLayout.t9.rawValue)
                        Text("全键盘").tag(ChineseLayout.qwerty.rawValue)
                    }
                    .pickerStyle(.segmented)
                    Toggle("按键震动", isOn: $haptics)
                    Toggle("麦克风预热（会一直占用麦克风）", isOn: $micPrewarm)
                    Toggle("离线识别优先（更快）", isOn: $onDevice)
                    Toggle("语音上屏兼容模式（逐段替换）", isOn: $inlineCompat)
                    Picker("长按空格开始说话", selection: $holdDelay) {
                        Text("0.15 秒").tag(0.15)
                        Text("0.2 秒").tag(0.2)
                        Text("0.3 秒").tag(0.3)
                        Text("0.5 秒").tag(0.5)
                    }
                } header: {
                    Text("键盘设置")
                } footer: {
                    Text("麦克风预热（默认关闭）：开启后键盘弹出时就打开麦克风，键盘显示期间会一直占用麦克风、状态栏显示麦克风指示；每次说完松手后麦克风都会立即释放。关闭时只在按住说话期间使用麦克风，松手即释放。离线识别更快，需系统已下载中文离线模型，不可用时自动改用联网识别。若这里的设置在键盘中没有生效，可点键盘工具栏上的 ⚙︎ 直接修改。")
                }

                Section("语音输入指南") {
                    Label("长按空格键说话，松开结束，文字自动上屏", systemImage: "space")
                    Label("说话时手指上滑可取消本次输入", systemImage: "arrow.up")
                    Label("点工具栏的麦克风开始说话，再点「完成」结束；按住麦克风则松开结束", systemImage: "mic")
                    Label("说话时上方浮窗实时显示识别结果，全程不用跳转到其他 App", systemImage: "text.bubble")
                }

                Section("百度风格键盘说明") {
                    Text("九键：左侧是常用标点，输入时变为拼音选择；「分词」键插入分隔符；⌫ 长按连续删除；「重输」清空拼音；上方候选栏点 ⌄ 展开全部候选。全键盘：字母直接拼音，「分词」键插入 '。英文：⇧ 单击大写一次、双击锁定大写。「123」数字键盘，「符号」中文/英文/表情符号页，「中/英」切换语言。工具栏：语音、剪贴板、九键/全键盘切换、设置、收起键盘。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("第三步：试一试") {
                    TextField("在这里切换到语音键盘试试", text: $text, axis: .vertical)
                        .lineLimit(3...8)
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

    /// Feeds a second of silence to the recognizer to tell a device-wide Speech failure
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
