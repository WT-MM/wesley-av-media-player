import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from bench import normalize, distance, segments, boundary_alignment, quiet_snapshot, OutputCapture, QUIET_LOAD

class HarnessTest(unittest.TestCase):
    def test_librispeech_normalization(self):
        self.assertEqual(normalize("Don't—expand 21. FOO_BAR!"), ['DONTEXPAND','21','FOOBAR'])
    def test_edits(self):
        self.assertEqual(distance('A B C'.split(), 'A X C D'.split()), 2)
        self.assertEqual(distance([], ['A']), 1)
        self.assertEqual(distance(['A'], []), 1)
    def test_quiet_gate_fails_closed(self):
        with patch('bench.subprocess.check_output',return_value=f'load averages: {QUIET_LOAD-0.01:.2f} 7.00 8.00'), patch('bench.subprocess.run',return_value=SimpleNamespace(stdout='',returncode=0)):
            self.assertTrue(quiet_snapshot()['quiet'])
        with patch('bench.subprocess.check_output',return_value=f'load averages: {QUIET_LOAD:.2f} 1.00 1.00'), patch('bench.subprocess.run',return_value=SimpleNamespace(stdout='',returncode=0)):
            self.assertFalse(quiet_snapshot()['quiet'])
        with patch('bench.subprocess.check_output',return_value='load averages: 1.00 1.00 1.00'), patch('bench.subprocess.run',return_value=SimpleNamespace(stdout='',returncode=1)):
            self.assertFalse(quiet_snapshot()['quiet'])
        with patch('bench.subprocess.check_output',return_value='load averages: 1.00 1.00 1.00'), patch('bench.subprocess.run',return_value=SimpleNamespace(stdout='123 /usr/bin/clang++',returncode=0)):
            self.assertFalse(quiet_snapshot()['quiet'])
    def test_streamed_events_and_malformed_diagnostic(self):
        events = io.StringIO()
        capture = OutputCapture(events)
        capture.feed(b'{not JSON}\n{"event":"pre', 0.5)
        capture.feed(b'pared","seconds":0.2}\n', 0.8)
        capture.feed(b'[00:00:00.000 --> 00:00:01.000] Hello\n', 1.2)
        capture.feed(b'{"event":"segment","text":"later"}\n', 1.5)
        records = [json.loads(line) for line in events.getvalue().splitlines()]
        self.assertIn('parse_error', records[0])
        self.assertEqual(capture.prepare_time, 0.2)
        self.assertEqual(capture.ready, 0.8)
        self.assertEqual(capture.first, 1.2)
        self.assertEqual(len(records), 4)

    def test_srt_and_anchor(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp/wam-asr-scratch') as d:
            p=pathlib.Path(d)/'out.srt'
            p.write_text('1\n00:00:01,250 --> 00:00:04,000\nOne two three\nfour\n\n')
            seg=segments(p)
        self.assertEqual(seg[0]['start'],1.25)
        e={'utterances':[{'text':'ONE TWO THREE FOUR','start':1.0}]}
        a=boundary_alignment(e,seg)
        self.assertEqual(a['matched'],1)
        self.assertEqual(a['median_absolute'],.25)
        self.assertEqual(boundary_alignment(e,[])['matched'],0)
if __name__=='__main__': unittest.main()
