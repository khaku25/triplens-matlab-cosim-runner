"""Execute the actual Linux CVODE CS FMU; never replay a stored CSV."""
from __future__ import annotations
import argparse
import csv
import json
import math
from pathlib import Path
import shutil
import tempfile
import time
import zipfile
import numpy as np
from fmpy import extract, read_model_description
from fmpy.fmi2 import FMU2Slave

OUTPUTS=['hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure',
         'lpDrumLevel','lpDrumPressure','stElectricalPower']

def main() -> None:
    ap=argparse.ArgumentParser()
    ap.add_argument('--fmu',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--case',choices=['baseline','flow_step','temperature_step'],required=True)
    ap.add_argument('--stop',type=float,default=2.0)
    ap.add_argument('--step',type=float,default=0.01)
    a=ap.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    report={'case':a.case,'status':'not_started','step_s':a.step,'stop_s':a.stop,
            'last_completed_time_s':0.0,'simulation_engine':'actual FMI2 CoSimulation CVODE',
            'is_csv_replay':False,'closed_loop_ecms_verified':False}
    start=time.perf_counter(); rows=[]; fmu=None; temp=None; initialized=False
    try:
        with zipfile.ZipFile(a.fmu) as z:
            manifest=json.loads(z.read('resources/cvode_build_manifest.json'))
            assert manifest['integrator']=='CVODE' and manifest['sundials_static_linked']
            flags=json.loads(z.read('resources/TripLens_CombinedCycle_TripTAC_CoSim_flags.json'))
            assert flags=={'s':'cvode'}
        md=read_model_description(str(a.fmu),validate=False)
        values={v.name:v.valueReference for v in md.modelVariables}
        temp=extract(str(a.fmu))
        fmu=FMU2Slave(guid=md.guid,unzipDirectory=temp,
            modelIdentifier=md.coSimulation.modelIdentifier,instanceName='TripLens_'+a.case)
        fmu.instantiate(loggingOn=False)
        fmu.setupExperiment(startTime=0.0,tolerance=1e-6)
        fmu.enterInitializationMode()
        inputs=[values['gtExhaustFlowCmd'],values['gtExhaustTemperatureCmd']]
        fmu.setReal(inputs,[606.94,893.75])
        fmu.exitInitializationMode(); initialized=True
        print('CVODE_INITIALIZATION_PASSED',flush=True)
        refs=[values[n] for n in OUTPUTS]
        nominal=np.array(fmu.getReal(refs),dtype=float)
        assert np.isfinite(nominal).all()
        rows.append([0.0,606.94,893.75]+nominal.tolist())
        n=round(a.stop/a.step); assert math.isclose(n*a.step,a.stop)
        for k in range(n):
            t=k*a.step; flow=606.94; temperature=893.75
            if t>=1.0 and a.case=='flow_step': flow*=0.99
            if t>=1.0 and a.case=='temperature_step': temperature*=0.995
            fmu.setReal(inputs,[flow,temperature])
            fmu.doStep(currentCommunicationPoint=t,communicationStepSize=a.step)
            report['last_completed_time_s']=(k+1)*a.step
            outputs=np.array(fmu.getReal(refs),dtype=float)
            assert np.isfinite(outputs).all(), 'Nonfinite physical outputs'
            assert ((outputs[[0,2,4]]>0)&(outputs[[0,2,4]]<4.1)).all(), 'Invalid drum level'
            assert ((outputs[[1,3,5]]>1e3)&(outputs[[1,3,5]]<1e8)).all(), 'Invalid pressure'
            assert 1e3<abs(outputs[6])<1e10, 'Invalid ST output'
            rows.append([(k+1)*a.step,flow,temperature]+outputs.tolist())
        assert report['last_completed_time_s']>=a.stop-a.step/2
        data=np.array(rows)
        if a.case!='baseline':
            baseline=np.genfromtxt(a.out/'baseline.csv',delimiter=',',skip_header=1)
            assert np.allclose(data[:,0],baseline[:,0],rtol=0,atol=1e-12)
            pre=data[:,0]<=1.0; delta=np.abs(data[:,3:]-baseline[:,3:])
            scale=np.maximum(1,np.max(np.abs(baseline[:,3:]),axis=0))
            assert np.max(delta[pre]/scale)<1e-7,'Different pre-event histories'
            post=np.max(delta[~pre],axis=0)
            assert np.any(post/scale>1e-10),'No physical response to changed input'
            report['post_change_max_absolute_response']=dict(zip(OUTPUTS,post.tolist()))
        report.update(status='pass',samples=len(rows),initial_outputs=dict(zip(OUTPUTS,nominal.tolist())),
                      final_outputs=dict(zip(OUTPUTS,outputs.tolist())))
        print('CVODE_TIME_ADVANCEMENT_PASS '+a.case,flush=True)
    except Exception as e:
        report.update(status='failure',error=repr(e),initialization_passed=initialized)
        raise
    finally:
        report['wall_seconds']=time.perf_counter()-start
        (a.out/(a.case+'_result.json')).write_text(json.dumps(report,indent=2))
        if rows:
            suffix='.csv' if report['status']=='pass' else '_partial_FAILED.csv'
            with (a.out/(a.case+suffix)).open('w',newline='') as out:
                writer=csv.writer(out); writer.writerow(['time_s','gtFlow_kg_s','gtTemperature_K']+OUTPUTS); writer.writerows(rows)
        print(json.dumps(report,indent=2),flush=True)
        if fmu:
            try:
                if initialized: fmu.terminate()
                fmu.freeInstance()
            except Exception: pass
        if temp: shutil.rmtree(temp,ignore_errors=True)

if __name__=='__main__': main()
