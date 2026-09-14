import SwiftUI
import Kingfisher
import UIKit

final class LivingHomeViewController: UIViewController, BLTabBarContentVCProtocol {
    private let model = LivingHomeModel()
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: LivingHomeView(model: model, open: { [weak self] video in
            guard let self else { return }
            VideoDetailViewController.create(aid: video.aid, cid: video.cid).present(from: self)
        }, search: { [weak self] in self?.tabBarController?.selectedIndex = 1 }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
    func reloadData() { Task { await model.load() } }
}

@MainActor final class LivingHomeModel: ObservableObject {
    @Published var videos: [VideoDetail.Info] = []
    @Published var loading = false
    @Published var error: String?
    func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do { videos = try await WebRequest.requestHotVideo(page: 1).list }
        catch { self.error = "暂时无法加载视频，请稍后重试。" }
    }
}

struct LivingHomeView: View {
    @ObservedObject var model: LivingHomeModel
    let open: (VideoDetail.Info) -> Void
    let search: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                if let hero = model.videos.first {
                    ZStack(alignment: .leading) {
                        GeometryReader { geo in
                            KFImage(hero.pic).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: geo.size.width * 0.75, height: 510).clipped()
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        LinearGradient(colors: [Color(white: 0.06), Color(white: 0.06).opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 22) {
                            Text("BILILIVING  /  今日发现").font(.system(size: 20, weight: .semibold, design: .rounded)).tracking(4).foregroundStyle(.white.opacity(0.7))
                            Text(hero.title).font(.system(size: 48, weight: .bold)).lineLimit(3).frame(maxWidth: 780, alignment: .leading)
                            Text(hero.ownerName).font(.system(size: 24)).foregroundStyle(.white.opacity(0.65))
                            HStack(spacing: 20) {
                                Button { open(hero) } label: { Label("开始观看", systemImage: "play.fill") }
                                    .accessibilityIdentifier("living.hero.play")
                                Button(action: search) { Label("搜索", systemImage: "magnifyingglass") }
                            }.padding(.top, 10)
                        }.padding(56)
                    }.frame(height: 510).clipShape(RoundedRectangle(cornerRadius: 30)).focusSection()
                    HStack(alignment: .firstTextBaseline) {
                        Text("此刻，值得一看").font(.system(size: 34, weight: .bold))
                        Spacer()
                        Text("1080p 优先 · 弹幕随行").font(.system(size: 21)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 36), count: 3), spacing: 44) {
                        ForEach(Array(model.videos.dropFirst().enumerated()), id: \.element.aid) { index, video in
                            Button { open(video) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    KFImage(video.pic).resizable().aspectRatio(16 / 9, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                    Text(video.title).font(.system(size: 26, weight: .medium)).lineLimit(2).frame(height: 68, alignment: .topLeading)
                                    Text(video.ownerName).font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.buttonStyle(.card).accessibilityIdentifier("living.video.\(index)")
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        Text("BiliLiving").font(.system(size: 76, weight: .bold))
                        Text("好视频，坐下来慢慢看。").font(.system(size: 36)).foregroundStyle(.secondary)
                        if model.loading { ProgressView("正在发现精彩内容…") }
                        if let error = model.error {
                            Text(error).font(.system(size: 24)).foregroundStyle(.secondary)
                            Button("重新加载") { Task { await model.load() } }
                        }
                        Button(action: search) { Label("搜索视频", systemImage: "magnifyingglass") }
                    }.frame(maxWidth: .infinity, minHeight: 620, alignment: .leading)
                }
                Text("BiliLiving · 你的客厅放映室").font(.system(size: 18)).foregroundStyle(.tertiary).padding(.top, 10)
            }.padding(.horizontal, 72).padding(.top, 40).padding(.bottom, 70)
        }.background(Color(white: 0.035)).task { if model.videos.isEmpty { await model.load() } }
    }
}

final class LivingLibraryViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: LivingLibraryView(open: { [weak self] page in
            guard let self else { return }
            self.present(TabBarPageVCFactory.createVC(for: page), animated: true)
        }, settings: { [weak self] in
            guard let self else { return }
            self.present(SettingsViewController(), animated: true)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

struct LivingLibraryView: View {
    let open: (TabBarPage) -> Void
    let settings: () -> Void
    @ObservedObject private var defaults = Defaults.shared
    @State private var loggedIn = ApiRequest.isLogin()
    var body: some View {
        VStack(alignment: .leading, spacing: 44) {
            HStack(spacing: 28) {
                Image(systemName: loggedIn ? "person.crop.circle.fill" : "person.crop.circle").font(.system(size: 80)).foregroundStyle(.white.opacity(0.75))
                VStack(alignment: .leading, spacing: 12) {
                    Text(loggedIn ? (AccountManager.shared.activeAccount?.profile.username ?? "我的空间") : "游客模式").font(.system(size: 48, weight: .bold))
                    Text(loggedIn ? "继续喜欢的内容，发现新的灵感。" : "无需登录，搜索、看视频和弹幕。登录后可同步收藏与观看记录。").font(.system(size: 25)).foregroundStyle(.secondary)
                }
            }
            if !loggedIn {
                Button { AppDelegate.shared.showLogin() } label: { Label("扫码登录", systemImage: "qrcode.viewfinder") }.accessibilityIdentifier("living.login")
            } else {
                HStack(spacing: 28) {
                    Button { open(.favorite) } label: { Label("我的收藏", systemImage: "heart") }
                    Button { open(.history) } label: { Label("观看历史", systemImage: "clock") }
                    Button { open(.toView) } label: { Label("稍后再看", systemImage: "bookmark") }
                }
            }
            Divider().padding(.vertical, 10)
            Text("观看偏好").font(.system(size: 32, weight: .bold))
            HStack(spacing: 28) {
                Button { defaults.showDanmu.toggle() } label: {
                    Label(defaults.showDanmu ? "弹幕已开启" : "弹幕已关闭", systemImage: defaults.showDanmu ? "text.bubble.fill" : "text.bubble")
                }.accessibilityIdentifier("living.danmaku.toggle")
                Button(action: settings) { Label("播放设置", systemImage: "slider.horizontal.3") }
                if loggedIn {
                    Button("退出登录") { ApiRequest.logout { _ in loggedIn = ApiRequest.isLogin() } }
                }
            }
            Text("默认优先 1080p，可在播放器中切换清晰度。\n搜索时可打字输入，或按住 Siri 遥控器麦克风键听写。")
                .font(.system(size: 24)).foregroundStyle(.secondary).lineSpacing(12)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text("BiliLiving · 为大屏而生").font(.system(size: 20)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 100).padding(.top, 90).padding(.bottom, 60).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.035))
    }
}
