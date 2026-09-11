# TripLens MATLAB Co-Simulation Runner

Experimental runner for a separate TripLens digital-twin track.

This repository is intentionally isolated from `triplens-thermosyspro-cloud-runner` so the existing submission/demo pipeline remains untouched.

## Hosted MATLAB / OPC UA 52GT scenario

`matlab-native-opcua-ecms.yml` runs the pinned ThermoSysPro 3.1 combined-cycle
model with the TripLens HP/LP bypass and spray patch. The current scenario is:

`GT in service -> 52GT OPEN command -> observed 52GT.CLOSED 1->0 -> derived GT Trip -> OPC UA -> native ThermoSysPro response`

The OPEN command, breaker feedback, derived protection request, OPC UA
readback and physical latch are separate captured fields. Direct GT Trip is
not injected as the root cause. The breaker-open-to-Trip policy is a
provisional VPP rule; no actual plant ECMS logic or plant network is used.

## Goal

Run the co-simulation on the user's actual Windows MATLAB installation through a GitHub self-hosted runner, then connect:

1. ECMS electrical state / commands
2. ThermoSysPro process physics
3. Alarm/event generation
4. TripLens outputs

The first proof-of-concept is **HP BFP operation and trip**:

`FWP_HP_RUN / FWP_HP_TRIP / FWP_HP_RESET -> ECMS operation state machine -> VCB-A01 and motor-shaft state -> ThermoSysPro dynamic response -> CSV results`

Normal STOP and TRIP are intentionally different:

- Normal STOP removes the run enable, keeps `VCB-A01` closed, and lets RPM coast down.
- TRIP latches the trip, commands `VCB-A01` open after its operating delay, and lets RPM coast down.
- RESET does not reclose the breaker and does not restart the pump. Reclose and a new RUN edge are separate actions.
- START never closes the feeder breaker.

The operation core uses the model-native HP FWP speed of `1400 rpm` and exports `thermo_speed_input_rpm` for the native `PompeAlimHP.rpm_or_mpower` connection. No derivative protection and no process H/HH/L/LL alarm is active before the physical input is connected.

## Current stages

- `smoke`: verify the real MATLAB environment and local dependencies.
- `bfp-wrapper-check`: verify that the local ThermoSysPro `CombinedCycle_TripTAC.mo` contains the expected controllable pump and boundary connectors.
- `ecms-fwp-hp-operation`: build and test READY/STARTING/RUNNING/STOPPING/TRIPPED/RESET_WAIT, breaker actuation, RPM dynamics, reset and manual reclose in Simulink.
- `fwp-ramp-trip-native`: verify that the native ThermoSysPro HP FWP speed input produces process response. This is a process-side experiment, not an ECMS breaker-initiated trip.
- `bfp-cosim`: final external wiring between the validated ECMS operation output and the ThermoSysPro input/feedback.

## Local folders expected on the self-hosted PC

Set these environment variables on the runner PC or pass them when testing locally:

- `TRIPLENS_THERMOSYSPRO_ROOT`: folder containing `ThermoSysPro/package.mo`
- `TRIPLENS_OPENMODELICA_HOME`: optional OpenModelica install root; the scripts also search common Windows locations.

No files in the existing cloud-runner repository are required to be modified.

## ECMS/VVP Simulink automation

The existing Windows self-hosted runner can inspect and run a local ECMS/VVP
Simulink model without opening the MATLAB desktop.

Available workflow modes:

- `ecms-inventory`: load the model, record solver settings, block count, and
  root Inport/Outport names, then upload `outputs/ecms_inventory.json`.
- `ecms-simulate`: run the model with `sim`, then upload the simulation
  report and `outputs/ecms_simulation_output.mat`.

The model does not need to be committed. Configure the repository Actions
variable `TRIPLENS_ECMS_MODEL_PATH` with the absolute path to the local
`.slx` or `.mdl` file on the runner PC. If the existing MATLAB entry script
loads or creates exactly one Simulink model, `TRIPLENS_ECMS_MODEL_PATH` may
be omitted and `TRIPLENS_ECMS_INIT_SCRIPT` can point to that entry script.
Optionally set:

- `TRIPLENS_ECMS_INIT_SCRIPT`: absolute path to a MATLAB initialization script.
- `TRIPLENS_ECMS_STOP_TIME`: positive simulation stop time in seconds.

Workflow-dispatch inputs override those repository variables for one run. After
changing Windows user environment variables, restart the existing runner so the
runner process inherits them.

This automation is only for the isolated ECMS/VVP simulation model. Do not point
it at a live plant ECMS, operational network, or company production system.
