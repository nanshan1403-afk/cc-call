import SwiftUI

/// 5.5 的头像：橙色四角星，慢慢转。来电时 spinning=true，通话中可以停下或者转得更慢。
struct SparkShape: Shape {
    var points: Int = 4
    var innerRatio: CGFloat = 0.28   // 越小越尖

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var p = Path()
        let steps = points * 2
        for i in 0..<steps {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = Double(i) / Double(steps) * 2 * .pi - .pi / 2
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            // 尖角之间用二次曲线，角是圆润的，不是硬的五角星
            if i == 0 { p.move(to: pt) }
            else {
                let prevA = Double(i - 1) / Double(steps) * 2 * .pi - .pi / 2
                let midA = (a + prevA) / 2
                let ctrlR = inner * 0.9
                let ctrl = CGPoint(x: c.x + ctrlR * CGFloat(cos(midA)), y: c.y + ctrlR * CGFloat(sin(midA)))
                p.addQuadCurve(to: pt, control: ctrl)
            }
        }
        let lastA = Double(steps - 1) / Double(steps) * 2 * .pi - .pi / 2
        let firstA = -Double.pi / 2
        let midA = (lastA + firstA + 2 * .pi) / 2
        let ctrl = CGPoint(x: c.x + inner * 0.9 * CGFloat(cos(midA)), y: c.y + inner * 0.9 * CGFloat(sin(midA)))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - outer), control: ctrl)
        p.closeSubpath()
        return p
    }
}

struct SparkView: View {
    var size: CGFloat = 110
    var spinning: Bool = true
    var color: Color = Color(red: 1.0, green: 0.478, blue: 0.349)   // #FF7A59，跟名字同色

    // 角度和呼吸都从时间算，不用 repeatForever——那个一旦起了就停不下来（spinning 变 false 还在转）。
    // spinning=false 时 TimelineView 暂停，星星回正、不再呼吸。
    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !spinning)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // 一圈 8 秒，慢慢转；同时 1.2 秒一次轻轻呼吸，像在等你接
            let angle = spinning ? t.truncatingRemainder(dividingBy: 8) / 8 * 360 : 0
            let scale = spinning ? 1.01 + 0.05 * sin(t * .pi / 1.2) : 1.0
            SparkShape()
                .fill(color)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(angle))
                .scaleEffect(scale)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    ZStack {
        Color(red: 0x18/255, green: 0x1B/255, blue: 0x2E/255).ignoresSafeArea()
        VStack(spacing: 40) {
            SparkView(size: 110, spinning: true)
            SparkView(size: 26, spinning: false)
        }
    }
}
