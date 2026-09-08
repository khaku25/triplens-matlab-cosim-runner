# A-program → ECMS → Thermo mapping

Source baseline: `khaku25/triplens-thermosyspro-cloud-runner@6fd1824880f97c957ba5a04013f3d789fb1dbd5d`

## 1. DCS logic inventory

The current A-program rule table contains 32 DCS alarm/protection judgement rules. They reduce to the following physical-signal families.

| A-program rule IDs | A source signal | Thermo source | ECMS role | Twin status |
|---|---|---|---|---|
| D1-001 | gt_trip_cmd | external command / GT boundary | ECMS GT TRIP command | CLOSED_LOOP_READY after GT command adapter |
| D1-010, D1-011 | gt_exhaust_mass_flow_kg_s | Debit.y.signal | display/alarm only | DIRECT_THERMO |
| D1-020, D1-021 | gt_exhaust_temperature_k | Temperature.y.signal | display/alarm only | DIRECT_THERMO |
| D1-030, D1-031, D1-032 | stg_power_w | Alternateur.Welec | ECMS.ST.MW | DIRECT_THERMO |
| D2-101..D2-104 | hp_drum_level_m | BallonHP.yLevel.signal / BallonHP.zl | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-111..D2-114 | ip_drum_level_m | BallonMP.yLevel.signal / BallonMP.zl | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-121..D2-124 | lp_drum_level_m | BallonBP.yLevel.signal / BallonBP.zl | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-201, D2-202 | hp_drum_pressure_pa | BallonHP.P | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-211, D2-212 | ip_drum_pressure_pa | BallonMP.P | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-221, D2-222 | lp_drum_pressure_pa | BallonBP.P | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-301, D2-302 | hp_steam_flow_kg_s | TurbineHP.Q | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-311, D2-312 | ip_steam_flow_kg_s | TurbineMP.Q | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |
| D2-321, D2-322 | lp_steam_flow_kg_s | TurbineBP.Q | DCS logic hosted in ECMS logic engine | DIRECT_THERMO |

### DCS logic result

- 31/32 rules are based on physical values already available directly from the validated ThermoSysPro model.
- D1-001 is a command-origin rule rather than a physical measurement rule and is already representable in the ECMS command contract.
- Therefore the current 32-rule DCS alarm table is structurally portable into an ECMS-hosted logic engine without inventing synthetic process values.

## 2. Process equipment links

| Equipment | ECMS command | Electrical attachment | Thermo feedback | Current status |
|---|---|---|---|---|
| FWP-HP | FWP_HP_TRIP / RUN / RESET | BUS-A / VCB-A01 / 6.9 kV | TSP.DRUM.HP.FW_FLOW | STRUCTURAL_1TO1_READY |
| FWP-IP | FWP_IP_TRIP / RUN / RESET | BUS-B / VCB-B01 / 6.9 kV | TSP.DRUM.IP.FW_FLOW | STRUCTURAL_1TO1_READY |
| FWP-LP | FWP_LP_TRIP / RUN / RESET | BUS-A / VCB-A02 / 6.9 kV | TSP.DRUM.LP.FW_FLOW | STRUCTURAL_1TO1_READY |
| STG | ST_TRIP / START / STOP | 52ST / TR-ST | TSP.GEN.ACTIVE_POWER | THERMO_ADAPTER_REQUIRED |
| GTG | GT_TRIP / START / STOP | 52GT / TR-GT | GT exhaust boundary | GT_TRIP_CONNECTED; START/STOP adapter required |
| HP/IP/LP FWV | valve commands | process actuator | Thermo valve opening / LIC outputs | THERMO_ADAPTER_REQUIRED |
| HPCV/IPCV/LPCV | valve commands | ST actuator | Thermo turbine flow | THERMO_ADAPTER_REQUIRED |

## 3. Electrical/fault logic inventory

A-program fault presets currently include:

`gtg_breaker_fail`, `uat_a_fault`, `uat_b_fault`, `gt_transformer_receive_fail`, `st_transformer_receive_fail`, `bus_a_fault`, `bus_b_fault`, `grid_loss`, `relay_fail`, `ecms_comms_loss`.

| Fault family | ECMS object exists | Needs solved electrical physics | Can affect Thermo process |
|---|---:|---:|---:|
| GTG breaker fail | yes | yes | yes, through GT/ST auxiliary topology |
| UAT-A / UAT-B fault | yes | yes | yes, through connected motor power availability |
| TR-GT / TR-ST receive fail | yes | yes | yes |
| BUS-A / BUS-B fault | yes | yes | yes, through feeder/motor de-energization |
| Grid loss | yes | yes | yes |
| Relay fail | partial | yes, protection layer required | indirectly |
| ECMS comms loss | yes as logic/fault state | no physical V/I required | no direct Thermo effect unless command/feedback is inhibited |

## 4. What can be moved from A-program into ECMS now

The following can be moved without changing the Thermo physics model:

1. All 32 current DCS threshold/hysteresis/delay alarm rules.
2. Breaker/transformer/grid command state machines already represented by the ECMS command catalog.
3. Fault-state definitions and sequencing logic from A-program.
4. Alarm/event formatting and ordering logic.
5. Process-trip decisions whose input is a Thermo signal already present in `signal_map.json`.

## 5. What must NOT be copied as synthetic logic

The following must be solved by a physics layer rather than hard-coded into ECMS:

- Bus voltage and feeder current under faults.
- Relay pickup based on V/I/frequency.
- Motor electrical torque/power availability after breaker/bus events.
- Fault current magnitude and protection operating time where those depend on system impedance.
- Process response after a motor/valve/GT/ST action; this must come back from ThermoSysPro.

## 6. Target final architecture

```text
A-program logic inventory
        ↓ migrate
ECMS Logic + Command/State Engine
        ↕
Electrical Twin (V/I/f, relays, breakers, buses, transformers)
        ↕ power/availability/commands
ThermoSysPro Process Twin
        ↕ level/pressure/flow/power
ECMS Logic
        ↓
DCS1 / DCS2 / ECMS alarms → TripLens
```

The final comparison should therefore be **ECMS logic outputs versus Thermo/electrical physical states**, not A-program synthetic outputs versus Thermo. A-program becomes the migration source and regression oracle, not the final simulator.
