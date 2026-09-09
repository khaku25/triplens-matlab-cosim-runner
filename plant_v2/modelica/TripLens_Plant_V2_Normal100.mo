within ;
model TripLens_Plant_V2_Normal100
  "TripLens Plant Model v2 NORMAL_100: no command means hold normal operation"

  parameter Real exhaustFlowNormal(unit="kg/s") = 606.94;
  parameter Real exhaustTemperatureNormal(unit="K") = 893.75;
  parameter Real feedwaterPumpNormalSpeed(unit="rpm") = 1400;

  extends ThermoSysPro.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC(
    Debit(Table=[0,exhaustFlowNormal;
                 1.0e9,exhaustFlowNormal]),
    Temperature(Table=[0,exhaustTemperatureNormal;
                       1.0e9,exhaustTemperatureNormal]),
    arretPomesHP(
      Initialvalue=feedwaterPumpNormalSpeed,
      Finalvalue=feedwaterPumpNormalSpeed,
      Starttime=1.0e9,
      Duration=1),
    arretPomesMp(
      Initialvalue=feedwaterPumpNormalSpeed,
      Finalvalue=feedwaterPumpNormalSpeed,
      Starttime=1.0e9,
      Duration=1),
    arretPomesBP(
      Initialvalue=feedwaterPumpNormalSpeed,
      Finalvalue=feedwaterPumpNormalSpeed,
      Starttime=1.0e9,
      Duration=1));

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
end TripLens_Plant_V2_Normal100;
