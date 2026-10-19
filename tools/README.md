# Latency measurement tools

- `refbeep.swift` — plays short beeps at exact wall-clock times (T0+1 s … T0+N s),
  sample-accurately, on the built-in speaker or the default output:
  `swiftc -O refbeep.swift -o refbeep && ./refbeep @<T0_epoch_us> 1 30 2000`
- `onsets.py` — finds beep onsets in a phone recording (two bandpass-filtered
  tracks, e.g. 2 kHz Mac reference vs 1 kHz Hub beep) and prints the delay
  of each Hub beep after its Mac beep.

Method used for the measured ~0.36 s: a 1 kHz beep process is captured by
nestcast (`--pid <pid> --mute`, so it plays only on the Hub) while a 2 kHz
reference plays on the Mac speaker at the same instants; a phone records both.
