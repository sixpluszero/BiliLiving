# BiliLiving

一个为客厅设计的 B 站 tvOS 客户端。基于 [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) 开发，保留原项目版权与 GPL-2.0 许可证。上游版本见 `docs/UPSTREAM-COMMIT`。

## 功能

- 默认游客模式：首次启动和重启均直接进入首页，无需扫码即可浏览、搜索、播放和看弹幕。
- 手机哔哩哔哩 App 扫码登录；二维码过期、网络失败与刷新处理。
- 登录令牌及账号 Cookie 保存在设备 Keychain；退出账号会移除对应记录。
- 发现首页：真实热门视频、大幅封面、三列视频卡片。
- 原生 tvOS 搜索：打字、系统键盘与 Siri Remote 系统听写。语音转写由 tvOS 提供，取决于设备语言、地区和听写设置；不是系统全局 Siri 搜索集成。
- AVKit 原生播放器，默认优先标准 1080p（qn=80），网络自适应向下选择。播放控制栏的“清晰度”菜单可手动选择服务端实际返回的清晰度。
- 真实视频弹幕，默认开启、上半屏显示；播放器中可开关和调整。
- 手机 B 站投屏接收：设备名 **BiliLiving · 小电视**，接力播放、手机控制与断线续播；“我的”显示开关和状态。新安装默认开启，旧安装保留开关。
- 简洁的“发现 / 搜索 / 我的”导航；使用系统原生按钮、焦点和播放控制，跟随 tvOS 26 的外观。
- 我的收藏、观看历史、稍后再看及播放设置。

## 打开项目

打开 `BilibiliLive.xcodeproj`，选择 `BilibiliLive` scheme 和 Apple TV 模拟器后运行。应用显示名称为 **BiliLiving**，Bundle ID 为 `com.jialin.BiliLiving`。保留上游 target 名称以减少迁移改动。

已在 Xcode 26.6 / tvOS 26.5 / Apple TV 4K (3rd generation, 1080p) Simulator 编译与测试。

```sh
./scripts/run-simulator.sh
./scripts/test-simulator.sh
```

脚本通过 `DEVELOPER_DIR` 使用 `/Applications/Xcode.app`，无需更改全局 xcode-select。可设置 `BILILIVING_SIMULATOR_ID` 使用其他已安装 tvOS 模拟器。

## 操作

1. 首次启动直接以游客模式浏览。需要登录时进入“我的 → 扫码登录”，在手机 B 站确认；扫码页也可选择“游客浏览”返回。
2. 选择“搜索”，输入关键词。真机键盘激活时，按住 Siri Remote 麦克风键进行系统听写。
3. 选择视频进入详情，点击播放。
4. 播放中调出底部控制栏，进入“清晰度”或弹幕菜单。手动切换保留当前进度及暂停状态。
5. 返回“我的”可开关弹幕、访问个人列表或退出登录。游客点击点赞、投币、收藏或关注时会提示登录；可取消提示继续观看。游客不向账号历史接口上报观看记录。

手机投屏的使用方式、协议支持与真机验证边界见 [docs/CASTING.md](docs/CASTING.md)。

模拟器可用方向键、Return 和 Escape 操作。模拟器不能完整模拟 Siri Remote 麦克风听写；此项需在真机确认。

## 验证与限制

测试详情见 [docs/TESTING.md](docs/TESTING.md)。测试会访问真实 B 站接口，网络或接口变化可能导致失败。

二维码生成和未扫描轮询已通过验证；账号授权最终确认需用户亲自在手机完成。未使用用户账号时，1080p、会员清晰度、收藏和历史的授权访问尚待登录后验证。菜单仅展示当前账号和视频实际可用的视频流，不绕过会员或区域限制。

这是自用开发版本，没有发布到 App Store 或 TestFlight。安装 Apple TV 真机时，在 Xcode Signing 中选择自己的开发团队并连接设备。

## 来源

原始 README 位于 [docs/UPSTREAM-README.md](docs/UPSTREAM-README.md)，许可证位于 [LICENSE.md](LICENSE.md)。本地分支 `feature/bililiving`。Swift Package Manager 依赖解析结果随项目记录。品牌图标由 `scripts/generate-brand.swift` 绘制。
