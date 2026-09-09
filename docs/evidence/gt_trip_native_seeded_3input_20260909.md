# GT 150/550 native-seeded physical test — reclassified as DERATING (2026-09-09)

> **Canonical classification changed:** this completed run is retained as immutable numerical evidence, but it is **not a Trip validation anymore**. TripLens now defines `TRIP` by the associated breaker reaching `CLOSED=0`. The `606.94/893.75 -> 150/550` exhaust-boundary change did not itself open 52GT and is therefore classified as **GT DERATING / output reduction**.

- Source workflow run: `34311992702`
- Historical execution result: **PASS**
- Actual FMI Co-Simulation: `true`
- Native-state seed initialization: **PASS**
- ST trip physical input held at zero for the whole run: `true`
- GT derating boundary: `606.94 kg/s / 893.75 K` -> `150.0 kg/s / 550.0 K` at t=5.0 s
- Stop time: `125.0 s`; FMI communication step: `0.1 s`
- Breaker-open Trip validation: **NOT PERFORMED BY THIS RUN**

## ST electrical response to GT exhaust derating

- Pre-change: `263.108987703 MW`
- Minimum: `159.113478644 MW`
- Final: `159.113478644 MW`
- Minimum change vs pre-change: `-39.525639%`
- Final change vs pre-change: `-39.525639%`

## Drum level final minus pre-change

- HP: `0.199259250 m`
- IP: `0.340012586 m`
- LP: `-0.139693905 m`

## Isolation checks

- HP admission valve stayed at native 0.8: `True`
- MP admission valve stayed at native 0.8: `True`
- Strong trip-like gate (historical label): `False`
- Moderate derating gate: `True`
- Weak-response gate: `False`

The original JSON is preserved for reproducibility even though some historical field names contain `trip`. For all new TripLens logic and reports, `TRIP` means the associated breaker `CLOSED` feedback becomes `0`; process-value reduction without breaker opening is `DERATING`.
