# Thirteen original refusals: immutable high_pass_35 facts

Read-only FFprobe and CoreMedia inventories are retained in [fallback-facts.json](fallback-facts.json) and [coremedia-facts.log](coremedia-facts.log). PAR absent in a container is recorded as absent; CoreMedia's 1:1 default is stated separately. `tv` means limited range.

| File | Codec / pixel format / depth | Primaries / transfer / matrix / range | Coded size; PAR |
| --- | --- | --- | --- |
| warm_bridge_06.mp4 | h264 Main / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1920×1080; 5127:4912 |
| pine_valley_48.mp4 | h264 Main / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1920×1080; 5127:4912 |
| green_vista_85.mp4 | h264 High / yuv420p / 8 | bt709 / bt709 / bt709 / tv | 1280×720; absent (CoreMedia 1:1) |
| lake_summit_29.mp4 | hevc Main 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 1920×1080; absent (CoreMedia 1:1) |
| sunny_jetty_60.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×360; 1:1 |
| river_street_45.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 |
| pine_creek_47.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 |
| cedar_grove_48.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 404×720; 1:1 |
| cobalt_bay_46.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 404×720; 1:1 |
| green_park_61.mp4 | h264 High 10 / yuv420p10le / 10 | bt2020 / arib-std-b67 / bt2020nc / tv | 640×720; 1:1 |
| olive_crossing_24.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | bt709 / bt709 / bt709 / tv | 1194×814; 1:1 |
| quiet_street_22.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | bt709 / bt709 / bt709 / tv | 1222×992; 1:1 |
| copper_pier_21.mp4 | h264 High 4:4:4 Predictive / yuv444p / 8 | smpte170m / bt709 / smpte170m / tv | 638×464; 1:1 |

CoreMedia segment mappings, verbatim rational fields (high_pass_35 interval → target interval):

### warm_bridge_06.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=6000/90000 flags=1 high_pass_35.duration=491326/1000 flags=1 target.start=0/1000 flags=1 target.duration=491326/1000 flags=1 
```

### pine_valley_48.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=352434/90000 flags=1 high_pass_35.duration=7373/1000 flags=1 target.start=0/1000 flags=1 target.duration=7373/1000 flags=1 
```

### green_vista_85.mp4

```text
TRACK 1 soun
empty=1 high_pass_35.start=0/0 flags=0 high_pass_35.duration=192/10000 flags=1 target.start=0/10000 flags=1 target.duration=192/10000 flags=1 
empty=0 high_pass_35.start=2112/48000 flags=1 high_pass_35.duration=6815160/240000 flags=1 target.start=192/10000 flags=1 target.duration=6815160/240000 flags=1 
TRACK 2 vide
empty=0 high_pass_35.start=0/1 flags=1 high_pass_35.duration=2562891/90000 flags=1 target.start=0/1 flags=1 target.duration=2562891/90000 flags=1 
```

### lake_summit_29.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=321/600 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
TRACK 2 soun
empty=0 high_pass_35.start=1476/44100 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
TRACK 3 meta
empty=0 high_pass_35.start=42456/600 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
TRACK 4 meta
empty=0 high_pass_35.start=1/600 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
TRACK 5 meta
empty=0 high_pass_35.start=21/10000 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
TRACK 6 meta
empty=0 high_pass_35.start=42456/600 flags=1 high_pass_35.duration=13200/600 flags=1 target.start=0/600 flags=1 target.duration=13200/600 flags=1 
```

### sunny_jetty_60.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=55000/1000 flags=1 target.start=0/1000 flags=1 target.duration=55000/1000 flags=1 
```

### river_street_45.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=44000/1000 flags=1 target.start=0/1000 flags=1 target.duration=44000/1000 flags=1 
```

### pine_creek_47.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=55000/1000 flags=1 target.start=0/1000 flags=1 target.duration=55000/1000 flags=1 
```

### cedar_grove_48.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=55000/1000 flags=1 target.start=0/1000 flags=1 target.duration=55000/1000 flags=1 
```

### cobalt_bay_46.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=44000/1000 flags=1 target.start=0/1000 flags=1 target.duration=44000/1000 flags=1 
```

### green_park_61.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=1024/15360 flags=1 high_pass_35.duration=99000/1000 flags=1 target.start=0/1000 flags=1 target.duration=99000/1000 flags=1 
```

### olive_crossing_24.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=0/1500 flags=1 high_pass_35.duration=196600/3000 flags=1 target.start=0/3000 flags=1 target.duration=196600/3000 flags=1 
```

### quiet_street_22.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=0/1500 flags=1 high_pass_35.duration=180600/3000 flags=1 target.start=0/3000 flags=1 target.duration=180600/3000 flags=1 
```

### copper_pier_21.mp4

```text
TRACK 1 vide
empty=0 high_pass_35.start=0/1500 flags=1 high_pass_35.duration=52600/3000 flags=1 target.start=0/3000 flags=1 target.duration=52600/3000 flags=1 
```

All seven color-refused files carry ambient payload `002fe9a03d134042`: illuminance 314 lux, x=15635/50000, y=16450/50000. lake_summit_29 additionally carries Dolby Vision profile 8, level 4, RPU present, enhancement layer absent, base layer present, compatibility ID 4; its rotation is −90°. The six angel files are H.264 High 10, not HEVC. The three sample-format refusals are 8-bit 4:4:4, not 4:2:2 or Hi10P.
