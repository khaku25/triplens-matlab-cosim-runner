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
