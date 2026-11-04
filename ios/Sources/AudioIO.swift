import AVFoundation

/// 麦克风 → 16k PCM16 发给电脑；电脑来的 24k PCM16 → 扬声器/听筒。
final class AudioIO {
    var onMic: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var running = false
    private var pending = Data()
    private let q = DispatchQueue(label: "cc.audio")

    init() {
        engine.attach(player)
    }

    func start() {
        q.async { self._start() }
    }

    func stop() {
        q.async { self._stop() }
    }

    private func _start() {
        guard !running else { return }
        let input = engine.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        guard inFmt.sampleRate > 0 else { return }
        converter = AVAudioConverter(from: inFmt, to: micFormat)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
            self?.convertAndSend(buf)
        }
        engine.prepare()
        do {
            try engine.start()
            player.play()
            running = true
        } catch {
            print("audio engine", error)
        }
    }

    private func _stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        running = false
        pending.removeAll()
    }

    private func convertAndSend(_ buf: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = micFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        onMic?(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
    }

    func play(pcm24k data: Data) {
        q.async {
            guard self.running else { return }
            self.pending.append(data)
            let n = self.pending.count / 2
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: AVAudioFrameCount(n)) else { return }
            buf.frameLength = AVAudioFrameCount(n)
            let dst = buf.floatChannelData![0]
            self.pending.withUnsafeBytes { raw in
                for i in 0..<n {
                    let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    dst[i] = Float(Int16(littleEndian: v)) / 32768.0
                }
            }
            self.pending.removeFirst(n * 2)
            self.player.scheduleBuffer(buf, completionHandler: nil)
            if !self.player.isPlaying { self.player.play() }
        }
    }
}

/// 后台不被系统挂起：循环放一段无声。开着"保持连接"的时候一直放。
final class KeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetooth])
        try? s.setActive(true)
        s.requestRecordPermission { _ in }   // 先把麦克风权限要了，别等到电话里才弹
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? KeepAlive.silentWav().write(to: url)
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
    }

    func stop() {
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
