"""120 s GT exhaust-trip response probe using the proven CVODE FMI2 Co-Simulation FMU.

0..60 s: nominal GT exhaust boundary.
60..120 s: flow 606.94 -> 150 kg/s and temperature 893.75 -> 550 K.
All dynamic FMI variables are recorded; all unit-bearing Real variables are checked finite.
This is an actual FMU calculation, never CSV replay.
"""
from __future__ import annotations
import argparse, json, math, shutil, time, zipfile, xml.etree.ElementTree as ET
from pathlib import Path
import h5py
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

MODEL='TripLens_CombinedCycle_TripTAC_CoSim'
KEY=['hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower']
NOMINAL={'gtExhaustFlowCmd':606.94,'gtExhaustTemperatureCmd':893.75}
TRIP={'gtExhaustFlowCmd':150.0,'gtExhaustTemperatureCmd':550.0}
TRIP_TIME=60.0

def parse_vars(fmu: Path):
    with zipfile.ZipFile(fmu) as z:
        root=ET.fromstring(z.read('modelDescription.xml'))
    out=[]
    for sv in root.find('ModelVariables'):
        caus=sv.attrib.get('causality','local')
        if caus in {'parameter','calculatedParameter'}:
            continue
        child=next(iter(sv))
        out.append({'name':sv.attrib['name'],'valueReference':int(sv.attrib['valueReference']),
                    'causality':caus,'variability':sv.attrib.get('variability'),'type':child.tag,
                    'unit':child.attrib.get('unit'),'description':sv.attrib.get('description')})
    return out

def unique_refs(vars_, typ):
    refs=[]; idx={}
    for v in vars_:
        if v['type']!=typ: continue
        r=v['valueReference']
        if r not in idx: idx[r]=len(refs); refs.append(r)
        v['stored_index']=idx[r]
    return refs

def write_json(p: Path, x): p.write_text(json.dumps(x,indent=2,ensure_ascii=False)+'\n')

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--fmu',type=Path,required=True); ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--stop',type=float,default=120.0); ap.add_argument('--step',type=float,default=0.1)
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    n=round(a.stop/a.step); assert math.isclose(n*a.step,a.stop,abs_tol=1e-12)
    assert a.stop>TRIP_TIME

    vars_=parse_vars(a.fmu)
    real_refs=unique_refs(vars_,'Real'); bool_refs=unique_refs(vars_,'Boolean'); int_refs=unique_refs(vars_,'Integer')
    physical=[v for v in vars_ if v['type']=='Real' and v.get('unit')]; physical_idx=sorted({v['stored_index'] for v in physical})
    byname={v['name']:v for v in vars_}; missing=[n for n in KEY+list(NOMINAL) if n not in byname]; assert not missing, missing
    meta={'scenario':'GT exhaust boundary trip','trip_time_s':TRIP_TIME,'nominal_inputs':NOMINAL,'trip_inputs':TRIP,
          'dynamic_variable_count':len(vars_),'unit_bearing_physical_real_count':len(physical),
          'unique_real_references':len(real_refs),'unique_boolean_references':len(bool_refs),'unique_integer_references':len(int_refs),
          'actual_fmi_cosimulation':True,'csv_replay':False,'variables':vars_}
    write_json(a.out/'gt_trip_variable_map.json',meta)
    print('GT_TRIP_DYNAMIC_VARIABLE_COUNT='+str(len(vars_)),flush=True)
    print('GT_TRIP_UNIT_BEARING_REAL_COUNT='+str(len(physical)),flush=True)

    report={'status':'not_started','trip_time_s':TRIP_TIME,'stop_s':a.stop,'step_s':a.step,'samples_expected':n+1,
            'dynamic_variable_count':len(vars_),'unit_bearing_physical_real_count':len(physical),
            'all_unit_bearing_real_finite':False,'actual_fmi_cosimulation':True,'csv_replay':False}
    temp=None; fmu=None; initialized=False; start=time.perf_counter(); snapshots={}
    try:
        md=read_model_description(str(a.fmu),validate=False); temp=extract(str(a.fmu))
        fmu=FMU2Slave(guid=md.guid,unzipDirectory=temp,modelIdentifier=md.coSimulation.modelIdentifier,instanceName='TripLens_GT_Trip_120s')
        fmu.instantiate(loggingOn=False); fmu.setupExperiment(startTime=0.0,tolerance=1e-6); fmu.enterInitializationMode()
        input_refs=[byname[k]['valueReference'] for k in NOMINAL]; fmu.setReal(input_refs,[NOMINAL[k] for k in NOMINAL]); fmu.exitInitializationMode(); initialized=True
        print('GT_TRIP_INITIALIZATION_PASS',flush=True)

        h5p=a.out/'gt_trip_120s_all_dynamic.h5'
        with h5py.File(h5p,'w') as h5:
            h5.attrs['trip_time_s']=TRIP_TIME; h5.attrs['stop_s']=a.stop; h5.attrs['step_s']=a.step
            ds_t=h5.create_dataset('time_s',(n+1,),dtype='f8')
            ds_r=h5.create_dataset('real_values',(n+1,len(real_refs)),dtype='f8',chunks=(8,min(1024,len(real_refs))),compression='gzip',compression_opts=1,shuffle=True)
            ds_b=h5.create_dataset('boolean_values',(n+1,len(bool_refs)),dtype='u1',chunks=(8,max(1,min(1024,len(bool_refs)))),compression='gzip',compression_opts=1,shuffle=True) if bool_refs else None
            ds_i=h5.create_dataset('integer_values',(n+1,len(int_refs)),dtype='i4',chunks=(8,max(1,min(1024,len(int_refs)))),compression='gzip',compression_opts=1,shuffle=True) if int_refs else None
            checkpoint_samples={0,round(10/a.step),round(59.9/a.step),round(60/a.step),round(60.1/a.step),round(61/a.step),round(70/a.step),round(90/a.step),n}
            prev_bool=None; bool_transitions=np.zeros(len(bool_refs),dtype=np.int64)
            for s in range(n+1):
                t=s*a.step
                r=np.asarray(fmu.getReal(real_refs),dtype=np.float64); b=np.asarray(fmu.getBoolean(bool_refs),dtype=np.uint8) if bool_refs else np.empty(0,dtype=np.uint8)
                i=np.asarray(fmu.getInteger(int_refs),dtype=np.int32) if int_refs else np.empty(0,dtype=np.int32)
                ds_t[s]=t; ds_r[s,:]=r
                if ds_b is not None: ds_b[s,:]=b
                if ds_i is not None: ds_i[s,:]=i
                if prev_bool is not None: bool_transitions += (b!=prev_bool)
                prev_bool=b.copy()
                finite=np.isfinite(r[physical_idx]);
                if not finite.all():
                    bad_unique={physical_idx[j] for j,ok in enumerate(finite) if not ok}
                    bad=[v['name'] for v in physical if v['stored_index'] in bad_unique][:30]
                    raise AssertionError(f'Nonfinite physical Real at t={t}: {bad}')
                def val(name): return float(r[byname[name]['stored_index']])
                levels=np.array([val('hpDrumLevel'),val('ipDrumLevel'),val('lpDrumLevel')]); prs=np.array([val('hpDrumPressure'),val('ipDrumPressure'),val('lpDrumPressure')]); pwr=val('stElectricalPower')
                assert np.all((levels>-1)&(levels<5)), f'Absurd drum level at {t}'
                assert np.all((prs>1e3)&(prs<1e8)), f'Absurd drum pressure at {t}'
                assert np.isfinite(pwr) and abs(pwr)<1e10, f'Absurd ST power at {t}'
                if s in checkpoint_samples:
                    x={'time_s':t,'flow_kg_s':NOMINAL['gtExhaustFlowCmd'] if t<TRIP_TIME else TRIP['gtExhaustFlowCmd'],
                       'temperature_K':NOMINAL['gtExhaustTemperatureCmd'] if t<TRIP_TIME else TRIP['gtExhaustTemperatureCmd'],
                       'stElectricalPower_W':pwr,'hpDrumLevel_m':levels[0],'ipDrumLevel_m':levels[1],'lpDrumLevel_m':levels[2],
                       'hpDrumPressure_Pa':prs[0],'ipDrumPressure_Pa':prs[1],'lpDrumPressure_Pa':prs[2],
                       'all_unit_bearing_reals_finite':True}
                    snapshots[str(t)]=x; print('GT_TRIP_CHECKPOINT '+json.dumps(x,separators=(',',':')),flush=True); h5.flush()
                if s<n:
                    cmd=NOMINAL if t<TRIP_TIME else TRIP
                    fmu.setReal(input_refs,[cmd[k] for k in NOMINAL]); fmu.doStep(currentCommunicationPoint=t,communicationStepSize=a.step)
                    report['last_completed_time_s']=(s+1)*a.step
            h5.attrs['boolean_transition_total']=int(bool_transitions.sum())
        pre=snapshots[str(59.900000000000006)] if str(59.900000000000006) in snapshots else snapshots.get('59.9')
        end=snapshots[str(a.stop)]
        report.update(status='pass',samples=n+1,all_unit_bearing_real_finite=True,hdf5_file=h5p.name,hdf5_bytes=h5p.stat().st_size,
                      snapshots=snapshots,pretrip_to_end={
                          'stElectricalPower_delta_W':end['stElectricalPower_W']-pre['stElectricalPower_W'],
                          'hpDrumLevel_delta_m':end['hpDrumLevel_m']-pre['hpDrumLevel_m'],
                          'ipDrumLevel_delta_m':end['ipDrumLevel_m']-pre['ipDrumLevel_m'],
                          'lpDrumLevel_delta_m':end['lpDrumLevel_m']-pre['lpDrumLevel_m'],
                          'hpDrumPressure_delta_Pa':end['hpDrumPressure_Pa']-pre['hpDrumPressure_Pa'],
                          'ipDrumPressure_delta_Pa':end['ipDrumPressure_Pa']-pre['ipDrumPressure_Pa'],
                          'lpDrumPressure_delta_Pa':end['lpDrumPressure_Pa']-pre['lpDrumPressure_Pa']})
        assert abs(report['pretrip_to_end']['stElectricalPower_delta_W'])>1e5, 'GT trip produced too little ST response over 60 s'
        print('GT_TRIP_120S_FULL_PHYSICS_PASS',flush=True)
    except Exception as e:
        report.update(status='failure',error=repr(e),initialization_passed=initialized,snapshots=snapshots); print('GT_TRIP_120S_FAILURE '+repr(e),flush=True); raise
    finally:
        report['wall_seconds']=time.perf_counter()-start; write_json(a.out/'gt_trip_120s_report.json',report); print(json.dumps(report,indent=2),flush=True)
        if fmu:
            try:
                if initialized: fmu.terminate()
                fmu.freeInstance()
            except Exception as e: print('CLEANUP_ERROR='+repr(e),flush=True)
        if temp: shutil.rmtree(temp,ignore_errors=True)

if __name__=='__main__': main()
