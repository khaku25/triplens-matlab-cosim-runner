"""420 s CVODE baseline stability probe over the full FMI variable inventory.

The FMU always solves the complete generated ThermoSysPro equation system. This
probe additionally reads every FMI Real variable at regular audit points, plus
all Integer/Boolean variables, so a short list of exposed outputs cannot hide a
non-finite internal state. It does not replay CSV data.
"""
from __future__ import annotations
import argparse, csv, json, math, shutil, tempfile, time, zipfile
from pathlib import Path
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

KEY=['hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure',
     'lpDrumLevel','lpDrumPressure','stElectricalPower']
CHECKPOINTS=(10.0,60.0,300.0,420.0)

def chunks(xs,n=2048):
    for i in range(0,len(xs),n): yield xs[i:i+n]

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--fmu',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--stop',type=float,default=420.0)
    ap.add_argument('--step',type=float,default=0.1)
    ap.add_argument('--audit-step',type=float,default=1.0)
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    report={'status':'not_started','stop_s':a.stop,'step_s':a.step,
            'audit_step_s':a.audit_step,'is_csv_replay':False,
            'simulation_engine':'actual FMI2 CoSimulation CVODE',
            'checkpoints':{},'last_completed_time_s':0.0}
    temp=None; fmu=None; initialized=False; key_rows=[]; t0=time.perf_counter()
    try:
        with zipfile.ZipFile(a.fmu) as z:
            manifest=json.loads(z.read('resources/cvode_build_manifest.json'))
            assert manifest['integrator']=='CVODE'
        md=read_model_description(str(a.fmu),validate=False)
        byname={v.name:v for v in md.modelVariables}
        real_vars=[v for v in md.modelVariables if v.type=='Real']
        int_vars=[v for v in md.modelVariables if v.type in ('Integer','Enumeration')]
        bool_vars=[v for v in md.modelVariables if v.type=='Boolean']
        report['inventory']={'total':len(md.modelVariables),'real':len(real_vars),
                             'integer_or_enum':len(int_vars),'boolean':len(bool_vars),
                             'inputs':sum(v.causality=='input' for v in md.modelVariables),
                             'outputs':sum(v.causality=='output' for v in md.modelVariables)}
        temp=extract(str(a.fmu))
        fmu=FMU2Slave(guid=md.guid,unzipDirectory=temp,
            modelIdentifier=md.coSimulation.modelIdentifier,instanceName='TripLens_Long_AllVars')
        fmu.instantiate(loggingOn=False); fmu.setupExperiment(startTime=0.0,tolerance=1e-6)
        fmu.enterInitializationMode()
        inputs=[byname['gtExhaustFlowCmd'].valueReference,byname['gtExhaustTemperatureCmd'].valueReference]
        fmu.setReal(inputs,[606.94,893.75]); fmu.exitInitializationMode(); initialized=True
        keyrefs=[byname[n].valueReference for n in KEY]
        first=np.asarray(fmu.getReal(keyrefs),float)
        assert np.isfinite(first).all(); key_rows.append([0.0]+first.tolist())
        real_refs=[v.valueReference for v in real_vars]
        int_refs=[v.valueReference for v in int_vars]
        bool_refs=[v.valueReference for v in bool_vars]
        rmin=np.full(len(real_refs),np.inf); rmax=np.full(len(real_refs),-np.inf); rlast=np.zeros(len(real_refs))
        audits=0
        def audit(now):
            nonlocal audits,rlast,rmin,rmax
            vals=[]
            for c in chunks(real_refs): vals.extend(fmu.getReal(c))
            arr=np.asarray(vals,float)
            bad=np.flatnonzero(~np.isfinite(arr))
            if len(bad):
                names=[real_vars[i].name for i in bad[:20]]
                raise AssertionError('Non-finite internal Real variables: '+repr(names))
            rmin=np.minimum(rmin,arr); rmax=np.maximum(rmax,arr); rlast=arr; audits+=1
            # Also prove all discrete variables are readable at the same audit point.
            for c in chunks(int_refs): fmu.getInteger(c)
            for c in chunks(bool_refs): fmu.getBoolean(c)
            return {'time_s':now,'real_checked':len(arr),'finite_real':int(np.isfinite(arr).sum())}
        report['initial_full_audit']=audit(0.0)
        n=round(a.stop/a.step); assert math.isclose(n*a.step,a.stop,abs_tol=1e-12)
        audit_every=round(a.audit_step/a.step); assert audit_every>=1 and math.isclose(audit_every*a.step,a.audit_step)
        checkpoint_set={round(x/a.step):x for x in CHECKPOINTS if x<=a.stop+1e-12}
        for k in range(n):
            t=k*a.step
            fmu.setReal(inputs,[606.94,893.75])
            fmu.doStep(currentCommunicationPoint=t,communicationStepSize=a.step)
            now=(k+1)*a.step; report['last_completed_time_s']=now
            key=np.asarray(fmu.getReal(keyrefs),float)
            assert np.isfinite(key).all(),'Non-finite exposed physical output'
            assert ((key[[0,2,4]]>0)&(key[[0,2,4]]<4.1)).all(),'Invalid drum level'
            assert ((key[[1,3,5]]>1e3)&(key[[1,3,5]]<1e8)).all(),'Invalid drum pressure'
            assert 1e3<abs(key[6])<1e10,'Invalid ST power'
            key_rows.append([now]+key.tolist())
            step_index=k+1
            if step_index%audit_every==0:
                info=audit(now)
                if step_index in checkpoint_set:
                    report['checkpoints'][str(checkpoint_set[step_index])]=dict(info,key_outputs=dict(zip(KEY,key.tolist())))
                    print('LONG_CHECKPOINT_PASS',now,flush=True)
        assert report['last_completed_time_s']>=a.stop-a.step/2
        report['status']='pass'; report['audits']=audits
        # Compact whole-inventory statistics; no gigantic 58M-cell trace artifact.
        stats=[]
        for i,v in enumerate(real_vars):
            stats.append([v.name,v.valueReference,v.causality or '',v.variability or '',rmin[i],rmax[i],rlast[i]])
        with (a.out/'all_real_variable_stats.csv').open('w',newline='') as f:
            w=csv.writer(f); w.writerow(['name','valueReference','causality','variability','min','max','last']); w.writerows(stats)
        print('CVODE_420S_FULL_VARIABLE_STABILITY_PASS',flush=True)
    except Exception as e:
        report.update(status='failure',error=repr(e),initialization_passed=initialized)
        raise
    finally:
        report['wall_seconds']=time.perf_counter()-t0
        (a.out/'long_all_vars_result.json').write_text(json.dumps(report,indent=2))
        if key_rows:
            with (a.out/'key_physics_0p1s.csv').open('w',newline='') as f:
                w=csv.writer(f); w.writerow(['time_s']+KEY); w.writerows(key_rows)
        print(json.dumps(report,indent=2),flush=True)
        if fmu:
            try:
                if initialized:fmu.terminate()
                fmu.freeInstance()
            except Exception: pass
        if temp: shutil.rmtree(temp,ignore_errors=True)

if __name__=='__main__': main()
