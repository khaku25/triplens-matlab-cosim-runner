"""Independent GT Trip physical revalidation for the 3-input TripTAC FMU.

Purpose
-------
Isolate the established GT boundary command from the newly-added ST intertrip.
The ST physical trip input is held at zero for the whole run.  Therefore any
process response in this test is caused by the GT exhaust boundary change only.

This is a real FMI 2.0 Co-Simulation execution, not CSV replay.
"""
from __future__ import annotations
import argparse, json, math, shutil, time, zipfile
from pathlib import Path
import xml.etree.ElementTree as ET
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

MODEL = 'TripLens_CombinedCycle_TripTAC_CoSim'
INPUTS = ['gtExhaustFlowCmd', 'gtExhaustTemperatureCmd', 'stTripCmd']
KEY = [
    'stElectricalPower',
    'hpDrumLevel','hpDrumPressure',
    'ipDrumLevel','ipDrumPressure',
    'lpDrumLevel','lpDrumPressure',
    'hpTurbineAdmissionOpening','mpTurbineAdmissionOpening',
]
NOMINAL = [606.94, 893.75, 0.0]
GT_TRIP = [150.0, 550.0, 0.0]


def dump(path: Path, obj):
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def variables(path: Path):
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read('modelDescription.xml'))
    ans = {}
    for sv in root.find('ModelVariables'):
        child = next(iter(sv))
        ans[sv.attrib['name']] = {
            'vr': int(sv.attrib['valueReference']),
            'type': child.tag,
            'causality': sv.attrib.get('causality', 'local'),
            'unit': child.attrib.get('unit', ''),
        }
    return ans


def pct(new, old):
    return None if abs(old) < 1e-12 else 100.0 * (new - old) / abs(old)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--fmu', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--trip-at', type=float, default=5.0)
    p.add_argument('--stop', type=float, default=125.0)
    p.add_argument('--step', type=float, default=0.1)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)

    n = round(a.stop / a.step)
    assert math.isclose(n * a.step, a.stop, abs_tol=1e-12)
    trip_index = round(a.trip_at / a.step)
    V = variables(a.fmu)
    missing = [x for x in INPUTS + KEY if x not in V]
    assert not missing, f'missing FMI variables: {missing}'
    assert all(V[x]['causality'] == 'input' for x in INPUTS)

    md = read_model_description(str(a.fmu), validate=False)
    temp = extract(str(a.fmu))
    fmu = FMU2Slave(
        guid=md.guid,
        unzipDirectory=temp,
        modelIdentifier=md.coSimulation.modelIdentifier,
        instanceName='TripLens_GT_Trip_Revalidation',
    )
    report = {
        'status': 'not_started',
        'actual_fmi_cosimulation': True,
        'csv_replay': False,
        'st_trip_input_held_zero': True,
        'trip_at_s': a.trip_at,
        'stop_s': a.stop,
        'step_s': a.step,
        'nominal_command': dict(zip(INPUTS, NOMINAL)),
        'gt_trip_command': dict(zip(INPUTS, GT_TRIP)),
    }
    start = time.perf_counter()
    initialized = False
    try:
        fmu.instantiate(loggingOn=False)
        fmu.setupExperiment(startTime=0.0, tolerance=1e-6)
        fmu.enterInitializationMode()
        inrefs = [V[x]['vr'] for x in INPUTS]
        fmu.setReal(inrefs, NOMINAL)
        fmu.exitInitializationMode()
        initialized = True
        print('GT_REVALIDATION_INITIALIZATION_PASS', flush=True)

        outrefs = [V[x]['vr'] for x in KEY]
        checkpoints = {0.0, a.trip_at - a.step, a.trip_at, a.trip_at + a.step,
                       10.0, 30.0, 60.0, 90.0, a.stop}
        checkpoints = {round(x, 10) for x in checkpoints if 0 <= x <= a.stop}
        cp = {}
        pre = None
        final = None
        traces = {k: [] for k in KEY}
        times = []

        for s in range(n + 1):
            t = round(s * a.step, 10)
            vals = fmu.getReal(outrefs)
            snap = {k: float(v) for k, v in zip(KEY, vals)}
            assert np.isfinite(list(snap.values())).all(), f'nonfinite key output at t={t}: {snap}'
            times.append(t)
            for k in KEY:
                traces[k].append(snap[k])
            if t == round(a.trip_at - a.step, 10):
                pre = dict(snap)
            if t in checkpoints:
                cp[str(t)] = snap
                print('GT_REVALIDATION_CHECKPOINT ' + json.dumps({'time_s': t, **snap}, separators=(',', ':')), flush=True)
            final = dict(snap)
            if s < n:
                cmd = NOMINAL if t < a.trip_at else GT_TRIP
                fmu.setReal(inrefs, cmd)
                fmu.doStep(currentCommunicationPoint=t, communicationStepSize=a.step)

        assert pre is not None and final is not None
        initial_st = traces['stElectricalPower'][0]
        final_st = final['stElectricalPower']
        min_st = min(traces['stElectricalPower'])
        hp_open = traces['hpTurbineAdmissionOpening']
        mp_open = traces['mpTurbineAdmissionOpening']

        # Isolation invariant: without ST trip input the new physical ST-trip adapter
        # must not close the admission valves. A process-driven variation is tolerated,
        # but the commanded opening should remain at the native 0.8 setting.
        hp_valve_stayed_native = max(abs(x - 0.8) for x in hp_open) < 1e-6
        mp_valve_stayed_native = max(abs(x - 0.8) for x in mp_open) < 1e-6

        report.update({
            'status': 'pass',
            'initialization_passed': True,
            'pre_trip': pre,
            'final': final,
            'checkpoints': cp,
            'st_power_initial_W': initial_st,
            'st_power_pre_trip_W': pre['stElectricalPower'],
            'st_power_final_W': final_st,
            'st_power_min_W': min_st,
            'st_power_final_change_pct_vs_pretrip': pct(final_st, pre['stElectricalPower']),
            'st_power_min_change_pct_vs_pretrip': pct(min_st, pre['stElectricalPower']),
            'hp_admission_stayed_native_0p8': hp_valve_stayed_native,
            'mp_admission_stayed_native_0p8': mp_valve_stayed_native,
            'drum_level_final_minus_pretrip_m': {
                'hp': final['hpDrumLevel'] - pre['hpDrumLevel'],
                'ip': final['ipDrumLevel'] - pre['ipDrumLevel'],
                'lp': final['lpDrumLevel'] - pre['lpDrumLevel'],
            },
            'interpretation_gate': {
                'strong_trip_like_if_st_power_drop_pct_le_minus_70': (pct(min_st, pre['stElectricalPower']) or 0) <= -70.0,
                'moderate_derating_if_drop_between_20_and_70_pct': -70.0 < (pct(min_st, pre['stElectricalPower']) or 0) <= -20.0,
                'weak_response_if_drop_gt_minus_20_pct': (pct(min_st, pre['stElectricalPower']) or 0) > -20.0,
            },
        })
        assert hp_valve_stayed_native and mp_valve_stayed_native, 'ST admission valve changed despite stTripCmd=0'
        print('GT_TRIP_PHYSICAL_REVALIDATION_PASS', flush=True)
        print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
    except Exception as e:
        report.update(status='failure', initialization_passed=initialized, error=repr(e))
        print('GT_TRIP_PHYSICAL_REVALIDATION_FAILURE ' + repr(e), flush=True)
        raise
    finally:
        report['wall_seconds'] = time.perf_counter() - start
        dump(a.out / 'gt_trip_physical_revalidation.json', report)
        try:
            if initialized:
                fmu.terminate()
            fmu.freeInstance()
        except Exception:
            pass
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
