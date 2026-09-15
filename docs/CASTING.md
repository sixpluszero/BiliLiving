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

此版本聚焦普通视频的接力播放。直播投屏、通用 DLNA SOAP/AirPlay 接收、手机端切换清晰度或倍速、后台唤醒和发送弹幕未实现；番剧标识可进入现有播放器，但会员/区域内容需要真机和相应账号进一步验证。

## 技术来源

- [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo)：上游接收端与播放器。
- [分析 Bilibili 客户端的“哔哩必连”协议](https://www.xfangfang.cn/028)：协议作者的抓包分析；Play.seekTs 与 Seek 使用秒，PlayUrl 通过 nva_ext 传内容。
- [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)：平台本地网络隐私说明。当前文档将 tvOS 列为不启用该隐私机制的平台；未添加仅适用于 iOS 的组播 entitlement。
