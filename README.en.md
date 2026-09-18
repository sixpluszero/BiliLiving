<a id="top"></a>
<p align="center">
  <img src="docs/assets/bililiving-banner.svg" alt="BiliLiving" width="960">
</p>

<h3 align="center">Good videos. Make yourself comfortable.</h3>
<p align="center">A Bilibili client for Apple TV, made for your living room</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-tvOS-111827?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="Platform: tvOS">
  <img src="https://img.shields.io/badge/Language-Swift-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Language: Swift">
  <a href="LICENSE.md"><img src="https://img.shields.io/badge/License-GPL--2.0-5086b7?style=flat-square" alt="License: GPL-2.0"></a>
  <a href="https://github.com/yichengchen/ATV-Bilibili-demo"><img src="https://img.shields.io/badge/Fork-ATV--Bilibili--demo-64748b?style=flat-square&amp;logo=github&amp;logoColor=white" alt="Fork of ATV-Bilibili-demo"></a>
</p>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

<p align="center">
  <a href="#features">✨ Features</a> ·
  <a href="#preview">📺 Preview</a> ·
  <a href="#quick-start">⚡ Quick Start</a> ·
  <a href="#casting">📱 Casting</a> ·
  <a href="#development">🛠 Development</a> ·
  <a href="#credits">🤝 Credits</a>
</p>

---

**BiliLiving** brings browsing, search, danmaku (on-screen comments), and phone casting to Apple TV, with a focus on **longer buffering for high-quality playback in the US and other overseas regions** and **TV-side HD playback from low-resolution cast links**. Start watching as a guest, or sign in for account recommendations, favorites, and watch history—all navigable with your remote.

> A community fork of [ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo), focused on guest access, the living-room home screen, and casting. Core playback, API, and danmaku capabilities come from upstream. This is an unofficial Bilibili client.

## Recent Updates

- **2026-09-15** — Account recommendations and paginated popular videos for guests; “Best available” as the default quality, with a creator follow action in the player.
- **2026-09-14** — Casting handoff and control improvements, including DLNA SOAP playback, video identification, and danmaku restoration.

See the [testing notes](docs/TESTING.md) (Chinese) for implementation and verification details.

<a id="features"></a>

## Features

| | What you can do on your TV |
| :--- | :--- |
| 🌎 **More buffering for overseas viewing** | New 30-second, 2-minute, and 5-minute forward-buffer targets, defaulting to 2 minutes, give 4K and other high-bitrate videos more room to absorb network fluctuations when accessing Bilibili CDNs from the US and other overseas regions. |
| 📺 **Low-resolution cast, higher-quality TV playback** | When a phone sends only a plain DLNA 720p link, try to identify the original video and fetch available HD streams using the signed-in TV account, restoring quality controls and danmaku. |
| 🛋 **Watch right away** | Browse, search, play videos, and enjoy danmaku without signing in. Account actions such as favoriting and following prompt for login when needed. |
| 🎞 **A home screen for the couch** | Large artwork, a three-column video grid, and remote focus navigation. Signed-in viewers get account recommendations; guests get popular videos, with pagination and refresh. |
| 🔎 **Native search** | Type with the tvOS keyboard or use Siri Remote dictation, subject to device language, region, and settings. |
| ▶️ **Native playback** | AVKit controls, quality selection, playback speed, and buffering preferences. Fresh installs default to the best quality available for the current account and video. |
| 💬 **Danmaku included** | Real video comments, enabled by default in the upper half of the screen, with in-player visibility and display controls. |
| 📱 **Pick on your phone, watch on TV** | Receive casts from the Bilibili mobile app, resume at the supplied position, and pause, play, or seek from your phone. TV playback continues after the phone disconnects. |
| 🔐 **Your viewing space** | QR-code login, favorites, history, Watch Later, and creator follows. Tokens and account cookies are stored in the device Keychain. |

### 4K and high-bitrate playback improvements for overseas networks

Upstream already supports 4K, CDN probing, and switching CDNs when playback stalls. BiliLiving builds on that foundation by replacing the fixed 15-second forward-buffer target for regular continuous video playback with **30 seconds, 2 minutes, or 5 minutes**, defaulting to **2 minutes**. The extra buffer is intended to absorb brief throughput drops on cross-border connections, helping viewers in the US and other overseas regions avoid repeated buffering during high-bitrate playback.

- Adjust the target immediately under **播放设置 → 视频预缓冲** (Playback Settings → Video Buffer) in the player. Try 5 minutes on more variable connections.
- Startup and seeking temporarily use a shorter buffer before restoring the longer target. Playback does not wait for the full 2 or 5 minutes to download.
- A new “Best available” default and playlists limited to the selected quality reduce automatic downgrades after choosing a quality such as 4K.

These durations are targets requested from AVPlayer. Actual buffering depends on the system and network; sustained insufficient bandwidth can still cause stalls. See the [buffering strategy](docs/PLAYBACK-BUFFERING.md) (Chinese) for implementation and validation limits.

### Recover HD playback from a low-resolution phone cast link

Upstream already supports fetching streams for casts that include video identifiers. BiliLiving adds a path for a different case: **the phone sends only a plain DLNA media URL, without an AV/BV identifier**. The TV extracts a CID from a trusted Bilibili URL, searches using the title, and verifies an exact CID match against Bilibili's video-part data. If the match succeeds and the TV is signed in, it opens the native player and fetches fresh streams.

Even if the phone's cast controls only show 720p, the TV can request server-authorized 1080p/4K options using its own account, along with danmaku and playback settings. **Available quality depends on the TV account's permissions, the source video, and the server response; this does not bypass membership requirements.** Guests and unsuccessful matches retain the original phone-provided link, avoiding the wrong video or a downgrade of the existing stream. See the [casting guide](docs/CASTING.md) (Chinese).

<a id="preview"></a>

## Preview

<p align="center">
  <img src="docs/screenshots/home.png" alt="BiliLiving Discover screen with large artwork and video cards" width="960">
</p>

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/player-danmaku.png" alt="Video playback with danmaku"><br><strong>Playback &amp; danmaku</strong></td>
    <td width="50%"><img src="docs/screenshots/video-detail.png" alt="Video details"><br><strong>Video details</strong></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/casting.png" alt="Profile screen with casting controls"><br><strong>Phone casting</strong></td>
    <td width="50%"><img src="docs/screenshots/guest-mode.png" alt="Guest mode and sign-in entry"><br><strong>Guest &amp; account access</strong></td>
  </tr>
</table>

Screenshots show an earlier development build. Labels such as “1080p preferred” may differ from the current version; the feature descriptions above reflect current behavior. Screenshots show the Chinese UI.

<a id="quick-start"></a>

## Quick Start

Build from source for now. The app is not distributed through the App Store or TestFlight.

### Run in the simulator

You need macOS, Xcode, and an installed tvOS Simulator runtime. Clone the repository:

```sh
git clone https://github.com/sixpluszero/BiliLiving.git
cd BiliLiving
open BilibiliLive.xcodeproj
```

Wait for Swift Package Manager to resolve dependencies, select the **BilibiliLive** scheme and an Apple TV simulator, then click **Run**. The project retains its upstream target name; the installed app is called **BiliLiving**.

Alternatively, use the script. List your local simulators and replace the placeholder with an Apple TV simulator's UDID:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl list devices available
export BILILIVING_SIMULATOR_ID="<APPLE_TV_SIMULATOR_UDID>"
./scripts/run-simulator.sh
```

Scripts use `/Applications/Xcode.app` by default. Override `DEVELOPER_DIR` if needed; changing the global `xcode-select` setting is unnecessary. Recorded validation used Xcode 26.6 / tvOS 26.5 / Apple TV 4K (3rd generation, 1080p) Simulator.

### Install on Apple TV

Connect and select your Apple TV in Xcode. Choose your development team under **Signing & Capabilities**, and change the Bundle Identifier if signing requires it (default: `com.jialin.BiliLiving`). Run after configuring signing.

### Start watching

1. Browse the home screen as a guest, or open **我的 → 扫码登录** (Profile → QR login) and confirm in the Bilibili mobile app.
2. Open **搜索** (Search), enter a query, select a video, and start playback from its detail screen.
3. Adjust quality, danmaku, or speed in the player controls. Manual quality changes preserve playback position and pause state.
4. After signing in, access favorites, history, and Watch Later from **我的** (Profile), or follow creators from the player.

Use arrow keys, Return, and Escape in the simulator. Siri Remote dictation requires a physical-device check; it is keyboard dictation, not a system-wide Siri search integration.

<a id="casting"></a>

## Phone Casting

1. Connect your phone and Apple TV to the same local network, and keep BiliLiving in the foreground.
2. In **我的** (Profile), enable casting and confirm the status says “等待手机投屏” (Waiting for a cast).
3. Open a video in the Bilibili mobile app, tap its cast button, and select **BiliLiving · 小电视**.
4. Continue watching on the TV, using your phone to pause, resume, or seek.

Casting is enabled on fresh installs; upgrades keep the existing setting. Guests can receive casts too. Casting does not sign the TV into your phone's account; when the TV fetches a new stream, access and quality depend on the TV account. This is not an AirPlay receiver.

See the [casting guide](docs/CASTING.md) (Chinese) for protocol support, troubleshooting, and verification history.

<a id="development"></a>

## Development & Contributions

Fixes, usability improvements, and documentation updates are welcome. Include your tvOS version, device, login state, and reproduction steps when reporting a problem. For casting, also include the phone OS and Bilibili app version. Remove tokens, cookies, and signed video URLs from logs before sharing them.

Run tests using the simulator configured above:

```sh
./scripts/test-simulator.sh
```

Some tests access live Bilibili APIs or the local network, so results depend on network and server behavior. The current records include an unresolved casting multicast-discovery timeout; they do not establish a fully passing suite. Premium quality levels and specific phone/TV combinations also need physical-device validation.

| Documentation (Chinese) | Contents |
| :--- | :--- |
| [Testing notes](docs/TESTING.md) | Verified behavior, build records, and outstanding checks |
| [Casting guide](docs/CASTING.md) | Usage, NVA / DLNA implementation, and compatibility boundaries |
| [Buffering strategy](docs/PLAYBACK-BUFFERING.md) | Playback buffering preferences and implementation |

Quality menus only show streams the server makes available for the current account and video. The app does not bypass membership or regional restrictions. Favorites, history, and final account authorization require an actual login; simulator tests cannot cover every physical-device behavior.

<a id="credits"></a>

## Credits & License

Thanks to [yichengchen/ATV-Bilibili-demo](https://github.com/yichengchen/ATV-Bilibili-demo) and its contributors for the player, Bilibili API integration, danmaku, account handling, and casting foundation. BiliLiving builds on that work with a living-room interface and experience improvements, preserving upstream commit history and copyright notices.

- **Upstream baseline:** [706aa63](https://github.com/yichengchen/ATV-Bilibili-demo/commit/706aa63aee68571700f4c09132b99c691427b93a), recorded in [UPSTREAM-COMMIT](docs/UPSTREAM-COMMIT).
- **Original project introduction:** [Upstream README](docs/UPSTREAM-README.md).
- **License:** [GPL-2.0](LICENSE.md). Follow its terms when distributing modified versions; provide the complete corresponding source and build scripts alongside IPA releases.

<p align="center"><a href="#top">Back to top ↑</a></p>
