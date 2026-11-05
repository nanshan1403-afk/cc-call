import SwiftUI

/// 来电 / 通话中：上面是谁和时长，中间头像在动，下面字幕一行一行冒，底下静音 / 挂断 / 免提。
struct CallScreen: View {
    @EnvironmentObject var mgr: CallManager
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var who: Who { Who.from(name: mgr.caller) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(mgr.caller)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(who.color)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.ccDim)
            }
            .padding(.top, 28)

            AvatarView(who: who, size: 120, active: true)
                .padding(.top, 26)
                .padding(.bottom, 10)

            BubbleList(lines: mgr.lines, who: who)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 44) {
                RoundButton(icon: mgr.muted ? "mic.slash.fill" : "mic.fill", label: "静音",
                            on: mgr.muted) { mgr.toggleMute() }
                RoundButton(icon: "phone.down.fill", label: "挂断", on: false, danger: true) { mgr.hangupFromApp() }
                RoundButton(icon: "speaker.wave.2.fill", label: "免提",
                            on: mgr.speaker) { mgr.toggleSpeaker() }
            }
            .padding(.bottom, 36)
        }
        .onReceive(tick) { now = $0 }
    }

    private var subtitle: String {
        if mgr.ringing { return "来电…" }
        if let s = mgr.callStart {
            let d = Int(now.timeIntervalSince(s))
            return String(format: "%02d:%02d · %@", d / 60, d % 60, mgr.callState)
        }
        return mgr.callState
    }
}

struct RoundButton: View {
    var icon: String
    var label: String
    var on: Bool
    var danger: Bool = false
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(danger || on ? Color.white : Color.white.opacity(0.9))
                    .frame(width: 68, height: 68)
                    .background(danger ? Color.red : (on ? Color.white.opacity(0.35) : Color.white.opacity(0.14)))
                    .clipShape(Circle())
            }
            Text(label).font(.caption).foregroundStyle(Color.ccDim)
        }
    }
}
