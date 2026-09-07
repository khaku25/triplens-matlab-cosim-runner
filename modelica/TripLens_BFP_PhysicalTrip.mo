within ;
model TripLens_BFP_PhysicalTrip
  parameter Real bfpTripTime(unit="s") = 300;
  parameter Real bfpRampDuration(unit="s") = 2;
  parameter Real bfpNormalRpm = 1400;
  parameter Real bfpTrippedRpm = 0;

  extends ThermoSysPro.Fluid.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC(
    arretPomesHP(
      Initialvalue=bfpNormalRpm,
      Starttime=bfpTripTime,
      Duration=bfpRampDuration,
      Finalvalue=bfpTrippedRpm),
    Debit(Starttime=1e9),
    Temperature(Starttime=1e9));

  output Real hpBfpRpm = PompeAlimHP.Vr;
  output Real hpBfpMassFlow(unit="kg/s") = PompeAlimHP.Q;
  output Real hpFeedwaterFlow(unit="kg/s") = CapteurDebitEauHP.Measure.signal;
  output Real hpDrumLevel(unit="m") = BallonHP.zl;
  output Real hpDrumPressure(unit="Pa") = BallonHP.P;
  output Real hpSteamFlow(unit="kg/s") = CapteurDebitVapHP.Measure.signal;
  output Real stMechanicalPower(unit="W") = Alternateur.Wmec;

  annotation(experiment(StartTime=0, StopTime=1000, Tolerance=1e-3, Interval=1));
end TripLens_BFP_PhysicalTrip;
