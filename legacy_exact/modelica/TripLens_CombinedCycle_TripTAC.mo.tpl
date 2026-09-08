within ;
model TripLens_CombinedCycle_TripTAC
  parameter Real tripTime(unit="s") = @TRIP_TIME@;
  parameter Real tripRampDuration(unit="s") = @TRIP_RAMP_DURATION@;
  parameter Real exhaustFlowNormal(unit="kg/s") = 606.94;
  // The legacy ThermoSysPro CCPP becomes singular when flue-gas flow is
  // forced to 50 kg/s while its steam-side pumps and valves remain online.
  // 150 kg/s is the lowest severe-trip point verified to reach 1000 s in
  // OpenModelica 1.27 with the paired temperature floor below.
  parameter Real exhaustFlowTripped(unit="kg/s") = 150.0;
  parameter Real exhaustTemperatureNormal(unit="K") = 893.75;
  parameter Real exhaustTemperatureTripped(unit="K") = 550.0;

  extends ThermoSysPro.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC(
    Debit(Table=[0,exhaustFlowNormal;
                 tripTime,exhaustFlowNormal;
                 tripTime + tripRampDuration,exhaustFlowTripped;
                 @STOP_TIME@,exhaustFlowTripped]),
    Temperature(Table=[0,exhaustTemperatureNormal;
                       tripTime,exhaustTemperatureNormal;
                       tripTime + tripRampDuration,exhaustTemperatureTripped;
                       @STOP_TIME@,exhaustTemperatureTripped]));

  annotation(experiment(
    StartTime=0,
    StopTime=@STOP_TIME@,
    Tolerance=1e-3,
    Interval=@OUTPUT_INTERVAL@));
end TripLens_CombinedCycle_TripTAC;
