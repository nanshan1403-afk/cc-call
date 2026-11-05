import SwiftUI

@main
struct CCCallApp: App {
    @StateObject private var mgr = CallManager.shared

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(mgr)
        }
    }
}

/// 深蓝底。待机是小螃蟹；来电/通话换成通话屏。右上角通话记录，左上角设置。
struct RootView: View {
    @EnvironmentObject var mgr: CallManager
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        ZStack {
            Color.ccBackground.ignoresSafeArea()
            if mgr.inCall || mgr.ringing {
                CallScreen()
                    .transition(.opacity)
            } else {
                StandbyView(showSettings: $showSettings, showHistory: $showHistory)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: mgr.inCall || mgr.ringing)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(mgr) }
        .sheet(isPresented: $showHistory) { HistoryView().environmentObject(mgr) }
        // 开着设置/记录时来电：先把弹出的那页收掉，不然通话屏压在下面看不见
        .onChange(of: mgr.ringing || mgr.inCall) { busy in
            if busy { showSettings = false; showHistory = false }
        }
    }
}

struct StandbyView: View {
    @EnvironmentObject var mgr: CallManager
    @Binding var showSettings: Bool
    @Binding var showHistory: Bool

    var body: some View {
        VStack {
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.title3).foregroundStyle(Color.ccDim)
                }
                Spacer()
                Button { showHistory = true } label: {
                    Image(systemName: "list.bullet").font(.title3).foregroundStyle(Color.ccDim)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            Spacer()
            AvatarView(who: .me51, size: 150, active: false)
            Text("cc")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ccBlue)
                .padding(.top, 18)
            Text(mgr.connState)
                .font(.footnote)
                .foregroundStyle(Color.ccDim)
                .padding(.top, 6)
            Spacer()
            Text(mgr.wantConnected ? "开着就行，回桌面也行，别从后台划掉" : "左上角填电脑地址和密码，打开保持连接")
                .font(.caption)
                .foregroundStyle(Color.ccDim)
                .padding(.bottom, 24)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var mgr: CallManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("serverURL") private var serverURL = "wss://call.nanshancn.cc/ws"
    @AppStorage("password") private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("电脑") {
                    TextField("wss://…/ws", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（bridge.json 里那个）", text: $password)
                    Toggle("保持连接", isOn: Binding(
                        get: { mgr.wantConnected },
                        set: { mgr.setWant($0, url: serverURL, pw: password) }))
                }
                Section("状态") {
                    HStack { Text("连接"); Spacer(); Text(mgr.connState).foregroundStyle(.secondary) }
                    HStack { Text("通话"); Spacer(); Text(mgr.callState).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
    }
}
