"""Prepare a native-state-seeded TripLens TripTAC source FMU.

The legacy validated 2-input path remains hash-pinned.  The current 3-input
profile is accepted only when it comes from the explicitly recorded build run
and exposes the exact GT/ST physical FMI interface.  Symbolic initialization
and physical assertions remain active; this only supplies the previously solved
native t=0 state as initial guesses and retains the already-validated NLS x0
when its own residual satisfies the early-convergence test.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import tempfile
import uuid
import xml.etree.ElementTree as ET
import zipfile

from scipy.io import loadmat

LEGACY_SOURCE_SHA = 'a8d47601321b3313893a019533facc3e433bd11c98c8f1b653a5ec61e1ad1f6a'
MAT_SHA = '21b5f8b7405fa35e3cd4a72fe0b9dc6666ce6892ff3cd35a8289b118fbe12023'
CURRENT_3INPUT_SOURCE_RUN = 34308733698
MODEL = 'TripLens_CombinedCycle_TripTAC_CoSim'
CURRENT_INPUTS = ['gtExhaustFlowCmd', 'gtExhaustTemperatureCmd', 'stTripCmd']
CURRENT_OUTPUTS = [
    'stElectricalPower',
    'hpDrumLevel', 'ipDrumLevel', 'lpDrumLevel',
    'hpDrumPressure', 'ipDrumPressure', 'lpDrumPressure',
    'hpTurbineInletValveOpening', 'mpTurbineInletValveOpening',
]
ALIASES = {
    'hpDrumLevel': 'BallonHP.zl',
    'ipDrumLevel': 'BallonMP.zl',
    'lpDrumLevel': 'BallonBP.zl',
    'hpDrumPressure': 'BallonHP.P',
    'ipDrumPressure': 'BallonMP.P',
    'lpDrumPressure': 'BallonBP.P',
    'stElectricalPower': 'Alternateur.Welec',
    'hpTurbineInletValveOpening': 'ConstantVanneTurbineHP.y.signal',
    'mpTurbineInletValveOpening': 'ConstantVanneTurbineMP.y.signal',
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_values(path: Path) -> dict[str, float]:
    data = loadmat(path, chars_as_strings=False)
    result: dict[str, float] = {}
    for i in range(data['name'].shape[1]):
        name = ''.join(data['name'][:, i]).rstrip('\x00 ')
        block, row = map(int, data['dataInfo'][:2, i])
        block = 2 if block == 0 else block
        value = float(data[f'data_{block}'][abs(row)-1, 0]) * (1 if row > 0 else -1)
        if math.isfinite(value):
            result[name] = value
    assert result['time'] == 0.0, 'Only the consistent native t=0 initial solution is supported.'
    return result


def interface(path: Path) -> tuple[str, list[str], list[str], dict[str, str]]:
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read('modelDescription.xml'))
    variables = root.find('ModelVariables')
    assert variables is not None
    inputs: list[str] = []
    outputs: list[str] = []
    starts: dict[str, str] = {}
    for variable in variables:
        name = variable.attrib['name']
        causality = variable.attrib.get('causality')
        child = next(iter(variable), None)
        if child is not None and 'start' in child.attrib:
            starts[name] = child.attrib['start']
        if causality == 'input':
            inputs.append(name)
        elif causality == 'output':
            outputs.append(name)
    return root.attrib.get('modelName', ''), inputs, outputs, starts


def validate_source(path: Path, profile: str, source_run_id: int | None) -> dict:
    source_sha = digest(path)
    model_name, inputs, outputs, starts = interface(path)
    if profile == 'legacy-2input':
        assert source_sha == LEGACY_SOURCE_SHA, 'Unexpected legacy source FMU; refuse index-based seeding.'
        return {
            'profile': profile,
            'source_fmu_sha256': source_sha,
            'source_fmu_run': 34217750061,
            'model_name': model_name,
            'inputs': inputs,
            'outputs': outputs,
        }

    assert profile == 'current-3input'
    assert source_run_id == CURRENT_3INPUT_SOURCE_RUN, (
        f'3-input source provenance must be workflow run {CURRENT_3INPUT_SOURCE_RUN}; got {source_run_id}'
    )
    assert inputs == CURRENT_INPUTS, f'unexpected 3-input FMI interface: {inputs}'
    missing = [name for name in CURRENT_OUTPUTS if name not in outputs]
    assert not missing, f'missing 3-input physical outputs: {missing}'
    assert starts.get('stTripCmd', '0') in {'0', '0.0'}, f'unexpected stTripCmd start: {starts.get("stTripCmd")}'
    assert starts.get('gtExhaustFlowCmd', '606.94') == '606.94'
    assert starts.get('gtExhaustTemperatureCmd', '893.75') == '893.75'
    return {
        'profile': profile,
        'source_fmu_sha256': source_sha,
        'source_fmu_run': source_run_id,
        'model_name': model_name,
        'inputs': inputs,
        'outputs': outputs,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-fmu', type=Path, required=True)
    parser.add_argument('--native-mat', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--source-profile', choices=['legacy-2input', 'current-3input'], default='legacy-2input')
    parser.add_argument('--source-run-id', type=int)
    args = parser.parse_args()

    source_info = validate_source(args.source_fmu, args.source_profile, args.source_run_id)
    assert digest(args.native_mat) == MAT_SHA, 'Unexpected native reference state.'
    values = native_values(args.native_mat)
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix='tl-warm-') as temp:
        root = Path(temp)
        with zipfile.ZipFile(args.source_fmu) as archive:
            for item in archive.infolist():
                target = (root / item.filename).resolve()
                assert target.is_relative_to(root.resolve()), 'Unsafe archive path.'
            archive.extractall(root)

        src = root / 'sources'
        init_files = list(src.glob('*_init_fmu.c'))
        assert len(init_files) == 1
        init_text = init_files[0].read_text()
        names = {int(i): n for i, n in re.findall(r'modelData->realVarsData\[(\d+)\]\.info\.name = "(.*?)";', init_text)}
        params = {int(i): n for i, n in re.findall(r'modelData->realParameterData\[(\d+)\]\.info\.name = "(.*?)";', init_text)}
        fixed = {int(i): int(v) for i, v in re.findall(r'modelData->realParameterData\[(\d+)\]\.attribute\.fixed = (\d+);', init_text)}

        var_seeds = []
        for index, name in names.items():
            native_name = name
            for alias, mapped in ALIASES.items():
                native_name = native_name.replace('$outputAlias_' + alias, mapped)
            if native_name in values:
                var_seeds.append((index, native_name, values[native_name]))
        param_seeds = [(i, n, values[n]) for i, n in params.items() if n in values and fixed.get(i) == 0]

        # The new wrapper changes only boundary-source classes.  Thousands of
        # native variables and all 61 calculated parameters must still map by
        # exact name; otherwise stop instead of guessing by index.
        assert len(var_seeds) >= 8400, f'too few native variable matches: {len(var_seeds)}'
        assert len(param_seeds) == 61, f'unexpected calculated parameter matches: {len(param_seeds)}'

        helper = '/* Actual native initial guesses; no replay of future outputs. */\n'
        helper += 'typedef struct {int index; double value;} TLNativeSeed;\n'
        for table, entries in [('tlNativeSeeds', var_seeds), ('tlNativeParameterSeeds', param_seeds)]:
            helper += f'static const TLNativeSeed {table}[]={{\n'
            helper += ''.join(' {%d, %.17g},\n' % (i, v) for i, _, v in entries) + '};\n'
        helper += '''static void tlApplyNativeSeed(ModelInstance *comp) {
 if (!getenv("TRIPLENS_USE_NATIVE_SEED")) return;
 size_t count=sizeof(tlNativeSeeds)/sizeof(tlNativeSeeds[0]);
 for(size_t i=0;i<count;i++) comp->fmuData->localData[0]->realVars[tlNativeSeeds[i].index]=tlNativeSeeds[i].value;
 size_t pc=sizeof(tlNativeParameterSeeds)/sizeof(tlNativeParameterSeeds[0]);
 for(size_t i=0;i<pc;i++) comp->fmuData->simulationInfo->realParameter[tlNativeParameterSeeds[i].index]=tlNativeParameterSeeds[i].value;
 fprintf(stderr,"NATIVE_WARM_SEEDS_APPLIED=%zu CALCULATED_PARAMETER_SEEDS=%zu\\n",count,pc);
}
'''
        (src / 'tl_native_seed.h').write_text(helper)

        fmu_c = next(src.glob('*_FMU.c'))
        text = fmu_c.read_text()
        needle = 'void setStartValues(ModelInstance *comp) {'
        assert text.count(needle) == 1
        fmu_c.write_text(text.replace(needle, '#include "tl_native_seed.h"\n' + needle + '\n  tlApplyNativeSeed(comp);'))

        solver = src / 'simulation/solver/nonlinearSolverHomotopy.c'
        text = solver.read_text()
        needle = '''        /* take the solution */
        vecCopy(homotopyData->n, homotopyData->x, nlsData->nlsx);
        /* reset continous flag */'''
        assert text.count(needle) == 2, 'Runtime revision changed; inspect rather than guessing.'
        replacement = '''        /* Diagnostic correction: f1 above was evaluated at x0, not stale x. */
        if (getenv("TRIPLENS_RETAIN_VALIDATED_NLS_GUESS")) {
          if(homotopyData->x0[0] != homotopyData->x[0])
            fprintf(stderr,"EARLY_CONVERGENCE_RETAIN_X0 eq=%d x0=%.17g old_x=%.17g residual_sq=%.17g\\n",eqSystemNumber,homotopyData->x0[0],homotopyData->x[0],error_f_sqrd);
          vecCopy(homotopyData->n, homotopyData->x0, homotopyData->x);
        }
        vecCopy(homotopyData->n, homotopyData->x, nlsData->nlsx);
        /* reset continous flag */'''
        solver.write_text(text.replace(needle, replacement, 1))

        xml_path = root / 'modelDescription.xml'
        xml = xml_path.read_text()
        old_guid = ET.fromstring(xml).get('guid')
        assert old_guid
        new_guid = '{' + str(uuid.uuid4()) + '}'
        xml_path.write_text(xml.replace(old_guid, new_guid))
        for file in src.rglob('*'):
            if file.is_file() and file.suffix in {'.c', '.h'}:
                body = file.read_text()
                if old_guid in body:
                    file.write_text(body.replace(old_guid, new_guid))

        manifest = {
            'diagnostic_only': True,
            'state_source_time_s': 0.0,
            **source_info,
            'native_mat_sha256': MAT_SHA,
            'source_capture_run': 34220970632,
            'real_variable_seeds': len(var_seeds),
            'calculated_parameter_seeds': len(param_seeds),
            'guid': new_guid,
            'symbolic_initialization_retained': True,
            'physical_assertions_retained': True,
            'physics_equations_modified': False,
            'runtime_solver_modified': True,
            'runtime_correction': 'Retain x0 when its own residual satisfies early-convergence test; enabled by environment.',
            'fmi_state_restore_implemented': False,
            'required_environment': ['TRIPLENS_USE_NATIVE_SEED=1', 'TRIPLENS_RETAIN_VALIDATED_NLS_GUESS=1'],
        }
        (root / 'resources').mkdir(exist_ok=True)
        (root / 'resources/native_seed_manifest.json').write_text(json.dumps(manifest, indent=2))

        out = args.out / 'TripLens_CombinedCycle_TripTAC_CoSim.fmu'
        with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
            for file in sorted(root.rglob('*')):
                if file.is_file() and not file.relative_to(root).as_posix().startswith('binaries/'):
                    archive.write(file, file.relative_to(root).as_posix())
        manifest['seeded_fmu_sha256'] = digest(out)
        (args.out / 'native_seed_manifest.json').write_text(json.dumps(manifest, indent=2))
        (args.out / 'native_seed_mapping.json').write_text(json.dumps({'variables': var_seeds, 'calculated_parameters': param_seeds}))
        print(json.dumps(manifest, indent=2))
        print('NATIVE_SEEDED_SOURCE_FMU_PREPARED_NOT_YET_EXECUTED')


if __name__ == '__main__':
    main()
