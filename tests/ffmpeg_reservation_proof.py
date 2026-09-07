"""Compile the production allocator implementation in a bounded standalone harness."""
import pathlib,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='wam-allocator-proof-',dir='/private/tmp') as root:
 binary=str(pathlib.Path(root)/'test')
 subprocess.run(['clang','-std=c11',str(repo/'tests/ffmpeg_reservation_test.c'),'-o',binary],check=True)
 subprocess.run([binary],check=True)
