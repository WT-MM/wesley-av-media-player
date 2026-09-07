"""The generated CTest fixture must exclude encoder contention."""
import json
import subprocess
import sys

inventory = json.loads(subprocess.check_output(['ctest', '--test-dir', sys.argv[1], '--show-only=json-v1'], text=True))
fixture = next(test for test in inventory['tests'] if test['name'] == 'avcodec_fixtures')
properties = {entry['name']: entry['value'] for entry in fixture['properties']}
assert properties.get('RUN_SERIAL') is True, properties
assert properties.get('RESOURCE_LOCK') == ['avcodec_fixture_generation'], properties
assert properties.get('FIXTURES_SETUP') == ['avcodec_media'], properties
print('fixture serialization and resource lock present in generated CTest metadata')
