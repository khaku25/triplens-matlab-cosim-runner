# TripLens Plant Model v2 Integration Report

Date: 2026-09-09  
R&D repository: `khaku25/triplens-matlab-cosim-runner`  
Competition repository: `khaku25/triplens-thermosyspro-cloud-runner`

## Decision

The Plant Model v2 R&D baseline includes GT, ST, HRSG, and the native
ThermoSysPro HP feedwater pump (`PompeAlimHP`). The clean integration does
not include the concurrent MATLAB/Simulink 1 ms logic-export changes.

The HP-FWP physical boundary is ready for integration. A Blind Trip experiment
has not been run yet; it waits for the concurrent logic work and the final
closed-loop wiring check.

## Repository responsibility boundary

| Repository | Owns | Must not own |
|---|---|---|
| R&D | ThermoSysPro physics, solved-state initialization, FMU generation, HP-FWP speed-to-physics adapter, physical-response validation | Competition answer labels |
| Competition | Validated RAW consumption, ProcessBus, DCS1/DCS2/ECMS presentation, Alarm Console, Blind Analysis input | MATLAB/Simulink validation code or duplicate pump/check-valve physics |

## Files introduced by the clean R&D integration

- `plant_v2/README.md`
- `plant_v2/command_bus.json`
- `plant_v2/modelica/TripLens_Plant_V2_Normal100.mo`
- `plant_v2/operating_states.json`
- `plant_v2/plant_model_v2_contract.json`
- `plant_v2/scripts/build_plant_v2_cosim.py`
- `plant_v2/scripts/install_normal100_windows.ps1`
- `plant_v2/scripts/normalize_fwp_hp_raw.py`
- `plant_v2/scripts/validate_fwp_hp_raw.py`
- `plant_v2/scripts/validate_plant_v2.py`
- `.github/workflows/plant-model-v2-contract.yml`
- `.github/workflows/plant-model-v2-fmu.yml`
- `.github/workflows/plant-model-v2-normal100-capture.yml`
- `.github/workflows/fwp-hp-warmstart-native.yml`

No existing `ecms_pump_logic/` file, MATLAB file, Simulink model, or user logic
file is changed by this integration.

## GT Trip / DERATE audit

| Case | Command / boundary | Breaker requirement | Result |
|---|---|---|---|
| GT DERATE | 606.94 kg/s / 893.75 K to 150 kg/s / 550 K | `52GT.CLOSED=1` | Process derating only |
| GT TRIP | `GT_TRIP_CMD` through 86GT | `52GT.CLOSED=0`; ST intertrip requires `52ST.CLOSED=0` | Electrical Trip semantics |

The 150/550 boundary is never named or accepted as Trip. The Plant Model v2
contract audit passed:
https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34375127982

The native GT thermodynamic shutdown adapter remains explicitly pending. This
does not block HP-FWP physical integration, but it must be resolved before a
fully physical GT Trip Blind test is sealed.

## NORMAL_100 result

The physical validation performed a cold solve to 300 s, saved the complete
solved state, and restarted from 300 s to 1000 s with no scheduled command.

- GT exhaust flow: 606.94 kg/s
- GT exhaust temperature: 893.75 K
- HP/IP/LP feedwater source speed: 1400 rpm
- simulation completion: PASS
- all critical generator, HP/MP/BP drum pressure, and drum-level values: finite
- generator electrical output: 263110061.40 W at 300 s and 263109983.67 W at 1000 s
- HP drum level: 1.05000361 m at 300 s and 1.05001083 m at 1000 s
- solved-state SHA-256: `d05efdca27bfbc4247f996ddc49d3aa4fe28b6aab5abd1ece9f261cf34e61241`

Evidence:
https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34375132429

Installation of this state on a self-hosted Windows runner is an opt-in
deployment step. It is not part of the physical PASS gate.

## HP-FWP physical integration

Validated path:

`RPM coastdown boundary -> fwpHpSpeedCmd -> native PompeAlimHP -> feedwater and drum response`

The physical adapter keeps the native plant topology. It does not add a
Competition-side motor, pump, or check valve. A speed-coupled R&D discharge
isolation handles the short 300-301 s transition, followed by a fixed-closed
post-transition topology with a versioned numerical leakage equation.

Canonical RAW result:

- range: 300.0-420.0 s
- rows: 1201
- physics RAW clock: 0.1 s
- RPM: 1400 rpm to zero-speed gate
- native HP process-flow maximum change: 78.16231963375321 kg/s
- HP drum-level change: -0.3394437549784495 m
- HP/MP/BP drum levels and pressures: finite
- scenario answer label: absent

OpenModelica may eliminate the fixed-closed leakage equation from its CSV. The
normalizer restores only the exact value from the versioned R&D contract and
records the restoration in provenance. It does not create a field tag, alarm,
command, or expected accident result.

Physical source evidence:
https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34366779559

Canonical RAW revalidation:
https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34374439526

The clean candidate workflow's physics/solver prefix is byte-identical to the
successful physical source workflow. Its normalizer and validator blob SHAs
also exactly match the revalidated PASS versions.

Motor coastdown, isolation, and numerical regularization constants are R&D
values pending plant/OEM approval.

## FMU result

The FMI 2.0 Co-Simulation source FMU contract passed. The pinned OpenModelica
image emitted a complete source-FMU tree rather than the final ZIP, so the
workflow now packages that unchanged tree deterministically and validates
`modelDescription.xml`, all required inputs/outputs, CoSimulation metadata,
and generated C sources.

Evidence:
https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34375441337

## Competition integration status

Competition PR #7 is the accepted RAW-only HP-FWP boundary:
https://github.com/khaku25/triplens-thermosyspro-cloud-runner/pull/7

It contains only:

- the HP-FWP R&D boundary contract,
- an audit workflow,
- a boundary audit script.

Its audit is passing. Competition PR #6 was closed without merge because it
duplicated pump/check-valve physics and combined HP/IP/LP plus protection logic
outside the agreed scope.

## Blind test readiness

| Gate | Status |
|---|---|
| NORMAL_100 physical baseline | PASS |
| Plant Model v2 contract | PASS |
| FMI 2.0 source FMU contract | PASS |
| HP-FWP RPM-to-native-physics response | PASS |
| Competition RAW-only boundary | PASS audit; merge follows R&D baseline |
| User's concurrent logic revision | In progress outside this PR |
| Closed-loop command/breaker/RPM wiring | Pending joint E2E check |
| Blind Trip experiment | Not started |

When both workstreams are complete, the test injects only the initiating
command. Expected breaker, RPM, flow, drum, and alarm results must be produced
by the simulation and must not be supplied to TripLens as an answer label.

Explicit exclusions remain in force: no CW Pump physics, no standalone
Condensate Pump physics, no fabricated tag, and no use of GT DERATE as Trip.
