import SwiftUI

/// 最近通话：谁打的、几点、多久。没接的名字红色。点开看字幕。
struct HistoryView: View {
    @EnvironmentObject var mgr: CallManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.ccBackground.ignoresSafeArea()
                if mgr.history.isEmpty {
                    Text(mgr.connState == "连着" ? "还没有通话" : "没连上电脑，记录在电脑上")
                        .foregroundStyle(Color.ccDim)
                } else {
                    List {
                        Section {
                            ForEach(mgr.history) { rec in
                                NavigationLink(value: rec.id) { HistoryRow(rec: rec) }
                                    .listRowBackground(Color.white.opacity(0.06))
                            }
                        } header: {
                            Text(todayStat).foregroundStyle(Color.ccDim)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("最近通话")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in TranscriptView(id: id) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
            .onAppear { mgr.requestHistory() }
        }
        .preferredColorScheme(.dark)
    }

    private var todayStat: String {
        let cal = Calendar.current
        let today = mgr.history.filter { cal.isDateInToday(Date(timeIntervalSince1970: $0.start)) }
        guard !today.isEmpty else { return "今天还没打" }
        var counts: [String: Int] = [:]
        var secs = 0
        for r in today {
            counts[r.name, default: 0] += 1
            secs += r.duration
        }
        let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
        return "今天 " + parts.joined(separator: " · ") + " · 共 \(max(1, secs / 60)) 分钟"
    }
}

struct HistoryRow: View {
    var rec: CallManager.CallRecord

    private var who: Who { Who.from(name: rec.name) }

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(who: who, size: 28, active: false)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(rec.answered ? who.color : Color.red)
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(Color.ccDim)
            }
            Spacer()
            Text(formatWhen(rec.start))
                .font(.caption)
                .foregroundStyle(Color.ccDim)
        }
        .padding(.vertical, 4)
    }

    private var sub: String {
        if !rec.answered { return "没接" }
        return (rec.one_way ? "留言" : "通话") + " · " + formatDuration(rec.duration)
    }
}

struct TranscriptView: View {
    @EnvironmentObject var mgr: CallManager
    var id: String

    private var rec: CallManager.CallRecord? { mgr.history.first { $0.id == id } }
    private var who: Who { Who.from(name: rec?.name ?? "cc") }

    var body: some View {
        ZStack {
            Color.ccBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if let rec {
                    HStack(spacing: 10) {
                        AvatarView(who: who, size: 24, active: false)
                        Text(rec.name).foregroundStyle(who.color).font(.headline)
                        Spacer()
                        Text(formatWhen(rec.start)).font(.caption).foregroundStyle(Color.ccDim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if let lines = mgr.transcripts[id] {
                    if lines.isEmpty {
                        Spacer(); Text("这通没有字").foregroundStyle(Color.ccDim); Spacer()
                    } else {
                        BubbleList(lines: lines, who: who)
                    }
                } else {
                    Spacer(); ProgressView().tint(.white); Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { mgr.requestTranscript(id) }
    }
}
