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

# These tests measure short UI deadlines. Other @MainActor tests can occupy
# their executor before timers start. Run them independently, preserving all
# original timing assertions, and require discovery so none can be skipped.
deadline_tests=(discoveryPlanningDeadlineStillDeliversFinalCandidate deletionNoticePausesAndCloses)
for deadline_test in "${deadline_tests[@]}"; do
    if [[ "${(j: :)test_identifiers}" != *"$deadline_test"* ]]; then
        print -u2 -r -- "UI deadline test $deadline_test was not discovered. Refusing an incomplete test run."
        exit 65
    fi
done
swift test --skip "SourceProviderTests|${(j:|:)deadline_tests}"
for deadline_test in "${deadline_tests[@]}"; do
    swift test --filter "$deadline_test"
done

batch_size=1
for (( offset = 1; offset <= ${#source_tests[@]}; offset += batch_size )); do
    batch=("${source_tests[@]:$((offset - 1)):$batch_size}")
    filter="${(j:|:)batch}"
    swift test --filter "$filter"
done

python3 -m unittest discover -s Tests/Packaging -p 'test_rollback_backups.py'
