"""Failure and concurrent publishers must not expose partially generated fixtures."""
import multiprocessing
import pathlib
import tempfile
import unittest

from native_avcodec_fixtures import publish


def writer(output, started, release, events, value):
    def build(stage):
        events.put(str(stage))
        started.set()
        if not release.wait(10):
            raise RuntimeError('publisher barrier timed out')
        (stage / 'packets').write_bytes(value * 100000)
        (stage / 'manifest.json').write_text(value.decode())
    publish(output, build)


class FixtureTransactionTest(unittest.TestCase):
    def test_failure_preserves_every_published_byte(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            output = pathlib.Path(temporary)
            (output / 'packets').write_bytes(b'accepted')
            (output / 'manifest.json').write_bytes(b'accepted-manifest')
            before = {p.name: p.read_bytes() for p in output.iterdir()}
            stages = []
            def failed(stage):
                stages.append(stage)
                (stage / 'packets').write_bytes(b'partial')
                raise RuntimeError('encoder failed')
            with self.assertRaisesRegex(RuntimeError, 'encoder failed'):
                publish(output, failed)
            self.assertEqual(before, {p.name: p.read_bytes() for p in output.iterdir()})
            self.assertFalse(stages[0].exists())

    def test_same_destination_serializes_and_scratch_is_unique(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as temporary:
            context = multiprocessing.get_context('spawn')
            events = context.Queue()
            started = [context.Event(), context.Event()]
            release = [context.Event(), context.Event()]
            workers = [context.Process(target=writer, args=(temporary, started[i], release[i], events, bytes([65+i]))) for i in range(2)]
            try:
                workers[0].start()
                self.assertTrue(started[0].wait(10))
                workers[1].start()
                self.assertFalse(started[1].wait(0.3), 'second encoder overlapped the first')
                release[0].set()
                self.assertTrue(started[1].wait(10))
                root = pathlib.Path(temporary)
                self.assertEqual((root / 'packets').read_bytes(), b'A' * 100000)
                release[1].set()
                for worker in workers:
                    worker.join(10)
                    self.assertEqual(worker.exitcode, 0)
                self.assertEqual((root / 'packets').read_bytes(), b'B' * 100000)
                self.assertEqual((root / 'manifest.json').read_text(), 'B')
                paths = [events.get(timeout=5), events.get(timeout=5)]
                self.assertNotEqual(*paths)
                self.assertTrue(all(not pathlib.Path(p).exists() for p in paths))
                self.assertEqual(sorted(p.name for p in root.iterdir()), ['manifest.json', 'packets'])
            finally:
                for worker in workers:
                    if worker.pid and worker.is_alive():
                        worker.terminate()
                        worker.join(5)


if __name__ == '__main__':
    unittest.main()
