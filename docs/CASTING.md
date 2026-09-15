# 手机投屏与接力播放

## 使用

1. 在 Apple TV 打开 BiliLiving，进入“我的”。投屏卡片应显示“等待手机投屏”；新安装默认开启，旧安装保留原开关，可手动开启。
2. 手机与 Apple TV 连接同一局域网（电视可用网线）。在手机哔哩哔哩 App 内打开视频，点击视频的投屏按钮，选择 **BiliLiving · 小电视**。
3. 电视独立加载视频并从手机传来的进度继续。手机可暂停、继续、拖动进度、开关弹幕、停止播放。
4. 手机断开后电视继续播放。重新选择设备连接后，接收端会回传当前状态和进度。手机端自动重连策略由手机 App 决定。

保持 BiliLiving 在前台；后台暂停接收，回到前台重新发布设备。网络恢复或本地 IP 改变时重新监听。关闭投屏只停止网络接收，不中断已开始的电视播放。

游客可使用投屏。视频权限与可用清晰度以电视端账号为准；不会导入手机消息中的 access_key，也不会把手机账号自动登录到电视。电视播放仍使用现有的 1080p 优先策略、清晰度菜单与弹幕播放器。

## 已实现

- SSDP 局域网发现、HTTP 设备描述与 NVA SETUP 长连接；按手机请求的设备/服务类型返回发现应答。
- `Play` 与 iOS `PlayUrl` 的 `nva_ext.content` 解析；支持数字和字符串形式的视频标识、秒数。
- 手机起播位置优先于电视观看历史；缺省起播位置为 0，超出视频时长会限制在结尾前。
- 加载期间的 Pause/Resume/Seek 保留到播放器就绪；新投屏替换旧投屏，不把指令发给旧播放器。
- Pause、Resume、Seek、SwitchDanmaku、Stop，OnPlayState、OnProgress、OnDanmakuSwitch 回传。
- 多次启动幂等，前后台、网络恢复和断开清理。最多同时保留 4 个控制连接。
- 无效 UTF-8、过大消息、无效进度安全拒绝；移除上游局域网日志下载入口，接收消息不记录手机令牌。

## 验证边界

模拟器测试通过真实 TCP/UDP 协议连接接收端，并使用真实 B 站视频验证起播、暂停、跳转、断线续播和重新连接后的控制。测试客户端位于 `Tests/BiliLivingTests.swift`，不会代替手机官方 App 的兼容性验证。

尚未在 iPhone + Apple TV 真机完成端到端发现与投屏验证。官方 App 的版本、局域网组播隔离、防火墙、VPN 与设备名称识别策略仍可能影响发现和连接。若设备不出现，先确认手机允许哔哩哔哩访问局域网、未使用访客网络，且电视 App 在前台。

此版本聚焦普通视频的接力播放。AirPlay 接收、DLNA 事件订阅推送、手机端切换清晰度或倍速、后台唤醒和发送弹幕未实现；DLNA HTTP/HTTPS 媒体地址播放及控制已补充，直播地址取决于 AVPlayer 格式支持；番剧标识可进入现有播放器，但会员/区域内容需要真机和相应账号进一步验证。

## 技术来源

- [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)：上游接收端与播放器。
- [分析 Bilibili 客户端的“哔哩必连”协议](https://www.xfangfang.cn/028)：协议作者的抓包分析；Play.seekTs 与 Seek 使用秒，PlayUrl 通过 nva_ext 传内容。
- [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)：平台本地网络隐私说明。当前文档将 tvOS 列为不启用该隐私机制的平台；未添加仅适用于 iOS 的组播 entitlement。

## 启动故障修补（2026-09-14）

用户反馈“投屏启动失败”后检查了启动路径。旧代码在同一个 catch 中吞掉了 UDP 创建、端口绑定、加入组播和 HTTP 监听的区别，随后从已连接的客厅 Apple TV 读取运行日志，确认多次出现 `dmr start fail: Address already in use.`。结合错误形式和依赖实现，优先定位 UDP 发现端口绑定冲突。发现并处理以下风险：

- SSDP 使用 IPv4 组播，接收 socket 只开启 IPv4，避免不必要的 IPv6 端口占用；若通配地址的 UDP 1900 已被占用，改为绑定 `239.255.255.250:1900`，保留真实组播发现能力。组播接收、发送明确使用当前工作的以太网或 Wi-Fi IPv4 地址。
- 不再无条件选 en0，过滤未运行、回环和不支持组播的接口，优先采用 NWPath 使用的接口。
- HTTP 明确监听 IPv4，默认使用 9958；端口被占用时改用系统分配的端口，并将实际端口放入 SSDP LOCATION。
- 每次重启新建 Swifter 实例。当前依赖的 accept 循环退出时会调用 stop，复用实例可能让旧循环关闭新服务；过期连接回调也按启动代次丢弃。
- 启动后立即公告。异常显示失败步骤和错误码，日志保留错误域与说明，并以 1/2/4/8/15 秒间隔最多重试 5 次；关闭投屏、退到后台会取消重试。

模拟器已验证 UDP 1900 被占用后的真实组播发现、HTTP 端口被占用后的自动换端口、连续 5 次重启、HTTP 描述和真实 NVA 连接。真机旧日志确认地址占用，但未记录绑定地址及 IP 版本；新版本状态文字可以进一步区分具体步骤。

## 能发现但不开始播放：控制协议修补

第二次真机日志检查（2026-09-14 21:12）确认新版本已成功启动：UDP 1900 走组播地址绑定，HTTP 9958 正常。手机多次获取设备、AVTransport、NirvanaControl 描述，却没有出现 `session connected`，因此当时尚未进入接收 Play 的阶段。

发现并修正的互操作问题：

- SSDP USN 原来带 `atvbilibili&` 前缀，与 XML UDN 以及 NVA UUID 不一致。现在三处使用相同的稳定设备标识，并把旧的 35 位随机后缀迁移为 NVA 的 `XY` 前缀格式。
- 握手响应原来是 `NVA 200 OK`，现在为 `NVA/1.0 200 OK`，明确包含 `Content-Length: 0`、Session、UUID 和版本。
- 原回复重新递增序号，还会被读取线程的下一条指令覆盖；现在回复直接使用对应请求的序号，主动状态事件/心跳采用独立计数。
- 支持 `RESTORE /projection` 重新连接，返回当前状态；恢复每秒心跳。
- 设备/服务描述返回 `text/xml`，NirvanaControl 描述补齐 SCPD 根元素、namespace、specVersion 和 serviceStateTable。
- 新增受限请求路径、握手、指令类型、播放器呈现阶段日志，不记录请求正文、Session、手机令牌或签名 URL。

协议依据：[原始抓包分析](https://www.xfangfang.cn/028) 与 [Macast Nirvana 实现](https://github.com/xfangfang/Macast-plugins/blob/main/nirvana/nirvana.py)。这些修补消除了确定的协议错误，但旧日志没有记录每个 HTTP 请求，不能仅凭描述请求确定官方手机客户端拒绝连接的唯一原因。

新的测试客户端使用严格 NVA 握手与二进制解析，检查设备身份一致、零长度握手正文、突发指令的逐条序号匹配、心跳与 RESTORE。真实视频接力测试先等待 GetVolume 的正确回复再发送 Play，验证播放时钟增长。官方手机客户端到 Apple TV 的端到端效果仍需安装新包后确认；发现列表可能缓存旧身份，需重新打开投屏列表选择设备。


## 手机进入控制页但电视无响应：DLNA SOAP 路径

2026-09-14 21:51 读取客厅 Apple TV 的本轮日志，21:45:58–21:46:38 连续出现 `POST /AVTransport/action`，没有 `/projection` 握手。这与之前基于 NVA 的测试路径不同。旧处理器对该路由一律返回 HTTP 400（`Use the Bilibili NVA projection service`），导致已发现设备的手机进入控制界面后，电视不处理其播放请求。日志未保存 SOAP 正文或动作名称，因此不能断言每条旧请求的具体动作和媒体格式。

补齐标准 SOAP 控制：SetAVTransportURI 保存媒体，Play 打开/恢复播放器，Pause、Stop、REL_TIME Seek 控制播放；GetTransportInfo/GetPositionInfo/GetMediaInfo 返回实际状态与进度。XML URL 转义、百分号编码的 nva_ext 分层解析；有 B 站视频标识时复用视频播放器，没有标识时使用 AVPlayer 播放 HTTP/HTTPS 媒体地址。未知动作、非法实例、无效地址及跳转返回 SOAP Fault，不再静默失败。直接地址播放也应用现有前向缓冲设置。

日志仅记录经过校验的动作名称、媒体类型和错误码，不记录手机提供的 URI、元数据或令牌。尚未实现 DLNA SUBSCRIBE 事件推送；本轮真机日志只有 HTTP 动作请求，标准状态查询已支持。

协议参考：[UPnP AVTransport 规范](https://www.upnp.org/specs/av/UPnP-av-AVTransport-v3-Service.pdf)。直接地址回归使用 [Apple HLS 测试流](https://developer.apple.com/streaming/examples/advanced-stream-hevc.html)。官方手机与真机仍待此安装包复测。
