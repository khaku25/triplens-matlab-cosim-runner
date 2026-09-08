within ;
model TripLens_CombinedCycle_BFPTrip
  parameter Real bfpTripTime(unit="s") = @BFP_TRIP_TIME@;
  parameter Real bfpCoastdownDuration(unit="s") = @BFP_COASTDOWN_DURATION@;
  parameter Real bfpNormalSpeed(unit="rev/min") = 1400.0;
  // The legacy pump model is numerically robust at this residual speed. The
  // electrical breaker is still represented as open in the blind ECMS data;
  // this value is the hydraulic adapter floor, not a claim that the motor runs.
  parameter Real bfpResidualSpeed(unit="rev/min") = @BFP_FINAL_RPM@;
  parameter Real exhaustFlowNormal(unit="kg/s") = 606.94;
  parameter Real exhaustTemperatureNormal(unit="K") = 893.75;

  extends ThermoSysPro.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC(
    // Keep the GT boundary normal: this is not a GT trip scenario.
    Debit(Table=[0,exhaustFlowNormal;
                 @STOP_TIME@,exhaustFlowNormal]),
    Temperature(Table=[0,exhaustTemperatureNormal;
                       @STOP_TIME@,exhaustTemperatureNormal]),
    // PompeAlimHP is the HP boiler-feed pump in the upstream model. Its
    // connected speed source is overridden to create the physical disturbance.
    arretPomesHP(
      Initialvalue=bfpNormalSpeed,
      Starttime=bfpTripTime,
      Duration=bfpCoastdownDuration,
      Finalvalue=bfpResidualSpeed));

  annotation(experiment(
    StartTime=0,
    StopTime=@STOP_TIME@,
    Tolerance=1e-3,
    Interval=@OUTPUT_INTERVAL@));
end TripLens_CombinedCycle_BFPTrip;
