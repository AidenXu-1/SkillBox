#!/bin/zsh
set -euo pipefail

app_root=${0:A:h:h}
cd "$app_root"

# SwiftPM occasionally leaves its test helper waiting when this network-heavy
# suite runs beside every other suite. Run all other tests together, then this
# suite one test at a time. Keeping each helper isolated avoids a reproducible
# post-suite hang in SwiftPM. The list is discovered at runtime so new tests
# cannot disappear from the release gate.
discovered_tests=$(swift test list)
test_identifiers=("${(@f)discovered_tests}")
source_tests=()
for identifier in "${test_identifiers[@]}"; do
    if [[ "$identifier" == SkillBoxCoreTests.SourceProviderTests/* ]]; then
        source_tests+=("$identifier")
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
run_log=""
trap '[[ -z "$run_log" ]] || rm -f -- "$run_log"' EXIT

# SwiftPM can exit successfully after running zero tests. Every batch must
# produce a non-empty Swift Testing result, including the deadline batches.
run_checked_tests() {
    run_log=$(mktemp "${TMPDIR:-/tmp}/SkillBox-tests.XXXXXX")
    local result=0
    swift test "$@" 2>&1 | tee "$run_log" || result=$?
    local output=$(<"$run_log")
    rm -f -- "$run_log"
    run_log=""
    if (( result != 0 )); then return "$result"; fi
    if [[ "$output" == *"No matching test cases were run"* ]] ||
       [[ ! "$output" =~ 'Test run with [1-9][0-9]* tests?' ]]; then
        print -u2 -r -- "No executed Swift tests were confirmed. Refusing an incomplete test run."
        return 65
    fi
}

run_checked_tests --skip "SourceProviderTests|${(j:|:)deadline_tests}"
for deadline_test in "${deadline_tests[@]}"; do
    run_checked_tests --filter "$deadline_test"
done

for identifier in "${source_tests[@]}"; do
    # Some toolchains list argument labels but filter the bare function name.
    # Keep the full suite/function identity, escaping regex punctuation, and
    # accept either the bare name or its argument suffix without prefix matches.
    filter=$(python3 -c 'import re, sys; print(re.escape(sys.argv[1].split("(", 1)[0]))' "$identifier")
    run_checked_tests --filter "^${filter}($|[(])"
done

python3 -m unittest discover -s Tests/Packaging -p 'test_*.py'
