// SharedUI — 播放器设置页（UIA-023；PLAN-播放器进阶 P1）
//
// 聚合既有持久化项（UserDefaults 注入同一真源）：默认循环、双击步长、倍速、
// 外挂字幕字号。即时生效（写入即应用），跨会话记忆由各键承担。

import SwiftUI

struct PlayerSettingsView: View {
    @ObservedObject var vm: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("默认循环播放", isOn: Binding(
                        get: { vm.loopEnabled },
                        set: { vm.setDefaultLoopEnabled($0) }
                    ))
                }
                Section("交互") {
                    Picker("双击快进快退", selection: Binding(
                        get: { vm.doubleTapSeconds },
                        set: { vm.doubleTapSeconds = $0 }
                    )) {
                        ForEach(PlayerViewModel.doubleTapOptions, id: \.self) { option in
                            Text("\(Int(option)) 秒").tag(option)
                        }
                    }
                    Picker("播放倍速", selection: Binding(
                        get: { vm.rate },
                        set: { vm.rate = $0 }
                    )) {
                        ForEach(PlayerControlsOverlay.rateOptions, id: \.self) { option in
                            Text(PlayerControlsOverlay.rateLabel(option)).tag(option)
                        }
                    }
                }
                Section("字幕") {
                    Picker("外挂字幕字号", selection: Binding(
                        get: { vm.subtitleScale },
                        set: { vm.subtitleScale = $0 }
                    )) {
                        Text("标准").tag(1.0)
                        Text("大").tag(1.4)
                    }
                }
            }
            .navigationTitle("播放设置")
            .toolbar {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
