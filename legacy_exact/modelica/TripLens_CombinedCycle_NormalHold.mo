within ;
model TripLens_CombinedCycle_NormalHold
  "TripLens steady normal-operation wrapper with no scheduled trip"

  parameter Real exhaustFlowNormal(unit="kg/s") = 606.94;
  parameter Real exhaustTemperatureNormal(unit="K") = 893.75;

  extends ThermoSysPro.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC(
    Debit(Table=[0,exhaustFlowNormal;
                 1.0e9,exhaustFlowNormal]),
    Temperature(Table=[0,exhaustTemperatureNormal;
                       1.0e9,exhaustTemperatureNormal]));

  annotation(
    experiment(
      StartTime=300,
      StopTime=1000,
      Tolerance=1e-3,
      Interval=0.1),
    __OpenModelica_simulationFlags(
      s="cvode",
      iif="C:/TripLensWarm/normal_hold_res.mat",
      iit="300",
      iim="none"));
end TripLens_CombinedCycle_NormalHold;
