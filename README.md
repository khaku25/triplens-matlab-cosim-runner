# TripLens MATLAB Co-Simulation Runner

Experimental runner for a separate TripLens digital-twin track.

This repository is intentionally isolated from `triplens-thermosyspro-cloud-runner` so the existing submission/demo pipeline remains untouched.

## Goal

Run the co-simulation on the user's actual Windows MATLAB installation through a GitHub self-hosted runner, then connect:

1. ECMS electrical state / commands
2. ThermoSysPro process physics
3. Alarm/event generation
4. TripLens outputs

The first proof-of-concept is **HP BFP trip**:

`FWP_HP_TRIP -> pump speed command = 0 -> ThermoSysPro dynamic response -> CSV results`

## Current stages

- `smoke`: verify the real MATLAB environment and local dependencies.
- `bfp-wrapper-check`: verify that the local ThermoSysPro `CombinedCycle_TripTAC.mo` contains the expected controllable pump and boundary connectors.
- `bfp-cosim`: reserved for the next step, after the local ThermoSysPro/OpenModelica paths have passed validation.

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
