# CVODE co-simulation connection probe: actual completed execution

Verified 2026-09-08. Final execution artifacts completed about 13:51 UTC / 22:51 KST.

## Result: PASS for the bounded connection/input-response tests

Workflow: TripTAC CVODE Warm Start Probe, run number 4.
Run: https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34233967732
Test code commit: c4973de857ae43e259354e36f50b172b7571d6f5.
All four jobs completed successfully: Linux build, Windows build, Linux execution,
and installed Windows MATLAB/Simulink execution. This is not merely an FMU build PASS.

Installed MATLAB job: 102087465489 on DESKTOP-LL7GB3B, MATLAB R2025b.
Linux execution job: 102087465735 on GitHub-hosted Ubuntu.
Windows execution artifact: cvode-simulink-execution-4, ID 10059245434.
Linux execution artifact: cvode-linux-execution-4, ID 10059253740.
Windows build artifact: cvode-build-win64-4, ID 10059077343.
Linux build artifact: cvode-build-linux64-4, ID 10059061969.

## Actual Windows / Simulink results

Each test ran from simulation time 0 through 2.00 seconds, at a 0.01 second FMI
communication interval. Each produced 201 aligned samples of two applied inputs
and seven physical outputs, with zero NaN/Inf values. sim() returned normally,
including FMU cleanup. All three cases ran in the same MATLAB batch process.

| Case | Applied input change | Completion | Final ST output, MW | Wall seconds including case model setup/validation |
|---|---|---|---|---|
| baseline | Flow 606.94 kg/s; temperature 893.75 K held constant | PASS | 263.109749366061 | 61.3120542 |
| flow_step | Only flow reduced 1%, to 600.8706 kg/s | PASS | 263.105661940855 | 60.5267561 |
| temperature_step | Only temperature reduced 0.5%, to 889.28125 K | PASS | 263.104455577952 | 62.1596131 |

All cases start from the same computed nominal state: ST 263.112293284256 MW,
HP/IP drum levels 1.05 m, LP drum level 1.75 m. These are reference-model values,
not calibrated measurements of the user's actual plant.

The Simulink Step command occurs at 1.00 s. A Unit Delay with nominal initial
conditions makes the applied change occur at 1.01 s; that transport delay is
explicitly recorded, not hidden or backdated. Input histories are recorded in
CSV. Before the applied change the physical histories match the baseline within
the configured comparison tolerance. After the change the respective maximum
ST differences from the baseline are 4087.425205618143 W and 5293.788108885288 W.
Other pressure/level outputs also respond. Tiny perturbations over two seconds
are connection tests, not realistic trip/blackout scenarios.

The Linux independent FMI importer also completed all three 2-second cases.
Its changes are applied at 1.00 s without the Simulink Unit Delay, so this is not
a claim of bitwise-identical cross-platform transients or a matched-time solver
accuracy study.

## Runtime evidence

The Windows execution log contains three instances of each actual marker:

- TRIPLENS_FMI_INTERNAL_SOLVER=cvode
- TRIPLENS_CVODE_FMI_CALLBACK_CLEANUP_PASS
- CVODE_SIM_RETURNED_AFTER_CLEANUP=<case>

It ends with INSTALLED_SIMULINK_CVODE_THREE_CASES_COMPLETE_PASS.
The result JSON has overall=pass and sim_returned=true for all three cases.
An independent local read of the actual artifact rechecked FMU SHA-256, all
three CSV lengths/time axes/finite values, applied inputs, pre-change agreement,
post-change response, and the runtime/cleanup markers.

## Exact build and changes

Base model: pinned ThermoSysPro CombinedCycle_TripTAC with external exhaust-flow
and temperature inputs; ThermoSysPro commit db81ae1b5a6a85f6c6c7693244cafa6087e18ff5.
OpenModelica runtime 1.27.0, SUNDIALS 5.4.0 static libraries, CVODE BDF/Newton.
SUNDIALS commit: 84c029fe0b4b3c3bbf5cf8835f5828a6bb98b7a2.

Windows FMU GUID: {e8eac018-5493-5a10-b5b2-241d5c5f2315}.
Windows FMU SHA-256: 794887fb4e0afd8a66cf26f41188f7d080221eb771aa9c048ed8c994eb1e2892.
Windows DLL SHA-256: 0eb368bf5c8cadaa95eb85e675ab8f5e19f050d8c76860920a309a448ff2c824.

The previously computed native t=0 solution supplies 8575 variable guesses and
61 calculated-parameter guesses. The earlier isolated nonlinear-solver
accepted-x0 correction is retained. This is not restoration of a t=300 FMI
snapshot and not a CSV playback engine. Model equations are still solved.

CVODE C sources and SUNDIALS were added to the cloud source build. The first
CVODE Windows test (run 34231529689) reached execution but crashed in cleanup:
fmi2FreeInstance -> cvode_solver_deinitial -> free(cvodeData). The crash return
RVA 0x155d6b7 maps immediately after that last free in the actual DLL.
The source allocated this outer object with FMI allocateMemory but freed it
with the DLL C runtime's free. The final build repairs ownership: CVODE internal
allocations are freed normally; the FMI-owned outer object is freed with the
importer's freeMemory. Cleanup is NOT skipped. The change is an experimental
local runtime repair, not a claim of an upstream accepted fix.

Generated physical C is checked unchanged except for FMU GUID. Native seed and
previous nonlinear-runtime-correction files are checked unchanged. Physical
property assertions remain active; no pressure clamp, invented sensor trace,
protection-threshold change, or fake success override was introduced.

The CVODE runtime reports relative tolerance 1e-3. Do not claim the Python
setupExperiment request of 1e-6 proved an effective 1e-6 runtime tolerance.
Diagnostic compiler optimization is -O0. The measured speed is not real time.

## Reproduce the saved Windows models

The Windows execution artifact includes the FMU, three SLX models, CSV traces,
SimulationOutput MAT files, runtime log, XML and JSON manifests. Extract it to
a writable directory and make that directory the MATLAB current folder.
Before importing the FMU, set the same explicit diagnostic flags:

```matlab
setenv('TRIPLENS_USE_NATIVE_SEED','1');
setenv('TRIPLENS_RETAIN_VALIDATED_NLS_GUESS','1');
addpath(pwd);
open_system('TripLens_CVODE_baseline.slx');
```

The saved model has the tested two-second settings. This opens the actual
connection test model, not a completed ECMS operator dashboard.
To rerun the full automated test, use ci/matlab_cvode_completion_probe.m with
the artifact files in outputs/, as in the recorded workflow.

## Limits / stop point

This establishes Simulink input -> actual Thermo CVODE computation -> Simulink
physical output and clean termination for the three tested short cases.
It does not establish a full ECMS/protection feedback loop, all A-program tags,
BFP/breaker/transformer command ports, long 300+120 second accident scenarios,
wall-clock real-time execution, or calibration against an actual plant.
No dashboard or persistent user ECMS deployment was performed by this probe.
The successful existing cloud RAW pipeline and ECMS protection source were not
edited. Final test jobs are complete; no additional scenario run is queued by
this report.
