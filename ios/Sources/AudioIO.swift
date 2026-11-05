import AVFoundation

/// 麦克风 → 16k PCM16 发给电脑；电脑来的 24k PCM16 → 扬声器/听筒。
final class AudioIO {
    var onMic: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var muted = false            // 静音：照样发帧，但全是 0，电脑那头就当她没说话
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var pending = Data()          // 引擎没起来之前先攒着，起来再播，开头那句不丢
    private let q = DispatchQueue(label: "cc.audio")

    private final class Once { var used = false }

    init() {
        engine.attach(player)
    }

    func start() { q.async { self._start() } }
    func stop() { q.async { self._stop() } }

    /// 她打断我的时候：把排队的我的声音清掉。
    func flush() {
        q.async {
            self.pending.removeAll()
            if self.isRunning {
                self.player.stop()
                self.player.play()
            }
        }
    }

    private func _start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        // 回声消除：不开的话听筒/外放里我的声音会被麦克风收回去。要在读格式之前开，开完格式会变。
        try? input.setVoiceProcessingEnabled(true)
        let inFmt = input.outputFormat(forBus: 0)
        // 麦克风没权限时 inFmt 是 0Hz/0 声道：那就只放不收，至少她能听见我（1105 第一通两边都哑，怀疑是这个）
        if inFmt.sampleRate > 0, inFmt.channelCount > 0, let conv = AVAudioConverter(from: inFmt, to: micFormat) {
            if inFmt.channelCount > 1 { conv.channelMap = [0] }
            converter = conv
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
                self?.convertAndSend(buf)
            }
        } else {
            converter = nil
            print("麦克风不可用，只放不收")
        }
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            // 多半是 session 没激活（CallKit 没来 didActivate）。自己激活一次再试。
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
            try? s.setActive(true)
            do { try engine.start() } catch {
                onError?("音频起不来：\(error.localizedDescription)")
                return
            }
        }
        player.play()
        isRunning = true
        onError?(converter == nil ? "只放不收（没麦克风）" : "音频通了")
        drainPending()
    }

    private func _stop() {
        guard isRunning else { return }
        if converter != nil { engine.inputNode.removeTap(onBus: 0) }
        player.stop()
        engine.stop()
        isRunning = false
        pending.removeAll()
    }

    private func convertAndSend(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = micFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        let once = Once()
        var err: NSError?
        _ = converter.convert(to: out, error: &err) { _, status in
            if once.used { status.pointee = .noDataNow; return nil }
            once.used = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength) * 2
        onMic?(muted ? Data(count: n) : Data(bytes: ch[0], count: n))
    }

    func play(pcm24k data: Data) {
        q.async {
            self.pending.append(data)
            if self.isRunning { self.drainPending() }
        }
    }

    private func drainPending() {
        let n = pending.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        let dst = buf.floatChannelData![0]
        pending.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                dst[i] = Float(Int16(littleEndian: v)) / 32768.0
            }
        }
        pending.removeFirst(n * 2)
        player.scheduleBuffer(buf, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}

/// 后台不被系统挂起：循环放一段无声。开着"保持连接"的时候一直放。
/// 免费账号没有 PushKit，App 被划掉就醒不了，这是唯一的保活法。
final class KeepAlive {
    private var player: AVAudioPlayer?
    private var wanted = false
    private var paused = false           // 通话中让位了，别让打断恢复把通话的 session 冲掉
    private var observer: NSObjectProtocol?

    func start() {
        wanted = true
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                // 真电话、Siri、闹钟打断完了，把无声再放起来
                guard let self, self.wanted, !self.paused,
                      let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self.resume()
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }   // 先把麦克风权限要了，别等到电话里才弹
        resume()
    }

    /// 通话结束后 CallKit 会把 session 关掉、category 也留在通话那套；这里全部设回来。
    func resume() {
        guard wanted else { return }
        paused = false
        let s = AVAudioSession.sharedInstance()
        // 保活只放无声，用普通播放通道跟她的音乐混着，不占通话通道（1105 她说一开 app 音乐就变味）。接电话时 RingService 再切 playAndRecord。
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)
        if player == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? KeepAlive.silentWav().write(to: url)
            }
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0.01
        }
        if player?.isPlaying != true { player?.play() }
    }

    /// 接电话前让位：CallKit 要自己激活 session，我们先退出来。
    func pause() {
        paused = true
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stop() {
        wanted = false
        player?.stop()
        player = nil
    }

    static func silentWav() -> Data {
        let sr: UInt32 = 8000
        let dataLen: UInt32 = sr * 2 * 2   // 2 秒
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataLen); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataLen); d.append(Data(count: Int(dataLen)))
        return d
    }
}
