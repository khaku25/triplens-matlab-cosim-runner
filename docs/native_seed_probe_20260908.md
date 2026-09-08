# Native-state-seeded FMU probe — verified 2026-09-08

## Current result: initialization advances; complete simulation still fails

This diagnostic is not a validated scenario engine or full ECMS closed loop.
The previous native t=0 physical solution is reused as initial guesses. It is
not a replay of the native CSV and not an FMI snapshot restore at t=300.
All symbolic initialization equations and physical property assertions remain.

## Actual GitHub / installed MATLAB evidence

Native state capture run: https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34220970632
Native artifact: triptac-native-full-state-1, ID 10053784441.
The unchanged pinned native reference ran with DASSL from 0 to 300 s, before
the scheduled trip. Full CSV contains 31 sample rows and 14,754 variables;
full MAT also preserves parameters. Saved snapshots include t=0 and t=300.
The seed used for this test is the solved t=0 state, not the t=300 snapshot.

Seeded Simulink run: https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34226155354
Workflow: TripTAC Native State Seed Simulink Probe #1.
Code commit: 7d3572d9e71fea9bd489bf860d5ddc2c9fc43fa2.
Windows job: 102060801351, runner DESKTOP-LL7GB3B, installed MATLAB R2025b.
Source artifact: native-seeded-source-1, ID 10055789634.
Windows artifact: native-seeded-simulink-evidence-1, ID 10055858544.
GUID: {14d259d3-12e3-4b99-92da-e9d3d79644a6}.
Seeded source FMU SHA-256: b14e9b4fc7269f324b35c2ab79a8bbb048ccad44b5ca359d6e2f58118795ed6c.

| Test | Observed result |
|---|---|
| Capture full native state on GitHub Ubuntu | PASS |
| Map native values into a separate FMU source copy | 8,575 real-variable guesses and 61 calculated-parameter guesses |
| Compile Windows DLL with installed MATLAB MinGW | PASS |
| Simulink import of two inputs and seven outputs | PASS |
| FMU nominal initialization | PASS for this tested state; outputs read and integration began |
| Run baseline through 0.2 s | FAIL in fmi2DoStep; linear system 8049 fails at t=0.002 s |
| Independently perturb flow and temperature | NOT RUN; baseline must pass first |
| ECMS protection feedback / accident validation | NOT ESTABLISHED |

FMI log after nominal input assignment:

```text
fmi2ExitInitializationMode...
fmi2ExitInitializationMode: succeed
fmi2GetReal: hpDrumLevel = 1.05
fmi2GetReal: hpDrumPressure = 12726424.23562607
fmi2GetReal: ipDrumLevel = 1.05
fmi2GetReal: ipDrumPressure = 2733918.284814339
fmi2GetReal: lpDrumLevel = 1.75
fmi2GetReal: lpDrumPressure = 536006.6647422113
fmi2GetReal: stElectricalPower = 263112293.2842558
```

The log then records actual integration state updates and another output read,
including ST power 263112293.246181 W. MATLAB subsequently reports a
fmi2DoStep error, rather than the previous fmi2ExitInitializationMode error.
The overall workflow correctly remains FAILED; no completed baseline CSV
or input-response PASS was produced by this Simulink test.

## Why native seeds alone were not sufficient

A separate Linux diagnostic reused the original source FMU and actual native
values. Seeding enabled the main thermal initial solve, but a controller's
accepted initial value was lost at the nonlinear solver return, leading to
an invalid subsequent pressure calculation.

The bundled OpenModelica 1.27 nonlinearSolverHomotopy.c early-convergence
branch evaluates f(x0), accepts its residual, but copies x into nlsx without
first copying the accepted x0 into x. The instrumented test showed:

```text
EARLY_CONVERGENCE_RETAIN_X0 eq=546 x0=0.80000000000000004 old_x=0 residual_sq=0
```

This corresponds to the LP level controller. Without the isolated correction,
the subsequent controller integral value was 0 instead of 400, the valve
coefficient fell from about 26845 to 201, and the computed average pressure
became negative. This is an observed numerical-runtime path, not a change to
physical plant design or a new protection threshold.

The experimental source copy therefore has TWO changes:
1. Apply the solved native t=0 values as initial guesses before initialization.
2. In the first early-convergence branch only, retain the x0 vector whose
   residual just passed before returning the solution. No tolerance is relaxed.

The source file in OpenModelica v1.27.0 independently contains this same branch:
https://github.com/OpenModelica/OpenModelica/blob/v1.27.0/OMCompiler/SimulationRuntime/c/simulation/solver/nonlinearSolverHomotopy.c
This is a local experimental correction, not a claim of an upstream accepted fix.

## Remaining work

Preserve this initialization result and investigate time advancement separately.
The current source FMU uses the default explicit Euler co-simulation path.
Native DASSL success does not demonstrate Euler stability. A smaller-step test
and a stiff-integrator comparison, such as a properly built CVODE FMU, are
appropriate next diagnostics. The exact cause of linear system 8049 failure
has not yet been isolated, so an integrator change is not claimed as a cure.

## Reproduction and scope

ci/build_native_seed_fmu.py checks SHA-256 of both source FMU and native MAT,
records the name-to-storage mapping, assigns a new GUID, and retains physics.
.github/workflows/triptac-native-seed-simulink.yml downloads the exact saved
artifacts, builds a separate seeded source copy, and invokes installed MATLAB.

The diagnostic requires these environment flags before loading the FMU:
TRIPLENS_USE_NATIVE_SEED=1
TRIPLENS_RETAIN_VALIDATED_NLS_GUESS=1

This does not add FMI state serialization support. Existing cloud RAW pipeline,
Modelica physics equations, and ECMS tag/protection source files were not edited
by these probe changes. CI checkout does refresh its generated workspace as
usual; persistent user models are not deployed or overwritten by this workflow.
