"""Diagnostic only: seed the pinned FMU from a solved native t=0 state.

Retains all symbolic initialization equations and physical assertions. This is
not FMI get/set-state support and not a restart at an arbitrary simulation time.
The optional runtime correction retains the very vector whose residual passed
an early convergence test; it never fabricates or clamps a physical result.
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

SOURCE_SHA = 'a8d47601321b3313893a019533facc3e433bd11c98c8f1b653a5ec61e1ad1f6a'
MAT_SHA = '21b5f8b7405fa35e3cd4a72fe0b9dc6666ce6892ff3cd35a8289b118fbe12023'
ALIASES = {'hpDrumLevel':'BallonHP.zl','ipDrumLevel':'BallonMP.zl',
 'lpDrumLevel':'BallonBP.zl','hpDrumPressure':'BallonHP.P',
 'ipDrumPressure':'BallonMP.P','lpDrumPressure':'BallonBP.P',
 'stElectricalPower':'Alternateur.Welec'}

def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()

def native_values(path: Path) -> dict[str, float]:
    d = loadmat(path, chars_as_strings=False)
    result = {}
    for i in range(d['name'].shape[1]):
        name = ''.join(d['name'][:, i]).rstrip('\x00 ')
        block, row = map(int, d['dataInfo'][:2, i])
        block = 2 if block == 0 else block
        value = float(d[f'data_{block}'][abs(row)-1, 0]) * (1 if row > 0 else -1)
        if math.isfinite(value):
            result[name] = value
    assert result['time'] == 0.0, 'Only the consistent native t=0 initial solution is supported.'
    return result

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--source-fmu', type=Path, required=True)
    ap.add_argument('--native-mat', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    assert digest(args.source_fmu) == SOURCE_SHA, 'Unexpected source FMU; refuse index-based seeding.'
    assert digest(args.native_mat) == MAT_SHA, 'Unexpected native reference state.'
    values = native_values(args.native_mat)
    args.out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tl-warm-') as temp:
        root = Path(temp)
        with zipfile.ZipFile(args.source_fmu) as z:
            for item in z.infolist():
                target = (root / item.filename).resolve()
                assert target.is_relative_to(root.resolve()), 'Unsafe archive path.'
            z.extractall(root)
        src = root / 'sources'
        init_files = list(src.glob('*_init_fmu.c'))
        assert len(init_files) == 1
        init_text = init_files[0].read_text()
        names = {int(i): n for i, n in re.findall(r'modelData->realVarsData\[(\d+)\]\.info\.name = "(.*?)";', init_text)}
        params = {int(i): n for i, n in re.findall(r'modelData->realParameterData\[(\d+)\]\.info\.name = "(.*?)";', init_text)}
        fixed = {int(i): int(v) for i, v in re.findall(r'modelData->realParameterData\[(\d+)\]\.attribute\.fixed = (\d+);', init_text)}
        var_seeds = []
        for i, name in names.items():
            native_name = name
            for key, val in ALIASES.items():
                native_name = native_name.replace('$outputAlias_' + key, val)
            if native_name in values:
                var_seeds.append((i, native_name, values[native_name]))
        param_seeds = [(i, n, values[n]) for i, n in params.items() if n in values and fixed[i] == 0]
        assert len(var_seeds) >= 8500 and len(param_seeds) == 61
        helper = '/* Actual native initial guesses; no replay of future outputs. */\n'
        helper += 'typedef struct {int index; double value;} TLNativeSeed;\n'
        for table, entries in [('tlNativeSeeds',var_seeds),('tlNativeParameterSeeds',param_seeds)]:
            helper += f'static const TLNativeSeed {table}[]={{\n'
            helper += ''.join(' {%d, %.17g},\n' % (i, v) for i, n, v in entries) + '};\n'
        helper += '''static void tlApplyNativeSeed(ModelInstance *comp) {
 if (!getenv("TRIPLENS_USE_NATIVE_SEED")) return;
 size_t count=sizeof(tlNativeSeeds)/sizeof(tlNativeSeeds[0]);
 for(size_t i=0;i<count;i++) comp->fmuData->localData[0]->realVars[tlNativeSeeds[i].index]=tlNativeSeeds[i].value;
 size_t pc=sizeof(tlNativeParameterSeeds)/sizeof(tlNativeParameterSeeds[0]);
 for(size_t i=0;i<pc;i++) comp->fmuData->simulationInfo->realParameter[tlNativeParameterSeeds[i].index]=tlNativeParameterSeeds[i].value;
 fprintf(stderr,"NATIVE_WARM_SEEDS_APPLIED=%zu CALCULATED_PARAMETER_SEEDS=%zu\\n",count,pc);
}
'''
        (src/'tl_native_seed.h').write_text(helper)
        fmu_c = next(src.glob('*_FMU.c'))
        text = fmu_c.read_text()
        needle = 'void setStartValues(ModelInstance *comp) {'
        assert text.count(needle) == 1
        text = text.replace(needle, '#include "tl_native_seed.h"\n' + needle + '\n  tlApplyNativeSeed(comp);')
        fmu_c.write_text(text)
        solver = src/'simulation/solver/nonlinearSolverHomotopy.c'
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
        # Only the first branch checks f(x0); the second branch has different semantics.
        solver.write_text(text.replace(needle, replacement, 1))
        xml_path = root/'modelDescription.xml'
        xml = xml_path.read_text()
        old_guid = ET.fromstring(xml).get('guid')
        new_guid = '{' + str(uuid.uuid4()) + '}'
        xml_path.write_text(xml.replace(old_guid, new_guid))
        for f in src.rglob('*'):
            if f.is_file() and f.suffix in {'.c','.h'}:
                text = f.read_text()
                if old_guid in text:
                    f.write_text(text.replace(old_guid,new_guid))
        manifest = {'diagnostic_only':True,'state_source_time_s':0.0,
         'source_fmu_sha256':SOURCE_SHA,'native_mat_sha256':MAT_SHA,
         'source_capture_run':34220970632,'source_fmu_run':34217750061,
         'real_variable_seeds':len(var_seeds),'calculated_parameter_seeds':len(param_seeds),
         'guid':new_guid,'symbolic_initialization_retained':True,'physical_assertions_retained':True,
         'physics_equations_modified':False,'runtime_solver_modified':True,
         'runtime_correction':'Retain x0 when its own residual satisfies early-convergence test; enabled by environment.',
         'fmi_state_restore_implemented':False,
         'required_environment':['TRIPLENS_USE_NATIVE_SEED=1','TRIPLENS_RETAIN_VALIDATED_NLS_GUESS=1']}
        (root/'resources').mkdir(exist_ok=True)
        (root/'resources/native_seed_manifest.json').write_text(json.dumps(manifest,indent=2))
        out = args.out/'TripLens_CombinedCycle_TripTAC_CoSim.fmu'
        with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
            for f in sorted(root.rglob('*')):
                if f.is_file() and not f.relative_to(root).as_posix().startswith('binaries/'):
                    z.write(f,f.relative_to(root).as_posix())
        manifest['seeded_fmu_sha256'] = digest(out)
        (args.out/'native_seed_manifest.json').write_text(json.dumps(manifest,indent=2))
        (args.out/'native_seed_mapping.json').write_text(json.dumps({'variables':var_seeds,'calculated_parameters':param_seeds}))
        print(json.dumps(manifest,indent=2))
        print('NATIVE_SEEDED_SOURCE_FMU_PREPARED_NOT_YET_EXECUTED')

if __name__ == '__main__':
    main()
