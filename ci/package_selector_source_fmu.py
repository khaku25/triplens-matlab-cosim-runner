"""Package only OpenModelica-generated source/metadata; never alter equations."""
from pathlib import Path
import hashlib
import json
import zipfile
import xml.etree.ElementTree as ET

base = Path('legacy_exact/build/selector_probe')
model_id = 'TripLens_CombinedCycle_TripTAC_CoSim'
roots = []
for xml in base.glob('*.fmutmp/modelDescription.xml'):
    root = ET.parse(xml).getroot()
    cs = root.find('CoSimulation')
    if cs is not None and cs.get('modelIdentifier') == model_id:
        roots.append((xml.parent, root))
if len(roots) != 1:
    raise RuntimeError(f'Expected one translated Co-Simulation root, got {roots}')
root_dir, xml = roots[0]
sources = root_dir / 'sources'
for rel in [f'{model_id}.c', f'{model_id}_FMU.c', 'omc_simulation_settings.h',
            'simulation_data.h', 'fmi-export/fmu2_model_interface.h']:
    if not (sources / rel).is_file():
        raise RuntimeError(f'Incomplete OpenModelica source export: {rel}')
for entry in xml.findall('CoSimulation/SourceFiles/File'):
    rel = Path(entry.get('name'))
    if rel.is_absolute() or '..' in rel.parts or not (sources / rel).is_file():
        raise RuntimeError(f'Missing/invalid declared source: {rel}')
c_files = list(sources.rglob('*.c'))
if len(c_files) < 50:
    raise RuntimeError(f'OpenModelica runtime sources missing ({len(c_files)} C files)')
target = base / f'{model_id}.fmu'
with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
    z.write(root_dir / 'modelDescription.xml', 'modelDescription.xml')
    for name in ['sources', 'resources', 'documentation']:
        directory = root_dir / name
        if directory.is_dir():
            for p in sorted(directory.rglob('*')):
                if p.is_file():
                    z.write(p, p.relative_to(root_dir).as_posix())
manifest = json.loads((base / 'selector_manifest.json').read_text())
manifest.update(source_packaging='generated fmutmp metadata and sources, no native Linux build',
                source_c_files=len(c_files), fmu_sha256=hashlib.sha256(target.read_bytes()).hexdigest())
(base / 'selector_manifest.json').write_text(json.dumps(manifest, indent=2))
print(f'SOURCE_ONLY_FMU_PACKAGED={target} bytes={target.stat().st_size} c_files={len(c_files)}')
