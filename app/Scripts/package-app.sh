#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_root=${script_dir:h}
configuration=${1:-release}
bundle_root="$app_root/.build/$configuration/SkillBox.app"
contents="$bundle_root/Contents"
identity=${SKILLBOX_CODESIGN_IDENTITY:--}

cd "$app_root"
swift build -c "$configuration" --product SkillBox

/bin/mkdir -p "$contents/MacOS" "$contents/Resources"
/usr/bin/install -m 755 "$app_root/.build/$configuration/SkillBox" "$contents/MacOS/SkillBox"
/usr/bin/install -m 644 "$app_root/Config/Info.plist" "$contents/Info.plist"
if [[ -n "${SKILLBOX_GITHUB_CLIENT_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SkillBoxGitHubClientID $SKILLBOX_GITHUB_CLIENT_ID" "$contents/Info.plist"
fi
if [[ -n "${SKILLBOX_GITHUB_INSTALL_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SkillBoxGitHubInstallURL $SKILLBOX_GITHUB_INSTALL_URL" "$contents/Info.plist"
fi
/usr/bin/plutil -lint "$contents/Info.plist"
if [[ "$identity" == "-" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" "$bundle_root"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$bundle_root"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle_root"

print -r -- "$bundle_root"
