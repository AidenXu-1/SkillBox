#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_root=${script_dir:h}
repo_root=${app_root:h}
bundle=${1:-"$app_root/.build/release/SkillBox.app"}

if [[ ! -d "$bundle" || "$bundle" != *.app ]]; then
    print -u2 -r -- "Expected an app bundle: $bundle"
    exit 64
fi

required_files=(
    "Contents/Info.plist"
    "Contents/MacOS/SkillBox"
    "Contents/Resources/Assets.car"
    "Contents/Resources/SkillBox.icns"
    "Contents/_CodeSignature/CodeResources"
)
for relative in "${required_files[@]}"; do
    if [[ ! -f "$bundle/$relative" ]]; then
        print -u2 -r -- "Release bundle is missing $relative"
        exit 65
    fi
done

unexpected=$(/usr/bin/find "$bundle" -type f -print | while IFS= read -r path; do
    relative=${path#"$bundle/"}
    if (( ${required_files[(Ie)$relative]} == 0 )); then
        print -r -- "$relative"
    fi
done)
if [[ -n "$unexpected" ]]; then
    print -u2 -r -- "Release bundle contains unexpected files:"
    print -u2 -r -- "$unexpected"
    exit 65
fi
if /usr/bin/find "$bundle" -type l -print -quit | /usr/bin/grep -q .; then
    print -u2 -r -- "Release bundle must not contain symbolic links."
    exit 65
fi
unexpected_xattrs=$(/usr/bin/find "$bundle" -print | while IFS= read -r path; do
    /usr/bin/xattr "$path" 2>/dev/null | while IFS= read -r attribute; do
        # macOS 26 adds this two-byte system provenance marker to locally
        # created files. It contains no developer identity or source path.
        if [[ "$attribute" != "com.apple.provenance" ]]; then
            print -r -- "$path: $attribute"
        fi
    done
done)
if [[ -n "$unexpected_xattrs" ]]; then
    print -u2 -r -- "Release bundle contains unexpected extended attributes:"
    print -u2 -r -- "$unexpected_xattrs"
    exit 65
fi

private_pattern='/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|AidenWorkflow|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|[A-Za-z0-9._%+-]+@(gmail|qq|163|icloud|outlook)\.[A-Za-z]{2,}'
if /usr/bin/find "$bundle" -type f -exec /usr/bin/grep -aE -q "$private_pattern" {} +; then
    print -u2 -r -- "Release bundle contains a forbidden private path or credential-like value."
    exit 66
fi

rg_path=$(command -v rg || true)
if [[ -z "$rg_path" ]]; then
    print -u2 -r -- "Release privacy verification requires ripgrep (rg)."
    exit 69
fi
if (
    cd "$repo_root"
    "$rg_path" -n --hidden \
        -g '!app/.build/**' \
        -g '!app/Tests/**' \
        -g '!app/Scripts/verify-release-privacy.sh' \
        -g '!scratch/**' \
        '/Users/[A-Za-z0-9._-]+|AidenWorkflow' \
        README.md app docs design >/dev/null
); then
    print -u2 -r -- "Repository contains a developer-local path outside test fixtures."
    exit 66
fi

print -r -- "Release privacy verification passed."
