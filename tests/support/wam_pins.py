"""packaging/pins.env as a dict, parsed the way CMake parses it."""
import pathlib
import re

PINS = dict(re.findall(r'^(WAM_[A-Z0-9_]+)=(.*)$',
                       (pathlib.Path(__file__).resolve().parents[2] / 'packaging/pins.env').read_text(),
                       re.M))
