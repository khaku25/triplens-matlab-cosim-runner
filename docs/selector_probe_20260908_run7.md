# TripTAC selector initialization probe: verified result

Test completed: 2026-09-08 10:55 UTC (19:55 KST).
Scope: isolated selector FMU probe only. This is not a status claim about unrelated ECMS or UI work.

## Result: NOT READY FOR PHYSICAL SCENARIO GENERATION

Run: https://github.com/khaku25/triplens-matlab-cosim-runner/actions/runs/34217750061
Workflow run number: 7.
Test code commit: `22d42813ea6eb6970e553f39d423b5cb6366f0a5`.
Pinned ThermoSysPro: `db81ae1b5a6a85f6c6c7693244cafa6087e18ff5`.
FMU GUID: `{f4b5b703-2efc-45cf-84cd-33df5ff8bf75}`.
Source FMU SHA-256: `a8d47601321b3313893a019533facc3e433bd11c98c8f1b653a5ec61e1ad1f6a`.

| Check | Observed result |
| --- | --- |
| Preserve original Debit and Temperature tables | PASS; reverse-patching only the wrapper additions recovers the pinned original exactly |
| Generate source FMU and validate interface | PASS |
| Compile Windows MinGW DLL and package FMU | PASS |
| Simulink import, two inputs and seven outputs | PASS |
| Correct nominal inputs at FMU initialization | PASS; confirmed in the FMI debug log |
| Complete normal-input baseline simulation | FAIL in fmi2ExitInitializationMode |
| Independent flow perturbation response | NOT RUN because baseline failed |
| Independent temperature perturbation response | NOT RUN because baseline failed |
| Full ECMS closed-loop / accident scenario validation | NOT ESTABLISHED by this probe |

## Decisive log evidence

```text
fmi2SetReal: gtExhaustFlowCmd = 606.9400000000001
fmi2SetReal: gtExhaustTemperatureCmd = 893.75
fmi2ExitInitializationMode...
Water_Ph: Incorrect region number (-1)
fmi2ExitInitializationMode: terminated by an assertion.
```

The later OpenModelica log line containing `succeed` does NOT override the error: MATLAB sim() failed, the baseline result JSON records failure, and no completed physical time-series CSV was produced.

Preserving the original schedules during initialization did NOT by itself resolve the failure. The remaining root cause is not yet isolated. It must not be described as a proven table-replacement problem or a solved co-simulation interface.

## Changes made in this investigation

The production Modelica wrapper, existing RAW CSV files, original ThermoSysPro source, and ECMS protection logic were not edited by these probe changes. New isolated scripts build the selector, package its actual generated C sources, and test its exact new artifact in Windows/Simulink. No property assertion was disabled and no nonphysical value was clamped to make the test pass.

The probe no longer consumes the old fixed cloud-FMU artifact. Source and Windows stages consume artifacts from the same workflow run. Source-only packaging is verified before Windows compilation.

Output mapping is read from modelDescription.xml rather than assumed from declaration order:
1. hpDrumLevel [m]
2. hpDrumPressure [Pa]
3. ipDrumLevel [m]
4. ipDrumPressure [Pa]
5. lpDrumLevel [m]
6. lpDrumPressure [Pa]
7. stElectricalPower [W]

Run 6 exposed another test-harness issue: Step blocks sent zero input values during FMU initialization. Run 7 uses Constant blocks for the baseline and confirms the correct nominal values above. Perturbation cases now contain Unit Delay blocks with nominal initial conditions and a documented 0.001 s command delay; those cases remain untested because baseline initialization still fails.

## Preserved evidence

Source artifact: `selector-source-fmu-7`, ID `10052507173`.
Windows artifact: `selector-simulink-evidence-7`, ID `10052562353`.
The Windows artifact includes the FMU, baseline SLX, modelDescription.xml, port mapping, failed result JSON, and the FMI debug log. This artifact is a diagnostic build, not a validated scenario engine.

## Next diagnostic target, not yet completed

Locate the first invalid pressure/enthalpy evaluation in this new selector FMU, then compare its initialization equations, alias-selected start values, and nonlinear solver path with a successfully initialized native ThermoSysPro reference. A successful original-equation preservation check does not prove identical numerical initialization after FMI export. Keep the physics and property-domain assertions intact during that comparison.
