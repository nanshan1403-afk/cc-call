import Foundation
import Combine

/// 跟电脑上的 callserver.py 保持一条 WebSocket；来电、接听、挂断、音频都走它。
final class CallManager: NSObject, ObservableObject {
    static let shared = CallManager()

    @Published var connState = "没连"
    @Published var callState = "空闲"
    @Published var inCall = false
    @Published private(set) var wantConnected = false

    private var url: URL?
    private var password = ""
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var reconnectDelay: TimeInterval = 2
    private var generation = 0
    private var pingTimer: Timer?

    private let ring = RingService()
    private let audio = AudioIO()
    private let keepAlive = KeepAlive()

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 86400 * 7
        session = URLSession(configuration: cfg)

        ring.onBeforeAnswer = { [weak self] in self?.keepAlive.pause() }
        ring.onAnswer = { [weak self] in self?.answered() }
        ring.onEnd = { [weak self] in self?.endedByUser() }
        ring.onAudioActivated = { [weak self] in self?.audio.start() }
        ring.onAudioDeactivated = { [weak self] in
            guard let self else { return }
            self.audio.stop()
            if self.wantConnected { self.keepAlive.resume() }   // 通话完把无声保活放回去，不然后台很快被挂起
        }
        audio.onMic = { [weak self] data in self?.send(data: data) }

        wantConnected = UserDefaults.standard.bool(forKey: "wantConnected")
        if wantConnected,
           let s = UserDefaults.standard.string(forKey: "serverURL"), let u = URL(string: s) {
            url = u
            password = UserDefaults.standard.string(forKey: "password") ?? ""
            connect()
        }
    }

    func setWant(_ on: Bool, url: String, pw: String) {
        wantConnected = on
        UserDefaults.standard.set(on, forKey: "wantConnected")
        self.url = URL(string: url)
        self.password = pw
        if on { reconnectDelay = 2; connect() } else { disconnect() }
    }

    func hangupFromApp() { ring.endCallFromApp() }

    // MARK: - 连接

    private func connect() {
        guard wantConnected, let url else { set(conn: "地址不对"); return }
        task?.cancel()
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        keepAlive.start()
        sendJSON(["type": "hello", "pw": password])
        set(conn: "连接中…")
        receive(gen: gen)
        startPing()
    }

    private func disconnect() {
        generation += 1
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        keepAlive.stop()
        set(conn: "没连")
    }

    private func startPing() {
        stopPing()
        DispatchQueue.main.async {
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { _ in }
            }
        }
    }

    private func stopPing() {
        DispatchQueue.main.async { self.pingTimer?.invalidate(); self.pingTimer = nil }
    }

    private func receive(gen: Int) {
        task?.receive { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .failure(let e):
                self.set(conn: "断了：\(e.localizedDescription)")
                DispatchQueue.main.async {
                    // 响着没接的也算，不然来电界面会一直挂着
                    if self.ring.hasCall {
                        self.ring.failCall()
                        self.inCall = false
                        self.callState = "断线"
                    }
                }
                self.scheduleReconnect()
            case .success(let msg):
                switch msg {
                case .data(let d): self.audio.play(pcm24k: d)
                case .string(let s): self.handle(text: s)
                @unknown default: break
                }
                self.receive(gen: gen)
            }
        }
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        let d = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.connect() }
    }

    // MARK: - 消息

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = ev["type"] as? String else { return }
        switch type {
        case "hello":
            reconnectDelay = 2
            set(conn: "连着")
        case "ring":
            set(call: "来电…")
            ring.reportIncoming(from: ev["caller"] as? String ?? "cc")
        case "cancel":
            ring.endCallFromRemote()
            set(call: "空闲")
        case "hangup":
            ring.endCallFromRemote()
            DispatchQueue.main.async { self.inCall = false }
            set(call: "挂了")
        case "flush":
            audio.flush()
        case "state":
            let v = ev["v"] as? String ?? ""
            let names = ["speaking": "他在说", "listening": "在听你", "thinking": "他在想"]
            set(call: names[v] ?? v)
        case "error":
            set(conn: ev["text"] as? String ?? "错误")
        default:
            break
        }
    }

    private func answered() {
        DispatchQueue.main.async { self.inCall = true }
        set(call: "接通")
        sendJSON(["type": "answer"])
        // 有时 CallKit 不回调 didActivate（session 本来就是激活的），一秒没动静就自己起引擎
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.inCall, !self.audio.isRunning else { return }
            self.audio.start()
        }
    }

    private func endedByUser() {
        DispatchQueue.main.async { self.inCall = false }
        sendJSON(["type": "hangup"])
        set(call: "挂了")
    }

    private func send(data: Data) {
        task?.send(.data(data)) { _ in }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func set(conn: String) { DispatchQueue.main.async { self.connState = conn } }
    private func set(call: String) { DispatchQueue.main.async { self.callState = call } }
}
