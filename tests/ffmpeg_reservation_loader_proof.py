"""Verify that the production allocator's thread association permits dlclose."""
import pathlib,subprocess,sys,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(repo/'tests/support'))
from wam_pins import PINS  # noqa: E402
with tempfile.TemporaryDirectory(prefix='wam-allocator-loader-',dir='/private/tmp') as directory:
 root=pathlib.Path(directory);lib=root/PINS['WAM_NATIVE_AVUTIL_DYLIB'];probe=root/'probe'
 subprocess.run(['clang','-std=c11','-dynamiclib',str(repo/'tests/ffmpeg_reservation_library.c'),'-o',str(lib)],check=True)
 subprocess.run(['clang',str(repo/'tests/ffmpeg_reservation_loader_test.c'),'-o',str(probe)],check=True)
 subprocess.run([str(probe),str(lib)],check=True)
