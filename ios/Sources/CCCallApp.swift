import SwiftUI

@main
struct CCCallApp: App {
    @StateObject private var mgr = CallManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(mgr)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var mgr: CallManager
    @AppStorage("serverURL") private var serverURL = "ws://192.168.1.2:8766/ws"
    @AppStorage("password") private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("电脑") {
                    TextField("ws://电脑IP:8766/ws", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（bridge.json 里那个）", text: $password)
                    Toggle("保持连接", isOn: Binding(
                        get: { mgr.wantConnected },
                        set: { mgr.setWant($0, url: serverURL, pw: password) }))
                }
                Section("状态") {
                    row("连接", mgr.connState)
                    row("通话", mgr.callState)
                }
                if !mgr.lines.isEmpty {
                    Section("这通电话") {   // 先这么摆着，界面她回来设计
                        ForEach(mgr.lines) { l in
                            HStack(alignment: .top) {
                                Text(l.who == "cc" ? "cc" : "你").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                                Text(l.text)
                            }
                        }
                    }
                }
                if mgr.inCall {
                    Section {
                        Button(role: .destructive) { mgr.hangupFromApp() } label: {
                            HStack { Spacer(); Text("挂断"); Spacer() }
                        }
                    }
                }
                Section {
                    Text("开着连接回桌面也行，别从后台划掉。cc 打来会像普通来电一样响，锁屏也能接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("cc")
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}
