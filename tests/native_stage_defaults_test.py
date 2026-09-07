"""Exercise independent native stage defaults using CMake's option evaluator."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[1]
high_pass_35 = (repo / 'CMakeLists.txt').read_text()
start = high_pass_35.index('option(WAM_ENABLE_AVFORMAT_STAGE')
end = high_pass_35.index('  if(NOT APPLE', start)
# Stop before the runtime implementation; evaluate the actual option contract.
options = high_pass_35[start:end].rsplit('if(', 1)[0]
with tempfile.TemporaryDirectory(prefix='wam-stage-options-', dir='/private/tmp') as directory:
    script = pathlib.Path(directory) / 'options.cmake'
    script.write_text('set(APPLE TRUE)\n' + options + '''
if(NOT WAM_ENABLE_AVFORMAT_STAGE OR WAM_ENABLE_AVCODEC_STAGE)
  message(FATAL_ERROR "ShippedStageDefaultsMismatch")
endif()
''')
    subprocess.run(['cmake', '-P', str(script)], check=True)
print('PASS demux defaults ON independently of codec OFF')
