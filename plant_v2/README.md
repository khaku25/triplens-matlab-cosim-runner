# TripLens Plant Model v2

This branch is the integration track for the final commandable plant model.
It is intentionally isolated from `main` so ongoing ECMS, FMU, alarm and UI work can continue without merge collisions.

## Target architecture

```text
TripLens Plant Model v2

Physics
├─ GT
├─ ST
├─ HRSG
├─ FWP-HP Dynamic
├─ FWP-IP Dynamic
├─ FWP-LP Dynamic
├─ Condensate Pump Dynamic
└─ CW Pump Dynamic

Operating States
├─ NORMAL_100
├─ NORMAL_75
├─ NORMAL_50
└─ COLD / STARTUP

Commands
├─ START
├─ STOP
├─ TRIP
├─ RESET
├─ Breaker OPEN/CLOSE
└─ Valve command
```

## What is physically active now

The v2 builder starts from the pinned ThermoSysPro `CombinedCycle_TripTAC` equations and externalizes only sources that already exist in that plant.

- GT: external exhaust flow and temperature command inputs.
- ST: inherited native turbine/generator physics.
- HRSG: inherited HP/MP/BP drum, heat exchanger and controller physics.
- FWP-HP: `PompeAlimHP` native pump with external RPM command. The separate ECMS HP pump START/STOP/TRIP/RESET/breaker/coast-down state machine is already validated in Windows MATLAB R2025b.
- FWP-IP: `PompeAlimMP` native pump with external RPM command. ECMS operation state machine is not yet implemented.
- FWP-LP: `PompeAlimBP` native pump with external RPM command. ECMS operation state machine is not yet implemented.

All three existing feedwater-pump speed sources start at the model-native 1400 rpm.

## What is deliberately not faked

The current pinned `CombinedCycle_TripTAC` has only the HP/MP/BP feedwater centrifugal pumps. A dedicated condensate pump and circulating-water pump are not present in the current plant model. Their v2 module slots are reserved, but they remain disabled until real physical components and circuits are added.

Likewise `NORMAL_75`, `NORMAL_50`, and `COLD_START` are state-registry slots, not guessed initial conditions. They require a physically defined operating point/startup sequence and a consistent full-state capture.

## NORMAL_100 behavior

`NORMAL_100` is the existing normal-hold baseline:

```text
GT exhaust flow        606.94 kg/s
GT exhaust temperature 893.75 K
FWP HP/IP/LP speed     1400 rpm
no command             -> hold normal operation
```

The Windows normal-hold state is currently installed as:

```text
C:/TripLensWarm/normal_hold_res.mat
```

No automatic GT trip is scheduled in this baseline.

## Command boundary

Plant Model v2 separates discrete equipment commands from continuous physical inputs.

```text
ECMS / command layer
START STOP TRIP RESET BREAKER_OPEN BREAKER_CLOSE
       ↓
validated equipment state machine
       ↓
motor / breaker / valve physical command
       ↓
TripLens_Plant_V2_CoSim
       ↓
ThermoSysPro response
```

For FWP-HP this translation already exists in `ecms_pump_logic/build_fwp_hp_operation.m`.
For FWP-IP/LP the physical RPM ports exist in v2 but the command state machines must still be built and validated.

`VALVE_POSITION` is a reserved command type. It must not be wired to an arbitrary valve until the target valve and ownership/control mode are explicitly defined.

## Build

After preparing the pinned ThermoSysPro source at `legacy_exact/vendor/ThermoSysPro`:

```bash
python3 plant_v2/scripts/build_plant_v2_cosim.py
```

Generated class:

```text
plant_v2/build/TripLens_Plant_V2_CoSim.mo
```

The generated model exposes these current physical inputs:

```text
gtExhaustFlowCmd
gtExhaustTemperatureCmd
fwpHpSpeedCmd
fwpIpSpeedCmd
fwpLpSpeedCmd
```

and physical feedback including ST power, three drum levels/pressures, three applied pump speeds, and three native feedwater-pump mass flows.

## Completion gates

Plant Model v2 is not called fully complete until all of the following are true:

1. NORMAL_100 no-command regression remains stable.
2. FWP-HP discrete commands drive the external HP pump speed port and native process response.
3. FWP-IP and FWP-LP receive equivalent validated state machines.
4. Condensate and CW pump physical circuits are explicitly added and validated.
5. NORMAL_75 and NORMAL_50 full-state snapshots are captured from physically defined steady operating points.
6. COLD/STARTUP has a startup sequence and consistent state model; it is not a zero-value preset.
7. Breaker OPEN/CLOSE remains separate from START/STOP.
8. Valve commands are bound only to named validated valves.
9. No-command operation changes nothing by itself.
10. Blind-test raw physics contains no scenario answer labels.

## Branch policy

Development is on `plant-model-v2`. Do not merge into `main` until the contract workflow passes and the current main branch is re-compared for concurrent changes.
