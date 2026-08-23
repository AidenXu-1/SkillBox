#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_root=${script_dir:h}
repo_root=${app_root:h}
distribution_root="$app_root/.build/distribution"
stage_root=""
quarantine_root=""
source_manifest=""
app_bundle="$app_root/.build/release/SkillBox.app"

# Public GitHub builds deliberately use the checked-in GitHub App identity.
# Test-only overrides must never leak into a public package.
if [[ -n "${SKILLBOX_GITHUB_CLIENT_ID:-}" || -n "${SKILLBOX_GITHUB_INSTALL_URL:-}" ]]; then
    print -u2 -r -- "Public distribution does not accept GitHub identity overrides."
    exit 64
fi
if [[ -n "${SKILLBOX_CODESIGN_IDENTITY:-}" && "$SKILLBOX_CODESIGN_IDENTITY" != "-" ]]; then
    print -u2 -r -- "This release route is intentionally ad-hoc signed. Unset SKILLBOX_CODESIGN_IDENTITY."
    exit 64
fi
if [[ -n "${SKILLBOX_NOTARY_PROFILE:-}" ]]; then
    print -u2 -r -- "This release route is intentionally not notarized. Unset SKILLBOX_NOTARY_PROFILE."
    exit 64
fi

"$script_dir/test-all.sh"
SKILLBOX_CODESIGN_IDENTITY=- "$script_dir/package-app.sh" release

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
signature_details=$(/usr/bin/codesign --display --verbose=4 "$app_bundle" 2>&1)
if [[ "$signature_details" != *"Signature=adhoc"* ]]; then
    print -u2 -r -- "Release app must use an ad-hoc signature."
    exit 65
fi
if [[ "$signature_details" != *"TeamIdentifier=not set"* ]]; then
    print -u2 -r -- "Release app unexpectedly has a TeamIdentifier."
    exit 65
fi
if [[ "$signature_details" != *"runtime"* ]]; then
    print -u2 -r -- "Release app must enable Hardened Runtime."
    exit 65
fi
"$script_dir/verify-release-privacy.sh" "$app_bundle"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_bundle/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_bundle/Contents/Info.plist")
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_bundle/Contents/Info.plist")
minimum_os=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app_bundle/Contents/Info.plist")
if [[ -z "$version" || "$version" == *[^A-Za-z0-9._-]* ]]; then
    print -u2 -r -- "The app version is empty or unsafe for a distribution filename."
    exit 65
fi

dmg_name="SkillBox-$version.dmg"
dmg_path="$distribution_root/$dmg_name"
manifest_name="SkillBox-$version-release.json"
manifest_path="$distribution_root/$manifest_name"
checksum_name="SkillBox-$version.sha256"
checksum_path="$distribution_root/$checksum_name"

/bin/mkdir -p "$distribution_root"
stage_root=$(/usr/bin/mktemp -d "$distribution_root/stage.XXXXXX")
quarantine_root=$(/usr/bin/mktemp -d "$distribution_root/quarantine.XXXXXX")
source_manifest=$(/usr/bin/mktemp "$distribution_root/source.XXXXXX")
cleanup() {
    for target in "$stage_root" "$quarantine_root"; do
        if [[ -n "$target" && "$target" == "$distribution_root/"* && -d "$target" ]]; then
            /bin/rm -rf "$target"
        fi
    done
    if [[ -n "$source_manifest" && "$source_manifest" == "$distribution_root/"* && -f "$source_manifest" ]]; then
        /bin/rm -f "$source_manifest"
    fi
}
trap cleanup EXIT

/bin/rm -f "$dmg_path" "$manifest_path" "$checksum_path"
/usr/bin/ditto "$app_bundle" "$stage_root/SkillBox.app"
/usr/bin/install -m 644 "$app_root/Resources/INSTALL-GITHUB.txt" "$stage_root/安装说明.txt"
/bin/ln -s /Applications "$stage_root/Applications"

icon_check="$distribution_root/AppIconIntegrationCheck"
/usr/bin/xcrun swiftc \
    -framework AppKit \
    -framework Vision \
    "$app_root/Tests/Packaging/AppIconIntegrationCheck.swift" \
    -o "$icon_check"
"$icon_check" "$stage_root/SkillBox.app"
/bin/rm -f "$icon_check"

/usr/bin/hdiutil create \
    -volname "SkillBox $version" \
    -srcfolder "$stage_root" \
    -format UDZO \
    -ov \
    "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"

# Bind the artifact to the exact current source snapshot, including uncommitted
# and untracked non-ignored files, without falsely claiming that Git is clean.
(
    cd "$repo_root"
    /usr/bin/git ls-files -co --exclude-standard | LC_ALL=C /usr/bin/sort | while IFS= read -r relative; do
        [[ -f "$relative" ]] || continue
        file_hash=$(/usr/bin/git hash-object -- "$relative")
        print -r -- "$file_hash  $relative"
    done
) > "$source_manifest"
source_snapshot_sha256=$(/usr/bin/shasum -a 256 "$source_manifest" | /usr/bin/awk '{print $1}')
git_head=$(/usr/bin/git -C "$repo_root" rev-parse HEAD)
git_clean=true
if [[ -n "$(/usr/bin/git -C "$repo_root" status --porcelain --untracked-files=all)" ]]; then
    git_clean=false
fi

app_sha256=$(/usr/bin/shasum -a 256 "$app_bundle/Contents/MacOS/SkillBox" | /usr/bin/awk '{print $1}')
dmg_sha256=$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print $1}')
cdhash=$(print -r -- "$signature_details" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')
architectures=$(/usr/bin/lipo -archs "$app_bundle/Contents/MacOS/SkillBox")
generated_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')

# A quarantined disposable copy should not pass normal Gatekeeper assessment.
# Users intentionally proceed with System Settings > Privacy & Security > Open Anyway.
/usr/bin/ditto "$app_bundle" "$quarantine_root/SkillBox.app"
/usr/bin/xattr -w com.apple.quarantine "0081;$(/bin/date +%s);SkillBoxReleaseCheck;" "$quarantine_root/SkillBox.app"
set +e
gatekeeper_output=$(/usr/sbin/spctl --assess --type execute --verbose=4 "$quarantine_root/SkillBox.app" 2>&1)
gatekeeper_exit=$?
set -e
if (( gatekeeper_exit == 0 )); then
    gatekeeper_result="accepted-on-build-machine"
else
    gatekeeper_result="manual-approval-required"
fi

/usr/bin/plutil -create xml1 "$manifest_path"
/usr/bin/plutil -insert product -string "SkillBox" "$manifest_path"
/usr/bin/plutil -insert version -string "$version" "$manifest_path"
/usr/bin/plutil -insert build -string "$build" "$manifest_path"
/usr/bin/plutil -insert bundleIdentifier -string "$bundle_id" "$manifest_path"
/usr/bin/plutil -insert minimumMacOS -string "$minimum_os" "$manifest_path"
/usr/bin/plutil -insert architectures -string "$architectures" "$manifest_path"
/usr/bin/plutil -insert signing -string "adhoc-hardened-runtime" "$manifest_path"
/usr/bin/plutil -insert notarized -bool NO "$manifest_path"
/usr/bin/plutil -insert manualGatekeeperApprovalRequired -bool YES "$manifest_path"
/usr/bin/plutil -insert gatekeeperAssessment -string "$gatekeeper_result" "$manifest_path"
/usr/bin/plutil -insert gatekeeperAssessmentExitCode -integer "$gatekeeper_exit" "$manifest_path"
/usr/bin/plutil -insert gitHead -string "$git_head" "$manifest_path"
/usr/bin/plutil -insert gitClean -bool "$git_clean" "$manifest_path"
/usr/bin/plutil -insert sourceSnapshotSHA256 -string "$source_snapshot_sha256" "$manifest_path"
/usr/bin/plutil -insert appExecutableSHA256 -string "$app_sha256" "$manifest_path"
/usr/bin/plutil -insert diskImage -string "$dmg_name" "$manifest_path"
/usr/bin/plutil -insert diskImageSHA256 -string "$dmg_sha256" "$manifest_path"
/usr/bin/plutil -insert cdHash -string "$cdhash" "$manifest_path"
/usr/bin/plutil -insert generatedAt -string "$generated_at" "$manifest_path"
/usr/bin/plutil -convert json "$manifest_path"
/usr/bin/plutil -p "$manifest_path" >/dev/null

(
    cd "$distribution_root"
    /usr/bin/shasum -a 256 "$dmg_name" "$manifest_name"
) > "$checksum_path"

print -r -- "Gatekeeper simulation: $gatekeeper_result (exit $gatekeeper_exit)"
if [[ -n "$gatekeeper_output" ]]; then
    print -r -- "$gatekeeper_output"
fi
print -r -- "$dmg_path"
print -r -- "$manifest_path"
print -r -- "$checksum_path"
