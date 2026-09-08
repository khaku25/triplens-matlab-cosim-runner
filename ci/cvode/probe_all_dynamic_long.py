"""Long baseline probe that records every dynamic FMI variable, not only 7 outputs.

Uses the actual FMI2 Co-Simulation FMU. Static parameters/calculatedParameters are
excluded from the time-series because they do not evolve; all local/input/output
dynamic variables are mapped in metadata. Aliases are preserved via valueReference
mapping while each unique FMI value is stored once.
"""
from __future__ import annotations
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import time
import zipfile
import xml.etree.ElementTree as ET

import h5py
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

MODEL='TripLens_CombinedCycle_TripTAC_CoSim'
KEY_OUTPUTS=['hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure',
             'lpDrumLevel','lpDrumPressure','stElectricalPower']
INPUTS={'gtExhaustFlowCmd':606.94,'gtExhaustTemperatureCmd':893.75}


def parse_dynamic_variables(fmu: Path):
    with zipfile.ZipFile(fmu) as z:
        root=ET.fromstring(z.read('modelDescription.xml'))
    variables=[]
    for sv in root.find('ModelVariables'):
        causality=sv.attrib.get('causality','local')
        if causality in {'parameter','calculatedParameter'}:
            continue
        child=next(iter(sv))
        variables.append({
            'name':sv.attrib['name'],
            'valueReference':int(sv.attrib['valueReference']),
            'causality':causality,
            'variability':sv.attrib.get('variability'),
            'type':child.tag,
            'unit':child.attrib.get('unit'),
            'description':sv.attrib.get('description'),
        })
    return variables


def unique_refs(variables, kind):
    refs=[]; index={}
    for v in variables:
        if v['type']!=kind: continue
        r=v['valueReference']
        if r not in index:
            index[r]=len(refs); refs.append(r)
        v['stored_index']=index[r]
    return refs


def write_json(path: Path, value):
    path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--fmu',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--stop',type=float,default=420.0)
    ap.add_argument('--step',type=float,default=0.1)
    ap.add_argument('--label',default='baseline_420s')
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    n=round(a.stop/a.step)
    assert math.isclose(n*a.step,a.stop,rel_tol=0,abs_tol=1e-12)

    variables=parse_dynamic_variables(a.fmu)
    real_refs=unique_refs(variables,'Real')
    bool_refs=unique_refs(variables,'Boolean')
    int_refs=unique_refs(variables,'Integer')
    string_refs=unique_refs(variables,'String')
    physical_real=[v for v in variables if v['type']=='Real' and v.get('unit')]
    unit_indices=sorted({v['stored_index'] for v in physical_real})
    meta={
        'label':a.label,'stop_s':a.stop,'communication_step_s':a.step,
        'dynamic_variable_count':len(variables),
        'dynamic_counts_by_type':{k:sum(v['type']==k for v in variables) for k in ['Real','Boolean','Integer','String']},
        'unit_bearing_physical_real_count':len(physical_real),
        'unique_value_reference_counts':{'Real':len(real_refs),'Boolean':len(bool_refs),'Integer':len(int_refs),'String':len(string_refs)},
        'variables':variables,
        'static_parameters_excluded_from_timeseries':True,
        'actual_fmi_cosimulation':True,
        'csv_replay':False,
        'inputs_held_nominal':INPUTS,
    }
    write_json(a.out/'all_dynamic_variable_map.json',meta)
    print('ALL_DYNAMIC_VARIABLE_COUNT='+str(len(variables)),flush=True)
    print('UNIT_BEARING_PHYSICAL_REAL_COUNT='+str(len(physical_real)),flush=True)
    print('UNIQUE_REAL_REFERENCES='+str(len(real_refs)),flush=True)
    print('UNIQUE_BOOLEAN_REFERENCES='+str(len(bool_refs)),flush=True)
    assert len(variables)>=12000, 'Unexpectedly small dynamic variable inventory'
    assert len(physical_real)>=8000, 'Unexpectedly small unit-bearing physical inventory'
    assert not string_refs, 'Dynamic strings are not handled by this probe'

    report={'status':'not_started','initialization_passed':False,'last_completed_time_s':0.0,
            'stop_s':a.stop,'step_s':a.step,'samples_expected':n+1,
            'all_dynamic_variable_count':len(variables),
            'unit_bearing_physical_real_count':len(physical_real),
            'all_unit_bearing_real_finite':False,'actual_fmi_cosimulation':True,'csv_replay':False}
    temp=None; fmu=None; initialized=False; start=time.perf_counter()
    key_refs={v['name']:v['valueReference'] for v in variables if v['name'] in KEY_OUTPUTS+list(INPUTS)}
    missing=[x for x in KEY_OUTPUTS+list(INPUTS) if x not in key_refs]
    assert not missing, 'Missing key variables: '+repr(missing)

    h5_path=a.out/(a.label+'_all_dynamic.h5')
    stats_min=np.full(len(real_refs),np.inf); stats_max=np.full(len(real_refs),-np.inf)
    stats_first=None; stats_last=None; bool_first=None; bool_last=None; bool_transitions=np.zeros(len(bool_refs),dtype=np.int64)
    nonfinite_first_seen={}
    try:
        md=read_model_description(str(a.fmu),validate=False)
        temp=extract(str(a.fmu))
        fmu=FMU2Slave(guid=md.guid,unzipDirectory=temp,modelIdentifier=md.coSimulation.modelIdentifier,instanceName='TripLens_Long_AllDynamic')
        fmu.instantiate(loggingOn=False)
        fmu.setupExperiment(startTime=0.0,tolerance=1e-6)
        fmu.enterInitializationMode()
        fmu.setReal([key_refs[k] for k in INPUTS],[INPUTS[k] for k in INPUTS])
        fmu.exitInitializationMode(); initialized=True; report['initialization_passed']=True
        print('LONG_ALL_VARIABLE_INITIALIZATION_PASS',flush=True)

        with h5py.File(h5_path,'w') as h5:
            h5.attrs['model']=MODEL; h5.attrs['stop_s']=a.stop; h5.attrs['step_s']=a.step
            ds_t=h5.create_dataset('time_s',(n+1,),dtype='f8')
            chunk_rows=max(1,min(16,n+1))
            ds_r=h5.create_dataset('real_values',(n+1,len(real_refs)),dtype='f8',chunks=(chunk_rows,min(1024,len(real_refs))),compression='gzip',compression_opts=1,shuffle=True)
            ds_b=h5.create_dataset('boolean_values',(n+1,len(bool_refs)),dtype='u1',chunks=(chunk_rows,max(1,min(1024,len(bool_refs)))),compression='gzip',compression_opts=1,shuffle=True) if bool_refs else None
            ds_i=h5.create_dataset('integer_values',(n+1,len(int_refs)),dtype='i4',chunks=(chunk_rows,max(1,min(1024,len(int_refs)))),compression='gzip',compression_opts=1,shuffle=True) if int_refs else None

            prev_bool=None
            for sample in range(n+1):
                t=sample*a.step
                real=np.asarray(fmu.getReal(real_refs),dtype=np.float64)
                boolean=np.asarray(fmu.getBoolean(bool_refs),dtype=np.uint8) if bool_refs else np.empty(0,dtype=np.uint8)
                integer=np.asarray(fmu.getInteger(int_refs),dtype=np.int32) if int_refs else np.empty(0,dtype=np.int32)
                ds_t[sample]=t; ds_r[sample,:]=real
                if ds_b is not None: ds_b[sample,:]=boolean
                if ds_i is not None: ds_i[sample,:]=integer

                if sample==0:
                    stats_first=real.copy(); bool_first=boolean.copy()
                stats_last=real.copy(); bool_last=boolean.copy()
                stats_min=np.minimum(stats_min,real); stats_max=np.maximum(stats_max,real)
                if prev_bool is not None: bool_transitions += (boolean!=prev_bool)
                prev_bool=boolean.copy()

                # Every unit-bearing physical Real must remain finite. We still store all dynamic Reals.
                if unit_indices:
                    finite=np.isfinite(real[unit_indices])
                    if not finite.all():
                        bad_unique={unit_indices[j] for j,ok in enumerate(finite) if not ok}
                        bad_names=[v['name'] for v in physical_real if v['stored_index'] in bad_unique][:100]
                        for name in bad_names: nonfinite_first_seen.setdefault(name,t)
                        raise AssertionError('Nonfinite unit-bearing physical Real(s) at t='+str(t)+': '+repr(bad_names[:20]))

                # Key sanity checks throughout the run.
                def value(name):
                    v=next(v for v in variables if v['name']==name)
                    return real[v['stored_index']]
                levels=np.array([value('hpDrumLevel'),value('ipDrumLevel'),value('lpDrumLevel')])
                pressures=np.array([value('hpDrumPressure'),value('ipDrumPressure'),value('lpDrumPressure')])
                power=value('stElectricalPower')
                assert np.all((levels>0)&(levels<4.1)), 'Invalid drum level at t='+str(t)
                assert np.all((pressures>1e3)&(pressures<1e8)), 'Invalid drum pressure at t='+str(t)
                assert 1e3<abs(power)<1e10, 'Invalid ST power at t='+str(t)

                if sample in {0,round(10/a.step),round(60/a.step),round(300/a.step),n}:
                    checkpoint={'time_s':t,'sample':sample,'stElectricalPower_W':float(power),
                                'hpDrumLevel_m':float(levels[0]),'ipDrumLevel_m':float(levels[1]),'lpDrumLevel_m':float(levels[2]),
                                'hpDrumPressure_Pa':float(pressures[0]),'ipDrumPressure_Pa':float(pressures[1]),'lpDrumPressure_Pa':float(pressures[2]),
                                'unit_bearing_physical_reals_finite':True}
                    write_json(a.out/('checkpoint_'+('%06.1f'%t).replace('.','p')+'s.json'),checkpoint)
                    print('LONG_CHECKPOINT '+json.dumps(checkpoint,separators=(',',':')),flush=True)
                    h5.flush()

                if sample<n:
                    fmu.setReal([key_refs[k] for k in INPUTS],[INPUTS[k] for k in INPUTS])
                    fmu.doStep(currentCommunicationPoint=t,communicationStepSize=a.step)
                    report['last_completed_time_s']=(sample+1)*a.step

        report.update(status='pass',samples=n+1,all_unit_bearing_real_finite=True,
                      hdf5_file=h5_path.name,hdf5_bytes=h5_path.stat().st_size)
        print('LONG_ALL_DYNAMIC_420S_PASS',flush=True)
    except Exception as e:
        report.update(status='failure',error=repr(e),initialization_passed=initialized,nonfinite_first_seen=nonfinite_first_seen)
        print('LONG_ALL_DYNAMIC_FAILURE '+repr(e),flush=True)
        raise
    finally:
        report['wall_seconds']=time.perf_counter()-start
        if stats_first is not None:
            summary=[]
            # Summary row for every dynamic Real variable, aliases included.
            for v in variables:
                if v['type']!='Real': continue
                j=v['stored_index']
                summary.append({'name':v['name'],'valueReference':v['valueReference'],'causality':v['causality'],'unit':v.get('unit'),
                                'first':float(stats_first[j]),'last':float(stats_last[j]),'min':float(stats_min[j]),'max':float(stats_max[j]),
                                'delta':float(stats_last[j]-stats_first[j])})
            write_json(a.out/'all_dynamic_real_summary.json',summary)
        if bool_first is not None:
            summary=[]
            for v in variables:
                if v['type']!='Boolean': continue
                j=v['stored_index']
                summary.append({'name':v['name'],'valueReference':v['valueReference'],'causality':v['causality'],
                                'first':bool(bool_first[j]),'last':bool(bool_last[j]),'transition_count':int(bool_transitions[j])})
            write_json(a.out/'all_dynamic_boolean_summary.json',summary)
        write_json(a.out/'long_all_dynamic_report.json',report)
        print(json.dumps(report,indent=2),flush=True)
        if fmu:
            try:
                if initialized: fmu.terminate()
                fmu.freeInstance()
            except Exception as cleanup_error:
                print('CLEANUP_ERROR='+repr(cleanup_error),flush=True)
        if temp: shutil.rmtree(temp,ignore_errors=True)

if __name__=='__main__': main()
