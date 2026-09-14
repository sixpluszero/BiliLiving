#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BILILIVING_SIMULATOR_ID="${BILILIVING_SIMULATOR_ID:-C3487C92-2D04-44AD-A9A0-E62EEBA2C4B6}"
xcodebuild -project BilibiliLive.xcodeproj -scheme BilibiliLive -configuration Debug -sdk appletvsimulator -destination "platform=tvOS Simulator,id=$BILILIVING_SIMULATOR_ID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
xcrun simctl boot "$BILILIVING_SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$BILILIVING_SIMULATOR_ID" -b
xcrun simctl install "$BILILIVING_SIMULATOR_ID" build/Build/Products/Debug-appletvsimulator/BilibiliLive.app
xcrun simctl launch "$BILILIVING_SIMULATOR_ID" com.jialin.BiliLiving
open -a Simulator
