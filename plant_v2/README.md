# TripLens Plant Model v2

This branch is the R&D integration track for the validated commandable plant baseline. It stays separate from the Competition RAW-only runner.

## Baseline scope

```text
TripLens Plant Model v2

Active baseline
├─ GT
├─ ST
├─ HRSG
└─ FWP-HP

Native but not command-enabled in this baseline
├─ FWP-IP  (PompeAlimMP)
└─ FWP-LP  (PompeAlimBP)

Explicitly excluded
├─ Condensate Pump
└─ CW Pump
```

The condensate and CW pumps are excluded because the pinned `CombinedCycle_TripTAC` has no standalone physical pump components for them. Do not synthesize them and do not create placeholder physics or tags.

FWP-IP/LP remain part of the inherited ThermoSysPro HRSG equations, but this v2 baseline does not claim their START/STOP/TRIP/RESET command adapters are implemented.

## Active physical bindings

The v2 builder starts from the pinned ThermoSysPro `CombinedCycle_TripTAC` equations and externalizes only sources that already exist in that plant.

- GT: external exhaust flow and temperature process-boundary inputs. The proven `606.94/893.75 -> 150/550` path is DERATING, not Trip.
- ST: inherited turbine/generator physics. `stTripCmd` closes the native HP/MP turbine admission commands as secondary shutdown physics.
- HRSG: inherited HP/MP/BP drum, heat-exchanger and controller physics.
- FWP-HP: native `PompeAlimHP` with external RPM input. `FWP_HP_RUN/STOP/TRIP/RESET`, VCB-A01 behavior and motor coast-down are owned and validated by the R&D ECMS pump state machine.

## NORMAL_100

```text
GT exhaust flow        606.94 kg/s
GT exhaust temperature 893.75 K
FWP-HP speed           1400 rpm
No command             hold normal operation
Physics exchange       0.1 s
Logic step             0.001 s
```

A normal operating state must be warmed to 300 s and then used as the initialization source for the 300-1000 s validation interval. Restart uses solved-state initialization rather than a new cold start.

The Windows normal-hold state currently used by the R&D environment is:

```text
C:/TripLensWarm/normal_hold_res.mat
```

No scheduled Trip is allowed in NORMAL_100.

## Validated HP-FWP physical evidence

The sealed R&D evidence uses the native `PompeAlimHP`, a 300 s NORMAL_100
solved state, the VCB-A01 trip/coast-down boundary, and a fixed-closed
post-transition topology. The OpenModelica DASSL run completed through 420 s.

- Canonical physics RAW: 300.0-420.0 s, 1201 rows, 0.1 s clock.
- FWP-HP RPM: 1400 rpm to the zero-speed gate.
- Native HP feedwater process-flow maximum change: 78.16231963375321 kg/s.
- HP drum level change: -0.3394437549784495 m.
- All HP/MP/BP drum level and pressure fields remained finite.
- No scenario answer label is emitted.

OpenModelica may eliminate the fixed-closed boundary-flow equation from CSV.
The RAW adapter may restore only the versioned numerical leak from the R&D
contract and must record that operation in provenance. It may not create a
field tag, alarm, command, or accident answer.
## FWP-HP command contract

```text
START
FWP_HP_RUN 0->1
 -> permissive
 -> breaker already closed
 -> motor acceleration
 -> RPM rise
 -> RUNNING

STOP
FWP_HP_RUN 1->0
 -> run disable
 -> VCB-A01 remains CLOSED
 -> RPM coast-down

TRIP
FWP_HP_TRIP=1
 -> trip latch
 -> VCB-A01 OPEN
 -> motor torque removed
 -> RPM coast-down
 -> thermo_speed_input_rpm -> fwpHpSpeedCmd

RESET
cause clear + run off + zero speed + breaker open
 -> clear latch only
 -> no reclose and no restart
```

FWP-HP motor/breaker timing constants are virtual-model R&D settings until approved plant/OEM values are supplied.

## Multi-rate contract

- ThermoSysPro physics exchange: `0.1 s`.
- ECMS/logic: `0.001 s`.
- Alarm persistence must use elapsed simulation time: `current_time - threshold_crossing_time`.
- Sample-count delay logic is prohibited.

## Repository boundary

R&D repository responsibilities:

- ThermoSysPro/FMUs and solved-state initialization
- MATLAB/Simulink ECMS state machines
- actuator and physical-response validation
- Plant Model v2 contracts

Competition RAW-only repository responsibilities:

- consume validated model/adapter outputs
- RAW -> ProcessBus -> DCS1/DCS2/ECMS
- Alarm Console and Blind Analysis input preparation

MATLAB/Simulink validation code must not be copied into the Competition repository.

## Completion gates for this baseline

1. NORMAL_100 warm-state simulation succeeds and major variables remain finite.
2. FWP-HP Trip opens VCB-A01 in the ECMS state machine.
3. FWP-HP coast-down RPM is delivered to the native `PompeAlimHP` input and produces a finite ThermoSysPro response.
4. GT Trip remains breaker-based (`52GT.CLOSED=0`); GT 150/550 remains DERATING.
5. No CW or condensate-pump physics/tag is introduced.
6. Blind RAW contains no scenario answer label.

FWP-IP/LP command integration, additional operating points and startup states are later R&D extensions and are not blockers for the v2 competition baseline.
