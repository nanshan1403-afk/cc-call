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

    @State private var angle: Double = 0
    @State private var pulse = false

    var body: some View {
        SparkShape()
            .fill(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .scaleEffect(pulse ? 1.06 : 0.96)
            .onAppear { start() }
            .onChange(of: spinning) { _ in start() }
    }

    private func start() {
        guard spinning else {
            withAnimation(.easeOut(duration: 0.6)) { pulse = false }
            return
        }
        // 一圈 8 秒，慢慢转；同时 1.2 秒一次轻轻呼吸，像在等你接
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) { angle = 360 }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
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
