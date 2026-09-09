# GT Trip native-seeded 3-input physical revalidation — 2026-09-09

- Source workflow run: `34311992702`
- Result: **PASS**
- Actual FMI Co-Simulation: `true`
- Native-state seed initialization: **PASS**
- ST trip physical input held at zero for the whole run: `true`
- GT command: `606.94 kg/s / 893.75 K` -> `150.0 kg/s / 550.0 K` at t=5.0 s
- Stop time: `125.0 s`; FMI communication step: `0.1 s`

## ST electrical response

- Pre-trip: `263.108987703 MW`
- Minimum: `159.113478644 MW`
- Final: `159.113478644 MW`
- Minimum change vs pre-trip: `-39.525639%`
- Final change vs pre-trip: `-39.525639%`

## Drum level final minus pre-trip

- HP: `0.199259250 m`
- IP: `0.340012586 m`
- LP: `-0.139693905 m`

## Isolation checks

- HP admission valve stayed at native 0.8: `True`
- MP admission valve stayed at native 0.8: `True`
- Strong trip-like gate (ST drop <= -70%): `False`
- Moderate derating gate (-70% < drop <= -20%): `True`
- Weak-response gate (drop > -20%): `False`

Interpretation gates are model-response labels for this virtual model, not plant protection settings.
