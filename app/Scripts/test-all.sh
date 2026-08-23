#!/bin/zsh
set -euo pipefail

app_root=${0:A:h:h}
cd "$app_root"

# SwiftPM occasionally leaves its test helper waiting when this network-heavy
# suite runs beside every other suite. Run all other tests together, then this
# suite one test at a time. Keeping each helper isolated avoids a reproducible
# post-suite hang in SwiftPM. The list is discovered at runtime so new tests
# cannot disappear from the release gate.
test_identifiers=("${(@f)$(swift test list)}")
source_tests=()
for identifier in "${test_identifiers[@]}"; do
    if [[ "$identifier" == SkillBoxCoreTests.SourceProviderTests/* ]]; then
        source_tests+=("${identifier##*/}")
    fi
done

if (( ${#source_tests[@]} == 0 )); then
    print -u2 -r -- "No SourceProviderTests were discovered. Refusing an incomplete test run."
    exit 65
fi

swift test --skip 'SourceProviderTests'

batch_size=1
for (( offset = 1; offset <= ${#source_tests[@]}; offset += batch_size )); do
    batch=("${source_tests[@]:$((offset - 1)):$batch_size}")
    filter="${(j:|:)batch}"
    swift test --filter "$filter"
done
