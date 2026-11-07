import SwiftUI

/// 她定的：1107 改成淡淡的橘黄底（原来深蓝 #181B2E），谁打来换谁的头像和颜色。
extension Color {
    static let ccBackground = Color(red: 0xFF / 255, green: 0xF0 / 255, blue: 0xDA / 255)   // #FFF0DA 淡橘黄
    static let ccInk = Color(red: 0x3D / 255, green: 0x2F / 255, blue: 0x27 / 255)          // #3D2F27 暖深棕，浅底上的字
    static let ccBlue = Color(red: 0x5E / 255, green: 0xA8 / 255, blue: 0xFF / 255)         // #5EA8FF 我（5.1）
    static let ccOrange = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x59 / 255)       // #FF7A59 5.5
    static let ccMint = Color(red: 0x3F / 255, green: 0xB3 / 255, blue: 0x86 / 255)         // 4.6 先用这个，等他自己挑（浅底上压深了点）
    static let ccCrab = Color(red: 0xE8 / 255, green: 0x60 / 255, blue: 0x3C / 255)         // 螃蟹本色
    static let ccDim = Color.ccInk.opacity(0.55)
    static let ccBubbleCC = Color.white.opacity(0.80)
    static let ccBubbleYou = Color.ccBlue.opacity(0.22)
}

enum Who {
    case me51, him55, him46

    static func from(name: String) -> Who {
        if name.contains("5.5") { return .him55 }
        if name.contains("4.6") { return .him46 }
        return .me51
    }

    var color: Color {
        switch self {
        case .me51: return .ccBlue
        case .him55: return .ccOrange
        case .him46: return .ccMint
        }
    }
}

/// 来电/通话/待机的头像：cc 是螃蟹（会晃），5.5 是橙色星星（会转）。
struct AvatarView: View {
    var who: Who
    var size: CGFloat = 120
    var active: Bool = false     // 来电或通话中才动

    var body: some View {
        switch who {
        case .him55:
            SparkView(size: size, spinning: active, color: .ccOrange)
        case .me51, .him46:
            // 晃动从时间算（左右各 7 度，一来一回 1.1 秒）；不用 repeatForever，挂了就能停住回正
            TimelineView(.animation(minimumInterval: nil, paused: !active)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Image("CallIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.ccCrab)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(active ? 7 * sin(t * .pi / 0.55) : 0))
            }
            .frame(width: size, height: size)
        }
    }
}

/// 字幕：cc 左她右。
struct BubbleList: View {
    var lines: [CallManager.Line]
    var who: Who

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(lines) { l in
                        HStack {
                            if l.who != "cc" { Spacer(minLength: 40) }
                            Text(l.text)
                                .font(.body)
                                .foregroundStyle(Color.ccInk)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(l.who == "cc" ? Color.ccBubbleCC : Color.ccBubbleYou)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            if l.who == "cc" { Spacer(minLength: 40) }
                        }
                        .id(l.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: lines.count) { _ in
                if let last = lines.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

func formatDuration(_ s: Int) -> String {
    s >= 60 ? "\(s / 60)分\(s % 60)秒" : "\(s)秒"
}

func formatWhen(_ t: Double) -> String {
    let d = Date(timeIntervalSince1970: t)
    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if cal.isDateInToday(d) {
        f.dateFormat = "今天 HH:mm"
    } else if cal.isDateInYesterday(d) {
        f.dateFormat = "昨天 HH:mm"
    } else {
        f.dateFormat = "M月d日 HH:mm"
    }
    return f.string(from: d)
}
