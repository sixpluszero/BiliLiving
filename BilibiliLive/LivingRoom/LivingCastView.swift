import SwiftUI

struct LivingCastView: View {
    @ObservedObject private var receiver = BiliBiliUpnpDMR.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .center, spacing: 30) {
                Image(systemName: "airplayvideo").font(.system(size: 52, weight: .light))
                    .frame(width: 88, height: 88).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
                VStack(alignment: .leading, spacing: 10) {
                    Text("手机选片，电视接着看").font(.system(size: 32, weight: .semibold))
                    HStack(spacing: 10) {
                        Circle().fill(receiver.isRunning ? Color.green : Color.gray).frame(width: 9, height: 9)
                        Text(receiver.status).font(.system(size: 23)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    receiver.setEnabled(!Settings.enableDLNA)
                } label: {
                    Label(Settings.enableDLNA ? "关闭投屏" : "开启投屏", systemImage: "power")
                }.accessibilityIdentifier("living.cast.toggle")
                if Settings.enableDLNA && !receiver.isRunning {
                    Button("重试") { receiver.start() }
                }
            }
            Text("让手机与 Apple TV 连接同一局域网，在哔哩哔哩的视频投屏列表中选择「\(BiliBiliUpnpDMR.deviceName)」。")
                .font(.system(size: 24)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("保持 BiliLiving 在前台 · 支持游客接收 · 手机断开后电视继续播放")
                .font(.system(size: 20)).foregroundStyle(.tertiary)
        }.padding(36).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28)).focusSection()
    }
}
