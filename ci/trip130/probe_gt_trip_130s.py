"""130 s GT-trip probe using the proven CVODE FMI2 Co-Simulation FMU.

Runs 10 s nominal, then commands the established TripTAC boundary values
flow 150 kg/s and temperature 550 K for 120 s. Records every dynamic FMI
variable and audits all unit-bearing Reals for finite values. This is an
input-response physics test, not an ECMS protection closed loop.
"""
from __future__ import annotations
import argparse, json, math, shutil, time, zipfile
from pathlib import Path
import xml.etree.ElementTree as ET
import h5py
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

MODEL='TripLens_CombinedCycle_TripTAC_CoSim'
KEY=['hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower']
NOMINAL={'gtExhaustFlowCmd':606.94,'gtExhaustTemperatureCmd':893.75}
TRIP={'gtExhaustFlowCmd':150.0,'gtExhaustTemperatureCmd':550.0}

def parse_vars(fmu: Path):
    with zipfile.ZipFile(fmu) as z:
        root=ET.fromstring(z.read('modelDescription.xml'))
    out=[]
    for sv in root.find('ModelVariables'):
        if sv.attrib.get('causality','local') in {'parameter','calculatedParameter'}: continue
        child=next(iter(sv))
        out.append({'name':sv.attrib['name'],'valueReference':int(sv.attrib['valueReference']),
                    'causality':sv.attrib.get('causality','local'),'type':child.tag,
                    'unit':child.attrib.get('unit'),'description':sv.attrib.get('description')})
    return out

def unique_refs(vars_, kind):
    refs=[]; idx={}
    for v in vars_:
        if v['type']!=kind: continue
        r=v['valueReference']
        if r not in idx: idx[r]=len(refs); refs.append(r)
        v['stored_index']=idx[r]
    return refs

def dump(p,v): p.write_text(json.dumps(v,indent=2,ensure_ascii=False)+'\n')

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--fmu',type=Path,required=True); ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--stop',type=float,default=130.0); ap.add_argument('--step',type=float,default=0.1); ap.add_argument('--trip-at',type=float,default=10.0)
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    n=round(a.stop/a.step); assert math.isclose(n*a.step,a.stop,abs_tol=1e-12)
    trip_sample=round(a.trip_at/a.step); assert math.isclose(trip_sample*a.step,a.trip_at,abs_tol=1e-12)
    vars_=parse_vars(a.fmu); real_refs=unique_refs(vars_,'Real'); bool_refs=unique_refs(vars_,'Boolean'); int_refs=unique_refs(vars_,'Integer')
    physical=[v for v in vars_ if v['type']=='Real' and v.get('unit')]; unit_idx=sorted({v['stored_index'] for v in physical})
    by_name={v['name']:v for v in vars_}; missing=[x for x in KEY+list(NOMINAL) if x not in by_name]; assert not missing, missing
    report={'status':'not_started','actual_fmi_cosimulation':True,'csv_replay':False,'trip_at_s':a.trip_at,'stop_s':a.stop,'step_s':a.step,
            'post_trip_duration_s':a.stop-a.trip_at,'all_dynamic_variable_count':len(vars_),
            'unit_bearing_physical_real_count':len(physical),'all_unit_bearing_real_finite':False}
    dump(a.out/'variable_inventory.json',{'variables':vars_,'dynamic_variable_count':len(vars_),'unit_bearing_physical_real_count':len(physical)})
    print('ALL_DYNAMIC_VARIABLE_COUNT='+str(len(vars_)),flush=True); print('UNIT_BEARING_PHYSICAL_REAL_COUNT='+str(len(physical)),flush=True)
    temp=None; fmu=None; initialized=False; start=time.perf_counter(); h5p=a.out/'gt_trip_130s_all_dynamic.h5'
    mins=np.full(len(real_refs),np.inf); maxs=np.full(len(real_refs),-np.inf); first=None; last=None; pre=None; after=None
    try:
        md=read_model_description(str(a.fmu),validate=False); temp=extract(str(a.fmu))
        fmu=FMU2Slave(guid=md.guid,unzipDirectory=temp,modelIdentifier=md.coSimulation.modelIdentifier,instanceName='TripLens_GT_Trip_130s')
        fmu.instantiate(loggingOn=False); fmu.setupExperiment(startTime=0.0,tolerance=1e-6); fmu.enterInitializationMode()
        inrefs=[by_name[k]['valueReference'] for k in NOMINAL]; fmu.setReal(inrefs,[NOMINAL[k] for k in NOMINAL]); fmu.exitInitializationMode(); initialized=True
        print('GT_TRIP_INITIALIZATION_PASS',flush=True)
        with h5py.File(h5p,'w') as h5:
            h5.attrs['trip_at_s']=a.trip_at; h5.attrs['stop_s']=a.stop; h5.attrs['step_s']=a.step
            ds_t=h5.create_dataset('time_s',(n+1,),dtype='f8'); ds_r=h5.create_dataset('real_values',(n+1,len(real_refs)),dtype='f8',chunks=(8,min(1024,len(real_refs))),compression='gzip',compression_opts=1,shuffle=True)
            ds_b=h5.create_dataset('boolean_values',(n+1,len(bool_refs)),dtype='u1',chunks=(8,max(1,min(1024,len(bool_refs)))),compression='gzip',compression_opts=1,shuffle=True) if bool_refs else None
            ds_i=h5.create_dataset('integer_values',(n+1,len(int_refs)),dtype='i4',chunks=(8,max(1,min(1024,len(int_refs)))),compression='gzip',compression_opts=1,shuffle=True) if int_refs else None
            checkpoints={0,trip_sample-1,trip_sample,trip_sample+1,round(30/a.step),round(60/a.step),round(130/a.step)}
            for s in range(n+1):
                t=s*a.step; rv=np.asarray(fmu.getReal(real_refs),dtype=float); bv=np.asarray(fmu.getBoolean(bool_refs),dtype=np.uint8) if bool_refs else np.empty(0,dtype=np.uint8); iv=np.asarray(fmu.getInteger(int_refs),dtype=np.int32) if int_refs else np.empty(0,dtype=np.int32)
                ds_t[s]=t; ds_r[s,:]=rv
                if ds_b is not None: ds_b[s,:]=bv
                if ds_i is not None: ds_i[s,:]=iv
                if first is None: first=rv.copy()
                last=rv.copy(); mins=np.minimum(mins,rv); maxs=np.maximum(maxs,rv)
                finite=np.isfinite(rv[unit_idx]);
                if not finite.all():
                    bad={unit_idx[j] for j,ok in enumerate(finite) if not ok}; names=[v['name'] for v in physical if v['stored_index'] in bad][:30]
                    raise AssertionError(f'nonfinite unit-bearing physical reals at t={t}: {names}')
                def val(name): return float(rv[by_name[name]['stored_index']])
                key={k:val(k) for k in KEY}; assert np.isfinite(list(key.values())).all()
                if s==trip_sample-1: pre=key.copy()
                if s==trip_sample+1: after=key.copy()
                if s in checkpoints:
                    cp={'time_s':t,'flow_cmd_kg_s':NOMINAL['gtExhaustFlowCmd'] if t<a.trip_at else TRIP['gtExhaustFlowCmd'],
                        'temperature_cmd_K':NOMINAL['gtExhaustTemperatureCmd'] if t<a.trip_at else TRIP['gtExhaustTemperatureCmd'],**key,'all_unit_bearing_physical_reals_finite':True}
                    dump(a.out/(f'checkpoint_{t:06.1f}s.json'.replace('.','p')),cp); print('GT_TRIP_CHECKPOINT '+json.dumps(cp,separators=(',',':')),flush=True); h5.flush()
                if s<n:
                    cmd=NOMINAL if t<a.trip_at else TRIP; fmu.setReal(inrefs,[cmd[k] for k in NOMINAL]); fmu.doStep(currentCommunicationPoint=t,communicationStepSize=a.step); report['last_completed_time_s']=(s+1)*a.step
        summary=[]
        for v in vars_:
            if v['type']!='Real': continue
            j=v['stored_index']; summary.append({'name':v['name'],'unit':v.get('unit'),'first':float(first[j]),'last':float(last[j]),'min':float(mins[j]),'max':float(maxs[j]),'delta':float(last[j]-first[j])})
        dump(a.out/'all_dynamic_real_summary.json',summary)
        report.update(status='pass',initialization_passed=True,samples=n+1,all_unit_bearing_real_finite=True,hdf5_file=h5p.name,hdf5_bytes=h5p.stat().st_size,
                      pre_trip_key_outputs=pre,first_post_trip_key_outputs=after,final_key_outputs={k:float(last[by_name[k]['stored_index']]) for k in KEY})
        initial_power=float(first[by_name['stElectricalPower']['stored_index']]); final_power=report['final_key_outputs']['stElectricalPower']
        report['st_power_change_W']=final_power-initial_power; report['st_power_change_pct']=100*(final_power-initial_power)/abs(initial_power)
        print('GT_TRIP_ALL_DYNAMIC_130S_PASS',flush=True)
    except Exception as e:
        report.update(status='failure',initialization_passed=initialized,error=repr(e)); print('GT_TRIP_130S_FAILURE '+repr(e),flush=True); raise
    finally:
        report['wall_seconds']=time.perf_counter()-start; dump(a.out/'gt_trip_130s_report.json',report); print(json.dumps(report,indent=2),flush=True)
        if fmu:
            try:
                if initialized: fmu.terminate()
                fmu.freeInstance()
            except Exception as e: print('CLEANUP_ERROR='+repr(e),flush=True)
        if temp: shutil.rmtree(temp,ignore_errors=True)

if __name__=='__main__': main()
