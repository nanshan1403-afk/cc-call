import CallKit
import AVFoundation
import UIKit

/// 系统来电界面。电脑说"ring"，这里让手机像接到普通电话一样响。
final class RingService: NSObject, CXProviderDelegate {
    var onBeforeAnswer: (() -> Void)?        // 接之前让保活让位
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentUUID: UUID?           // 只在主队列上碰

    override init() {
        let cfg = CXProviderConfiguration()
        cfg.supportsVideo = false
        cfg.maximumCallGroups = 1
        cfg.maximumCallsPerCallGroup = 1
        cfg.supportedHandleTypes = [.generic]
        cfg.includesCallsInRecents = true
        if let img = UIImage(named: "CallIcon") {
            cfg.iconTemplateImageData = img.pngData()
        }
        provider = CXProvider(configuration: cfg)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    var hasCall: Bool { currentUUID != nil }

    func reportIncoming(from name: String) {
        DispatchQueue.main.async {
            if self.currentUUID != nil { return }
            let uuid = UUID()
            self.currentUUID = uuid
            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: name)
            update.localizedCallerName = name
            update.hasVideo = false
            update.supportsHolding = false
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.supportsDTMF = false
            self.provider.reportNewIncomingCall(with: uuid, update: update) { err in
                if err != nil { DispatchQueue.main.async { self.currentUUID = nil } }
            }
        }
    }

    /// 电脑那头挂了
    func endCallFromRemote() { end(reason: .remoteEnded) }

    /// 网断了
    func failCall() { end(reason: .failed) }

    private func end(reason: CXCallEndedReason) {
        DispatchQueue.main.async {
            guard let u = self.currentUUID else { return }
            self.provider.reportCall(with: u, endedAt: Date(), reason: reason)
            self.currentUUID = nil
        }
    }

    /// 她在 app 里按挂断
    func endCallFromApp() {
        DispatchQueue.main.async {
            guard let u = self.currentUUID else { return }
            self.controller.request(CXTransaction(action: CXEndCallAction(call: u))) { _ in }
        }
    }

    // MARK: - CXProviderDelegate（主队列）

    func providerDidReset(_ provider: CXProvider) {
        currentUUID = nil
        onAudioDeactivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onBeforeAnswer?()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
        onAnswer?()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnd?()
        currentUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onAudioDeactivated?()
    }
}
