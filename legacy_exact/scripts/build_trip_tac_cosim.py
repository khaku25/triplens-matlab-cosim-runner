from pathlib import Path
import re

SRC = Path('legacy_exact/vendor/ThermoSysPro/ThermoSysPro/Examples/CombinedCyclePowerPlant/CombinedCycle_TripTAC.mo')
OUT = Path('legacy_exact/build/TripLens_CombinedCycle_TripTAC_CoSim.mo')
text = SRC.read_text(encoding='utf-8')

# Keep the original package and the original CombinedCycle_TripTAC plant.
# Only replace the two internal GT boundary schedules and the two ST turbine
# inlet-valve constant commands with externally driven sources so Simulink can
# become the master during FMI co-simulation. No turbine, drum, HRSG, condenser,
# generator or pump physics are replaced.
old_header = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;
model CombinedCycle_TripTAC
  "CCPP model to simulate a load variation from 100% to 50%"'''
new_header = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;
block TripLensExternalRealSource
  parameter Real initialValue;
  Modelica.Blocks.Interfaces.RealInput u(start=initialValue);
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;
equation
  // Keep ThermoSysPro inside its validated water/steam region while the
  // co-simulation master is still entering FMI initialization mode.
  y.signal = if initial() then initialValue else u;
end TripLensExternalRealSource;

block TripLensSTTripValveSource
  parameter Real normalOpening=0.8;
  Modelica.Blocks.Interfaces.RealInput trip(start=0)
    "0=normal admission, >=0.5=ST trip";
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;
equation
  // Preserve the native 0.8 opening during initialization. After
  // initialization a latched ECMS ST trip closes the actual HP/MP turbine
  // admission valves. The downstream steam-cycle rundown is still solved by
  // ThermoSysPro; no synthetic ST power-decay equation is introduced.
  y.signal = if initial() then normalOpening else if trip >= 0.5 then 0 else normalOpening;
end TripLensSTTripValveSource;

model TripLens_CombinedCycle_TripTAC_CoSim
  "CombinedCycle_TripTAC with external GT boundary and ST trip inputs for FMI co-simulation"
  Modelica.Blocks.Interfaces.RealInput gtExhaustFlowCmd(start=606.94, unit="kg/s")
    "External GT exhaust mass-flow command";
  Modelica.Blocks.Interfaces.RealInput gtExhaustTemperatureCmd(start=893.75, unit="K")
    "External GT exhaust temperature command";
  Modelica.Blocks.Interfaces.RealInput stTripCmd(start=0)
    "Latched ECMS ST trip command; closes actual HP/MP turbine admission valves";
  Modelica.Blocks.Interfaces.RealOutput stElectricalPower(unit="W");
  Modelica.Blocks.Interfaces.RealOutput hpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput ipDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput lpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput hpDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput ipDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput lpDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput hpTurbineInletValveOpening
    "Actual HP turbine admission-valve command after ST trip adapter";
  Modelica.Blocks.Interfaces.RealOutput mpTurbineInletValveOpening
    "Actual MP turbine admission-valve command after ST trip adapter";'''
if old_header not in text:
    raise SystemExit('original TripTAC class header not found')
text = text.replace(old_header, new_header, 1)

# Replace only the original timed GT boundary tables. All downstream HRSG/ST
# components, controllers and equations remain the pinned ThermoSysPro example.
pat_debit = re.compile(
    r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Debit\(.*?\)\s*'
    r'annotation \(Placement\(transformation\(extent=\{\{-527,-19\},\{-457,\s*55\}\}, rotation=0\)\)\);',
    re.S)
pat_temp = re.compile(
    r'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps Temperature\(.*?\)\s*'
    r'annotation \(Placement\(transformation\(extent=\{\{-527,-157\},\{\s*-457,-83\}\}, rotation=0\)\)\);',
    re.S)

text, n1 = pat_debit.subn(
    'TripLensExternalRealSource Debit(initialValue=606.94) annotation '
    '(Placement(transformation(extent={{-527,-19},{-457,55}}, rotation=0)));',
    text, count=1)
text, n2 = pat_temp.subn(
    'TripLensExternalRealSource Temperature(initialValue=893.75) annotation '
    '(Placement(transformation(extent={{-527,-157},{-457,-83}}, rotation=0)));',
    text, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit(f'GT boundary replacement failed: Debit={n1}, Temperature={n2}')

# Replace the original constant HP/MP turbine-admission commands with a source
# that preserves the native 0.8 opening in normal operation and closes the
# actual valves on the external ST trip input. The original connect() statements
# to vanne_entree_TurbineHP/MP remain untouched.
pat_st_hp = re.compile(
    r'ThermoSysPro\.InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps\s*'
    r'ConstantVanneTurbineHP\(.*?\)\s*'
    r'annotation \(Placement\(transformation\(extent=\{\{-241,-216\},\{\s*-171,-142\}\}, rotation=0\)\)\);',
    re.S)
pat_st_mp = re.compile(
    r'ThermoSysPro\.InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps\s*'
    r'ConstantVanneTurbineMP\(.*?\)\s*'
    r'annotation \(Placement\(transformation\(extent=\{\{-241,-300\},\{\s*-171,-226\}\}, rotation=0\)\)\);',
    re.S)
text, n3 = pat_st_hp.subn(
    'TripLensSTTripValveSource ConstantVanneTurbineHP(normalOpening=0.8) annotation '
    '(Placement(transformation(extent={{-241,-216},{-171,-142}}, rotation=0)));',
    text, count=1)
text, n4 = pat_st_mp.subn(
    'TripLensSTTripValveSource ConstantVanneTurbineMP(normalOpening=0.8) annotation '
    '(Placement(transformation(extent={{-241,-300},{-171,-226}}, rotation=0)));',
    text, count=1)
if n3 != 1 or n4 != 1:
    raise SystemExit(f'ST admission replacement failed: HP={n3}, MP={n4}')

text = text.replace('end CombinedCycle_TripTAC;',
                    'end TripLens_CombinedCycle_TripTAC_CoSim;', 1)

# Insert external assignments and compact physical feedback aliases at the
# beginning of the original model equation section. No synthetic process
# dynamics are introduced here.
extra_eq = '''\nequation
  Debit.u = gtExhaustFlowCmd;
  Temperature.u = gtExhaustTemperatureCmd;
  ConstantVanneTurbineHP.trip = stTripCmd;
  ConstantVanneTurbineMP.trip = stTripCmd;
  stElectricalPower = Alternateur.Welec;
  hpDrumLevel = BallonHP.zl;
  ipDrumLevel = BallonMP.zl;
  lpDrumLevel = BallonBP.zl;
  hpDrumPressure = BallonHP.P;
  ipDrumPressure = BallonMP.P;
  lpDrumPressure = BallonBP.P;
  hpTurbineInletValveOpening = ConstantVanneTurbineHP.y.signal;
  mpTurbineInletValveOpening = ConstantVanneTurbineMP.y.signal;
'''
helper_end = 'end TripLensSTTripValveSource;\n\nmodel TripLens_CombinedCycle_TripTAC_CoSim'
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
print('TripLens FMU interface: 3 inputs / 9 outputs')
print('ST trip physical path: stTripCmd -> vanne_entree_TurbineHP/MP opening -> ThermoSysPro rundown')
