#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_root=${script_dir:h}
configuration=${1:-release}
case "$configuration" in
    debug|release) ;;
    *)
        print -u2 -r -- "Unsupported configuration: $configuration (expected debug or release)"
        exit 64
        ;;
esac
bundle_root="$app_root/.build/$configuration/SkillBox.app"
contents="$bundle_root/Contents"
identity=${SKILLBOX_CODESIGN_IDENTITY:--}

cd "$app_root"
build_arguments=(-c "$configuration" --product SkillBox)
if [[ "$configuration" == "release" ]]; then
    build_arguments+=(
        -Xswiftc -gnone
        -Xswiftc -file-prefix-map
        -Xswiftc "$app_root=/SkillBoxSource"
    )
fi
swift build "${build_arguments[@]}"

/bin/rm -rf "$bundle_root"
/bin/mkdir -p "$contents/MacOS" "$contents/Resources"
/usr/bin/install -m 755 "$app_root/.build/$configuration/SkillBox" "$contents/MacOS/SkillBox"
/usr/bin/install -m 644 "$app_root/Config/Info.plist" "$contents/Info.plist"
/usr/bin/install -m 644 "$app_root/Resources/SkillBox.icns" "$contents/Resources/SkillBox.icns"
/usr/bin/install -m 644 "$app_root/Resources/Assets.car" "$contents/Resources/Assets.car"
/usr/bin/install -m 644 \
    "$app_root/Sources/SkillBoxCore/Resources/trusted-skills-catalog-v1.json" \
    "$contents/Resources/trusted-skills-catalog-v1.json"
agent_icon_source="$app_root/../design/ui/assets/agent-icons"
agent_icon_destination="$contents/Resources/AgentIcons"
/bin/mkdir -p "$agent_icon_destination"
for icon in \
    gpt.png \
    claude-code.png \
    workbuddy.png \
    zcode.png \
    kimi-code.png \
    cursor.png \
    hanaagent.png \
    pi.svg \
    deepseek-harness.svg \
    trae.png \
    gemini-cli.png
do
    /usr/bin/install -m 644 "$agent_icon_source/$icon" "$agent_icon_destination/$icon"
done
if [[ "$configuration" == "release" ]]; then
    /usr/bin/strip -S -x "$contents/MacOS/SkillBox"
fi
if [[ -n "${SKILLBOX_GITHUB_CLIENT_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SkillBoxGitHubClientID $SKILLBOX_GITHUB_CLIENT_ID" "$contents/Info.plist"
fi
if [[ -n "${SKILLBOX_GITHUB_INSTALL_URL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :SkillBoxGitHubInstallURL $SKILLBOX_GITHUB_INSTALL_URL" "$contents/Info.plist"
fi
/usr/bin/plutil -lint "$contents/Info.plist"
/usr/bin/xattr -cr "$bundle_root"
if [[ "$identity" == "-" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp=none --sign "$identity" "$bundle_root"
else
    /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$bundle_root"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle_root"

print -r -- "$bundle_root"
