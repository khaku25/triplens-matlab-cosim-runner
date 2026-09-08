from pathlib import Path
import re

SRC = Path('legacy_exact/vendor/ThermoSysPro/ThermoSysPro/Examples/CombinedCyclePowerPlant/CombinedCycle_TripTAC.mo')
OUT = Path('legacy_exact/build/TripLens_CombinedCycle_TripTAC_CoSim.mo')
text = SRC.read_text(encoding='utf-8')

# Keep the original package so all unqualified ThermoSysPro names resolve exactly
# as they do in the pinned example. Add a small adapter block plus a renamed copy
# of the original CombinedCycle_TripTAC model.
text = text.replace('within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nmodel CombinedCycle_TripTAC',
'''within ThermoSysPro.Examples.CombinedCyclePowerPlant;
block TripLensExternalRealSource
  Modelica.Blocks.Interfaces.RealInput u;
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;
equation
  y.signal = u;
end TripLensExternalRealSource;

model TripLens_CombinedCycle_TripTAC_CoSim''', 1)

# Replace only the original timed GT boundary tables. The downstream HRSG/ST
# equations and topology remain the original pinned example.
pat_debit = re.compile(r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Debit\(.*?\)\s*annotation \(Placement\(transformation\(extent=\{\{-527,-19\},\{-457,\s*55\}\}, rotation=0\)\)\);', re.S)
pat_temp = re.compile(r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Temperature\(.*?\)\s*annotation \(Placement\(transformation\(extent=\{\{-527,-157\},\{\s*-457,-83\}\}, rotation=0\)\)\);', re.S)

text, n1 = pat_debit.subn("TripLensExternalRealSource Debit annotation (Placement(transformation(extent={{-527,-19},{-457,55}}, rotation=0)));", text, count=1)
text, n2 = pat_temp.subn("TripLensExternalRealSource Temperature annotation (Placement(transformation(extent={{-527,-157},{-457,-83}}, rotation=0)));", text, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit(f'boundary replacement failed: Debit={n1}, Temperature={n2}')

text = text.replace('end CombinedCycle_TripTAC;', 'end TripLens_CombinedCycle_TripTAC_CoSim;', 1)

# Inputs are the same physical boundary quantities the original example scheduled
# internally. Outputs are aliases to original physical states used by ECMS/DCS.
insert = '''\n  Modelica.Blocks.Interfaces.RealInput gtExhaustFlowCmd(unit="kg/s") "External GT exhaust mass-flow command";
  Modelica.Blocks.Interfaces.RealInput gtExhaustTemperatureCmd(unit="K") "External GT exhaust temperature command";
  Modelica.Blocks.Interfaces.RealOutput stElectricalPower(unit="W");
  Modelica.Blocks.Interfaces.RealOutput hpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput ipDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput lpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput hpDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput ipDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput lpDrumPressure(unit="Pa");
'''
model_marker = 'model TripLens_CombinedCycle_TripTAC_CoSim\n'
text = text.replace(model_marker, model_marker + insert, 1)

extra_eq = '''\nequation
  Debit.u = gtExhaustFlowCmd;
  Temperature.u = gtExhaustTemperatureCmd;
  stElectricalPower = Alternateur.Welec;
  hpDrumLevel = BallonHP.zl;
  ipDrumLevel = BallonMP.zl;
  lpDrumLevel = BallonBP.zl;
  hpDrumPressure = BallonHP.P;
  ipDrumPressure = BallonMP.P;
  lpDrumPressure = BallonBP.P;
'''
helper_end = 'end TripLensExternalRealSource;\n\nmodel TripLens_CombinedCycle_TripTAC_CoSim'
pos = text.find(helper_end)
if pos < 0:
    raise SystemExit('helper/model boundary not found')
pos_eq = text.find('\nequation\n', pos + len(helper_end))
if pos_eq < 0:
    raise SystemExit('model equation section not found')
text = text[:pos_eq] + extra_eq + text[pos_eq + len('\nequation\n'):]

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(text, encoding='utf-8')
print(f'WROTE {OUT}')
