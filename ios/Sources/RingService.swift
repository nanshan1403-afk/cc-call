import CallKit
import AVFoundation
import UIKit

/// 系统来电界面。电脑说"ring"，这里让手机像接到普通电话一样响。
final class RingService: NSObject, CXProviderDelegate {
    var onAnswer: (() -> Void)?
    var onEnd: (() -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var currentUUID: UUID?

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
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(from name: String) {
        if currentUUID != nil { return }
        let uuid = UUID()
        currentUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] err in
            if err != nil { self?.currentUUID = nil }
        }
    }

    func endCallFromRemote() {
        guard let u = currentUUID else { return }
        provider.reportCall(with: u, endedAt: Date(), reason: .remoteEnded)
        currentUUID = nil
    }

    func endCallFromApp() {
        guard let u = currentUUID else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: u))) { _ in }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        currentUUID = nil
        onAudioDeactivated?()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
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
