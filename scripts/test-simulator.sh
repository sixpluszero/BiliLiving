#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BILILIVING_SIMULATOR_ID="${BILILIVING_SIMULATOR_ID:-C3487C92-2D04-44AD-A9A0-E62EEBA2C4B6}"
xcodebuild -project BilibiliLive.xcodeproj -scheme BilibiliLive -configuration Debug -destination "platform=tvOS Simulator,id=$BILILIVING_SIMULATOR_ID" -derivedDataPath build -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" CODE_SIGNING_ALLOWED=NO test
