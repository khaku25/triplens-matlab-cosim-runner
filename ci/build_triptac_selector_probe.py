"""Build an isolated FMU probe; never edit the pinned plant or production wrapper."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path('legacy_exact')
SRC = ROOT / 'vendor/ThermoSysPro/ThermoSysPro/Examples/CombinedCyclePowerPlant/CombinedCycle_TripTAC.mo'
OUT = ROOT / 'build/selector_probe/TripLens_CombinedCycle_TripTAC_CoSim.mo'
PIN = 'db81ae1b5a6a85f6c6c7693244cafa6087e18ff5'
HEADER = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;
model CombinedCycle_TripTAC
  "CCPP model to simulate a load variation from 100% to 50%"'''
REPLACEMENT = '''within ThermoSysPro.Examples.CombinedCyclePowerPlant;
block TripLensInitializationSelector
  parameter Real initialValue;
  ThermoSysPro.InstrumentationAndControl.Connectors.InputReal original;
  Modelica.Blocks.Interfaces.RealInput externalCommand(start=initialValue);
  ThermoSysPro.InstrumentationAndControl.Connectors.OutputReal y;
equation
  // Use the unmodified original schedule while solving initial equations.
  // After initialization, the FMI master owns the boundary condition.
  y.signal = if initial() then original.signal else externalCommand;
end TripLensInitializationSelector;

model TripLens_CombinedCycle_TripTAC_CoSim
  "Isolated original-table initialization selector probe, not a validated scenario"
  Modelica.Blocks.Interfaces.RealInput gtExhaustFlowCmd(start=606.94, unit="kg/s");
  Modelica.Blocks.Interfaces.RealInput gtExhaustTemperatureCmd(start=893.75, unit="K");
  Modelica.Blocks.Interfaces.RealOutput stElectricalPower(unit="W");
  Modelica.Blocks.Interfaces.RealOutput hpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput ipDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput lpDrumLevel(unit="m");
  Modelica.Blocks.Interfaces.RealOutput hpDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput ipDrumPressure(unit="Pa");
  Modelica.Blocks.Interfaces.RealOutput lpDrumPressure(unit="Pa");
  TripLensInitializationSelector gtFlowSelector(initialValue=606.94);
  TripLensInitializationSelector gtTemperatureSelector(initialValue=893.75);'''
EXTRA_EQUATIONS = '''
equation
  gtFlowSelector.externalCommand = gtExhaustFlowCmd;
  gtTemperatureSelector.externalCommand = gtExhaustTemperatureCmd;
  connect(Debit.y, gtFlowSelector.original);
  connect(Temperature.y, gtTemperatureSelector.original);
  stElectricalPower = Alternateur.Welec;
  hpDrumLevel = BallonHP.zl;
  ipDrumLevel = BallonMP.zl;
  lpDrumLevel = BallonBP.zl;
  hpDrumPressure = BallonHP.P;
  ipDrumPressure = BallonMP.P;
  lpDrumPressure = BallonBP.P;
'''

def main():
    original = SRC.read_text(encoding='utf-8')
    if original.count(HEADER) != 1:
        raise ValueError('Pinned TripTAC header mismatch')
    text = original.replace(HEADER, REPLACEMENT, 1)
    edits = []
    for old, new, port in [('Debit', 'gtFlowSelector', 'IMassFlow'),
                           ('Temperature', 'gtTemperatureSelector', 'ITemperature')]:
        pattern = rf'connect\(\s*{old}\.y\s*,\s*SourceFumees\.\s*{port}\s*\)'
        text, count = re.subn(pattern, f'connect({new}.y, SourceFumees.{port})', text)
        if count != 1:
            raise ValueError(f'Expected one original boundary connection: {old}, got {count}')
        edits.append({'original': old, 'selector': new, 'port': port})
    marker = '\nmodel TripLens_CombinedCycle_TripTAC_CoSim\n'
    pos = text.index('\nequation\n', text.index(marker) + len(marker))
    text = text[:pos] + EXTRA_EQUATIONS + text[pos + len('\nequation\n'):]
    text = text.replace('end CombinedCycle_TripTAC;', 'end TripLens_CombinedCycle_TripTAC_CoSim;', 1)
    # Both original table declarations and their numbers must remain byte-identical.
    tables = {}
    for name in ['Debit', 'Temperature']:
        pattern = rf'InstrumentationAndControl\.Blocks\.Tables\.Table1DTemps {name}\(.*?;'
        before = re.search(pattern, original, re.S)
        after = re.search(pattern, text, re.S)
        if before is None or after is None or before.group() != after.group():
            raise ValueError(f'Original {name} table changed')
        tables[name] = before.group()
    # Reversing only the documented wrapper additions must recover the original.
    reverse = text.replace(REPLACEMENT, HEADER, 1).replace(EXTRA_EQUATIONS, '\nequation\n', 1)
    for old, new, port in [('Debit', 'gtFlowSelector', 'IMassFlow'),
                           ('Temperature', 'gtTemperatureSelector', 'ITemperature')]:
        original_connection = re.search(rf'connect\(\s*{old}\.y\s*,\s*SourceFumees\.\s*{port}\s*\)', original).group()
        reverse = reverse.replace(f'connect({new}.y, SourceFumees.{port})', original_connection, 1)
    reverse = reverse.replace('end TripLens_CombinedCycle_TripTAC_CoSim;', 'end CombinedCycle_TripTAC;', 1)
    if reverse != original:
        raise ValueError('Unexpected change outside documented wrapper additions')
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding='utf-8')
    manifest = {'probe_only': True, 'thermosyspro_commit': PIN,
                'original_sha256': hashlib.sha256(original.encode()).hexdigest(),
                'wrapper_sha256': hashlib.sha256(text.encode()).hexdigest(),
                'original_recovered_exactly': True, 'original_tables': tables,
                'connection_edits': edits,
                'initialization_source': 'original Debit and Temperature tables',
                'post_initialization_source': 'FMI master inputs',
                'physical_equations_modified': False,
                'assertions_disabled': False}
    (OUT.parent / 'selector_manifest.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print('SELECTOR_ORIGINAL_PRESERVATION_PASS')
    print(json.dumps(manifest, indent=2))

if __name__ == '__main__':
    main()
