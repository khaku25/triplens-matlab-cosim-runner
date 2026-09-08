from pathlib import Path
import re

SRC = Path('legacy_exact/vendor/ThermoSysPro/ThermoSysPro/Examples/CombinedCyclePowerPlant/CombinedCycle_TripTAC.mo')
OUT = Path('legacy_exact/build/TripLens_CombinedCycle_TripTAC_CoSim.mo')
text = SRC.read_text(encoding='utf-8')

# Keep the original CombinedCycle_TripTAC plant and equations, but expose the two
# original load/trip boundary schedules as external continuous inputs.
text = text.replace('within ThermoSysPro.Examples.CombinedCyclePowerPlant;\nmodel CombinedCycle_TripTAC',
'''within ;
block TripLensExternalRealSource
  Modelica.Blocks.Interfaces.RealInput u;
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;
equation
  y.signal = u;
end TripLensExternalRealSource;

model TripLens_CombinedCycle_TripTAC_CoSim''', 1)

# Replace original timed boundary tables only; all downstream connections and
# the physical CCPP remain those of the pinned ThermoSysPro example.
pat_debit = re.compile(r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Debit\(.*?\)\s*annotation \(Placement\(transformation\(extent=\{\{-527,-19\},\{-457,\s*55\}\}, rotation=0\)\)\);', re.S)
pat_temp = re.compile(r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Temperature\(.*?\)\s*annotation \(Placement\(transformation\(extent=\{\{-527,-91\},\{-457,-17\}\}, rotation=0\)\)\);', re.S)

text, n1 = pat_debit.subn("TripLensExternalRealSource Debit annotation (Placement(transformation(extent={{-527,-19},{-457,55}}, rotation=0)));", text, count=1)
text, n2 = pat_temp.subn("TripLensExternalRealSource Temperature annotation (Placement(transformation(extent={{-527,-91},{-457,-17}}, rotation=0)));", text, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit(f'boundary replacement failed: Debit={n1}, Temperature={n2}')

# Rename closing class declaration.
text = text.replace('end CombinedCycle_TripTAC;', 'end TripLens_CombinedCycle_TripTAC_CoSim;', 1)

# Expose a compact set of outputs used by ECMS/DCS logic. These are aliases to
# the original example states, not synthetic dynamics.
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

# Add external boundary and output alias equations just before the first existing
# equation section. Original connections remain untouched.
eq_marker = '\nequation\n'
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
# Skip the helper block's equation section; replace the model's equation marker
# following the helper block end.
helper_end = 'end TripLensExternalRealSource;\n\nmodel TripLens_CombinedCycle_TripTAC_CoSim'
pos = text.find(helper_end)
if pos < 0:
    raise SystemExit('helper/model boundary not found')
pos_eq = text.find(eq_marker, pos + len(helper_end))
if pos_eq < 0:
    raise SystemExit('model equation section not found')
text = text[:pos_eq] + extra_eq + text[pos_eq + len(eq_marker):]

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(text, encoding='utf-8')
print(f'WROTE {OUT}')
