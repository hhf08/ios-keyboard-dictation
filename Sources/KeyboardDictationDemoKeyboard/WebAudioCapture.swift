import UIKit
import WebKit

/// Captures microphone audio from inside a keyboard extension by running `getUserMedia`
/// in a hidden `WKWebView`. WebKit performs the capture in its own processes, which avoids
/// the keyboard-process audio restrictions that break `AVAudioEngine` / `AudioQueue`, so the
/// user never has to jump to another app (免跳转).
///
/// For instant start the stream can be pre-warmed (`warm()`): the microphone stays open while
/// the keyboard is visible, the last ~300 ms are kept in a ring buffer, and `start()` only flips
/// a flag and flushes that pre-roll — so the first syllable is never lost.
///
/// Emits 16 kHz mono Int16 PCM chunks through `onAudio`.
@MainActor
final class WebAudioCapture: NSObject {
    static let sampleRate: Double = 16_000

    var onReady: (() -> Void)?
    var onStarted: (() -> Void)?
    var onAudio: ((Data, Float) -> Void)?
    var onEnded: ((String) -> Void)?

    private(set) var isReady = false
    private(set) var isCapturing = false
    private(set) var isWarm = false
    private var wantsWarm = false
    private let webView: WKWebView
    private var heartbeat: Timer?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "capture")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
    }

    /// The web view must live in the keyboard's view hierarchy for WebKit to capture.
    func attach(to view: UIView) {
        view.addSubview(webView)
        view.sendSubviewToBack(webView)
        load()
    }

    private func load() {
        // https base URL gives the page a secure context, which getUserMedia requires.
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://keyboard-dictation.invalid/"))
    }

    /// Opens the microphone ahead of time so `start()` is instantaneous.
    func warm() {
        wantsWarm = true
        updateHeartbeat()
        guard isReady else { return }
        webView.evaluateJavaScript("warmCapture(); 0", completionHandler: nil)
    }

    /// Releases a pre-warmed microphone.
    func cool() {
        wantsWarm = false
        isWarm = false
        if isReady { webView.evaluateJavaScript("coolCapture(); 0", completionHandler: nil) }
        updateHeartbeat()
    }

    @discardableResult
    func start() -> Bool {
        guard isReady else { return false }
        guard !isCapturing else { return true }
        isCapturing = true
        updateHeartbeat()
        webView.evaluateJavaScript("startCapture(); 0") { [weak self] _, error in
            if let error {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.finish(reason: "start failed: \(message)") }
            }
        }
        return true
    }

    func stop() {
        guard isCapturing else { return }
        webView.evaluateJavaScript("stopCapture(); 0", completionHandler: nil)
        finish(reason: "stopped")
    }

    func tearDown() {
        stop()
        cool()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "capture")
        webView.removeFromSuperview()
    }

    private func finish(reason: String) {
        guard isCapturing else { return }
        isCapturing = false
        updateHeartbeat()
        onEnded?(reason)
    }

    private func updateHeartbeat() {
        let needed = isCapturing || wantsWarm
        if needed, heartbeat == nil {
            let timer = Timer(timeInterval: 1, target: self, selector: #selector(beat), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            heartbeat = timer
            beat()
        } else if !needed {
            heartbeat?.invalidate()
            heartbeat = nil
        }
    }

    @objc private func beat() {
        guard isReady else { return }
        webView.evaluateJavaScript("captureHeartbeat(); 0", completionHandler: nil)
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            beat()
            if wantsWarm { warm() }
            onReady?()
        case "warm":
            isWarm = true
        case "warmFailed", "cooled":
            isWarm = false
        case "started":
            onStarted?()
        case "audio":
            guard isCapturing, let base64 = message["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            onAudio?(data, (message["rms"] as? NSNumber)?.floatValue ?? 0)
        case "interrupted", "failed":
            isWarm = false
            finish(reason: "\(type): \(message["reason"] as? String ?? "unknown")")
        default:
            break
        }
    }

    private static let page = """
    <!doctype html><html><body><script>
    const targetRate = \(Int(sampleRate));
    const PREROLL = Math.round(targetRate * 0.3);
    const post = message => window.webkit.messageHandlers.capture.postMessage(message);
    const encode = samples => {
      const bytes = new Uint8Array(samples.buffer, samples.byteOffset, samples.length * 2);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      return btoa(binary);
    };
    let lastHeartbeat = performance.now();
    window.captureHeartbeat = () => { lastHeartbeat = performance.now(); };
    let live = null, acquiring = null, warm = false, forwarding = false;
    let ring = [], ringSamples = 0;
    const release = () => {
      const l = live; live = null;
      ring = []; ringSamples = 0;
      if (!l) return;
      clearInterval(l.watchdog);
      if (l.processor) { l.processor.onaudioprocess = null; l.processor.disconnect(); }
      if (l.source) l.source.disconnect();
      if (l.sink) l.sink.disconnect();
      if (l.stream) l.stream.getTracks().forEach(t => t.stop());
      if (l.context) l.context.close().catch(() => {});
      try { if (navigator.audioSession) navigator.audioSession.type = 'auto'; } catch (_) {}
    };
    const lost = reason => {
      if (!live) return;
      release();
      const wasForwarding = forwarding;
      forwarding = false; warm = false;
      post({ type: wasForwarding ? 'interrupted' : 'cooled', reason });
    };
    const acquire = () => {
      if (live) return Promise.resolve();
      if (acquiring) return acquiring;
      acquiring = (async () => {
        const audioSession = navigator.audioSession;
        try { if (audioSession) audioSession.type = 'play-and-record'; } catch (_) {}
        const stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        });
        if (!warm && !forwarding) { stream.getTracks().forEach(t => t.stop()); return; }
        const l = { stream };
        live = l;
        try {
          stream.getAudioTracks()[0].onended = () => { if (live === l) lost('track-ended'); };
          // Created only once capture is wanted: an AudioContext can take audio focus.
          const context = new AudioContext({ latencyHint: 'interactive' });
          l.context = context;
          await context.resume();
          if (live !== l) return;
          const processor = context.createScriptProcessor(1024, 1, 1);
          const sink = context.createGain();
          sink.gain.value = 0;
          processor.connect(sink);
          sink.connect(context.destination);
          const source = context.createMediaStreamSource(stream);
          source.connect(processor);
          l.processor = processor; l.sink = sink; l.source = source;
          context.onstatechange = () => { if (live === l && context.state !== 'running') lost('context-' + context.state); };
          if (audioSession) audioSession.onstatechange = () => { if (live === l && audioSession.state === 'interrupted') lost('audio-session-interrupted'); };
          lastHeartbeat = performance.now();
          l.watchdog = setInterval(() => { if (performance.now() - lastHeartbeat > 3000) lost('native-heartbeat-expired'); }, 500);
          const step = context.sampleRate / targetRate;
          let position = 0, sum = 0, count = 0;
          processor.onaudioprocess = event => {
            const input = event.inputBuffer.getChannelData(0);
            const output = new Int16Array(Math.ceil(input.length / step) + 1);
            let written = 0, energy = 0;
            for (const sample of input) {
              energy += sample * sample; sum += sample; count += 1; position += 1;
              if (position >= step) {
                position -= step;
                output[written++] = Math.max(-1, Math.min(1, sum / count)) * 32767;
                sum = 0; count = 0;
              }
            }
            if (written === 0) return;
            const chunk = output.slice(0, written);
            const rms = Math.sqrt(energy / input.length);
            if (forwarding) {
              post({ type: 'audio', data: encode(chunk), rms });
            } else if (warm) {
              ring.push({ chunk, rms }); ringSamples += chunk.length;
              while (ring.length > 1 && ringSamples - ring[0].chunk.length >= PREROLL) ringSamples -= ring.shift().chunk.length;
            }
          };
        } catch (error) {
          if (live === l) release();
          throw error;
        }
      })().finally(() => { acquiring = null; });
      return acquiring;
    };
    window.warmCapture = async () => {
      warm = true;
      try { await acquire(); if (live) post({ type: 'warm' }); }
      catch (error) { warm = false; post({ type: 'warmFailed', reason: error.name + ': ' + error.message }); }
    };
    window.coolCapture = () => { warm = false; if (!forwarding) release(); };
    window.startCapture = async () => {
      forwarding = true;
      try {
        await acquire();
        if (!forwarding) { if (!warm) release(); return; }
        if (!live) throw new Error('microphone unavailable');
        for (const c of ring) post({ type: 'audio', data: encode(c.chunk), rms: c.rms });
        ring = []; ringSamples = 0;
        post({ type: 'started', sampleRate: live.context ? live.context.sampleRate : 0 });
      } catch (error) {
        forwarding = false;
        if (!warm) release();
        post({ type: 'failed', reason: error.name + ': ' + error.message });
      }
    };
    window.stopCapture = () => { forwarding = false; ring = []; ringSamples = 0; if (!warm) release(); };
    post({ type: 'ready' });
    </script></body></html>
    """
}

extension WebAudioCapture: WKUIDelegate, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        isWarm = false
        finish(reason: "web content process terminated")
        load()
    }
}

/// Breaks the retain cycle between `WKUserContentController` and its handler.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebAudioCapture?
    init(_ target: WebAudioCapture) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.handle(message.body) }
    }
}
