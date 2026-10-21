import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'Scripts/test-all.sh'
IDENTIFIERS = [
    'SkillBoxCoreTests.SourceProviderTests/plain()',
    'SkillBoxCoreTests.SourceProviderTests/parameterized(directory:)',
    'SkillBoxCoreTests.DeadlineTests/discoveryPlanningDeadlineStillDeliversFinalCandidate()',
    'SkillBoxCoreTests.DeadlineTests/deletionNoticePausesAndCloses()',
    'SkillBoxCoreTests.OtherTests/ordinary()',
]


class TestAllEntryTests(unittest.TestCase):
    def run_entry(self, scenario='normal'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bindir = root / 'bin'
            bindir.mkdir()
            events = root / 'events.jsonl'
            swift = bindir / 'swift'
            swift.write_text(f'#!{sys.executable}\n' + '''
import json, os, re, sys
ids = json.loads(os.environ['TEST_IDS'])
args = sys.argv[1:]
scenario = os.environ['TEST_SCENARIO']
if args == ['test', 'list']:
    if scenario == 'list-failure': sys.exit(9)
    print('\\n'.join(ids))
    sys.exit(0)
if scenario == 'execution-failure': sys.exit(7)
if '--filter' in args:
    expression = args[args.index('--filter') + 1]
    # SwiftPM lists parameter labels, while some toolchains filter the bare
    # function identity. Exercise both supported representations.
    matches = [x for x in ids if re.search(expression, x.split('(')[0] if scenario == 'bare-identities' else x)]
    if scenario == 'zero-source' and any('SourceProviderTests' in x for x in matches): matches = []
    if scenario == 'zero-deadline' and any('DeadlineTests' in x for x in matches): matches = []
else:
    matches = [ids[-1]]
    if scenario == 'zero-main': matches = []
if not matches:
    print('warning: No matching test cases were run')
    sys.exit(0)
with open(os.environ['TEST_EVENTS'], 'a') as stream:
    stream.write(json.dumps(matches) + '\\n')
print('✔ Test run with %d tests passed after 0.001 seconds.' % len(matches))
''')
            swift.chmod(0o755)
            python = bindir / 'python3'
            python.write_text(f'#!{sys.executable}\n' + '''
import os, sys
if '-m' in sys.argv:
    # Do not recursively launch this test suite from its own mock run.
    sys.exit(0)
os.execv(os.environ['TEST_REAL_PYTHON'], [os.environ['TEST_REAL_PYTHON']] + sys.argv[1:])
''')
            python.chmod(0o755)
            env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], TEST_IDS=json.dumps(IDENTIFIERS), TEST_EVENTS=str(events), TEST_SCENARIO=scenario, TEST_REAL_PYTHON=sys.executable)
            result = subprocess.run(['/bin/zsh', str(SCRIPT)], env=env, text=True, capture_output=True, timeout=20)
            executed = [x for line in events.read_text().splitlines() for x in json.loads(line)] if events.exists() else []
            return result, executed

    def test_parameterized_and_each_discovered_test_actually_runs(self):
        result, executed = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertCountEqual(executed, IDENTIFIERS)

    def test_zero_matching_source_test_fails(self):
        result, _ = self.run_entry('zero-source')
        self.assertNotEqual(result.returncode, 0)

    def test_bare_execution_identities_still_run_every_parameterized_test(self):
        result, executed = self.run_entry('bare-identities')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertCountEqual(executed, IDENTIFIERS)

    def test_zero_matching_deadline_test_fails(self):
        result, _ = self.run_entry('zero-deadline')
        self.assertNotEqual(result.returncode, 0)

    def test_zero_matching_main_batch_fails(self):
        result, _ = self.run_entry('zero-main')
        self.assertNotEqual(result.returncode, 0)

    def test_execution_failure_is_not_hidden(self):
        result, _ = self.run_entry('execution-failure')
        self.assertNotEqual(result.returncode, 0)

    def test_failed_discovery_cannot_report_success(self):
        result, _ = self.run_entry('list-failure')
        self.assertNotEqual(result.returncode, 0)
