# FWP-HP ECMS operation logic

This directory implements the HP feedwater pump manipulation logic agreed for the virtual ECMS test.

## Implemented behavior

- The normal stopped/READY condition has `VCB-A01` closed and shaft speed at zero.
- `FWP_HP_RUN` changing from 0 to 1 starts the pump only after the start permissives pass. START does not close the feeder breaker.
- `FWP_HP_RUN` changing from 1 to 0 performs a normal STOP: run enable is removed, `VCB-A01` remains closed, and RPM coasts down.
- `FWP_HP_TRIP` or `electrical_trip_active` latches TRIP, removes run enable, sends the feeder breaker trip command, opens the virtual breaker after its operating delay, and lets RPM coast down.
- RESET requires the cause to be clear, run request off, breaker open, and absolute speed at or below 5 rpm. RESET does not close the breaker or restart the pump.
- Reclosing `VCB-A01` is a separate ECMS command. A new 0-to-1 `FWP_HP_RUN` edge is required after reclose.

## Physical-value policy

The normal speed is the model-native `1400 rpm` from `CombinedCycle_TripTAC`. The Thermo boundary output is wired for `PompeAlimHP.rpm_or_mpower`; process feedback remains the native ThermoSysPro flow (`kg/s`), drum level (`m`) and pressure (`Pa`).

The current breaker time and motor time constants are explicitly marked virtual-model parameters because approved feeder C&E, breaker travel data, motor nameplate/load curve and shaft inertia are not yet available. They are mechanism parameters, not fabricated H/HH/L/LL or rate-of-change protection settings.

No derivative alarm and no process H/HH/L/LL alarm is active in this core. Those remain disabled until their actual physical input and approved setting exist.

## Generated evidence

`build_fwp_hp_operation` creates and tests `TripLens_ECMS_FWP_HP_Operation_Core.slx`. The test covers start, normal stop, restart, trip, breaker delay, invalid reset while rotating, valid reset, manual reclose and no automatic restart. `install_fwp_hp_operation_into_ecms` then places the referenced model visibly in the local `TripLens_ECMS_DigitalTwin` shell without claiming that the pending external electrical/Thermo lines are connected.
