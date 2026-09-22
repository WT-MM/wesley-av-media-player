import copy
import unittest
from compare_capture import analyze


class ComparisonTests(unittest.TestCase):
    def fixture(self):
        samples, windows = [], []
        for round in range(5):
            for profile, watts in [('wam', 10.2), ('reference', 10.4)]:
                base = len(windows) * 700
                block = dict(profile=profile, round=round)
                for index, phase in enumerate(('idle_before', 'recording', 'idle_after')):
                    start = base + index * 220
                    block[phase] = [start, start + 200]
                    for t in range(start, start + 201, 2):
                        power = watts if phase == 'recording' else 10
                        samples.append(dict(unix=t, UpdateTime=t, Voltage=10000,
                            Amperage=-power * 100, ExternalConnected=False, IsCharging=False))
                windows.append(block)
        return samples, windows

    def test_known_increment_and_paired_difference(self):
        samples, windows = self.fixture()
        result = analyze(samples, windows, 60)
        self.assertAlmostEqual(result['profiles']['wam']['incremental_watts'], .2)
        self.assertAlmostEqual(result['profiles']['wam']['raw_90min_battery_percentage_points'], .5)
        self.assertEqual(result['paired_comparisons'][0]['lower_measured_draw'], 'wam')

    def test_charging_stale_missing_and_duplicate_blocks_rejected(self):
        samples, windows = self.fixture()
        charged = copy.deepcopy(samples); charged[30]['ExternalConnected'] = True
        stale = copy.deepcopy(samples)
        for row in stale: row['UpdateTime'] = 0
        for altered, blocks in [(charged, windows), (stale, windows), (samples[10:], windows), (samples, windows + windows[:1]), (samples, windows[:2])]:
            with self.assertRaises(ValueError): analyze(altered, blocks, 60)

    def test_zero_delta_does_not_establish_advantage(self):
        samples, windows = self.fixture()
        for row in samples: row['Amperage'] = -1000
        result = analyze(samples, windows, 60)
        self.assertFalse(result['profiles']['wam']['resolved_positive_draw'])
        self.assertEqual(result['paired_comparisons'][0]['lower_measured_draw'], 'unresolved')


if __name__ == '__main__': unittest.main()
