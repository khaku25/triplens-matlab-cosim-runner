function export_fwp_hp_ecms_raw()
%EXPORT_FWP_HP_ECMS_RAW Export the full 1 ms ECMS signal record.
% This is ECMS-side R&D RAW. It does not contain a scenario-answer column.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
logicDir=fullfile(repoRoot,'ecms_pump_logic');
outDir=fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

cfg=readcell(fullfile(logicDir,'fwp_hp_settings_v1.csv'),'Delimiter',',');
sampleMs=settingValue(cfg,'LOGIC_SAMPLE_TIME_MS');
Ts=sampleMs/1000;
assert(abs(Ts-0.001)<1e-12,'TripLens:RawSampleTime','Expected 1 ms ECMS logic sample time.');

modelName='TripLens_ECMS_FWP_HP_Operation_Core';
modelPath=fullfile(outDir,[modelName '.slx']);
if ~isfile(modelPath)
    error('TripLens:MissingModel','Build %s before RAW export.',modelName);
end
if ~bdIsLoaded(modelName), load_system(modelPath); end

% Exact deterministic R&D stimulus used by the validated FWP-HP operation core.
t=(0:Ts:30)'; N=numel(t);
runRequest=(t>=0.5 & t<6) | (t>=12 & t<20) | (t>=27);
tripRequest=t>=18 & t<18.2;
resetRequest=(t>=19 & t<19.05) | (t>=25 & t<25.05);
recloseRequest=t>=26 & t<26.05;
remoteMode=true(N,1);
feederCbReady=true(N,1);
motorReady=true(N,1);
processStartPermissive=true(N,1);
busAVoltageKv=6.9*ones(N,1);
electricalTripActive=false(N,1);

inputNames={'fwp_hp_run_request','fwp_hp_trip_request','fwp_hp_reset_request', ...
    'feeder_cb_reclose_cmd','remote_mode','feeder_cb_ready','motor_ready', ...
    'process_start_permissive','bus_a_voltage_kv','electrical_trip_active'};
inputs={runRequest,tripRequest,resetRequest,recloseRequest,remoteMode, ...
    feederCbReady,motorReady,processStartPermissive,busAVoltageKv,electricalTripActive};

ds=Simulink.SimulationData.Dataset;
for k=1:numel(inputNames)
    tsx=timeseries(inputs{k},t);
    tsx.Name=inputNames{k};
    tsx=setinterpmethod(tsx,'zoh');
    ds=ds.addElement(tsx,inputNames{k});
end
simIn=Simulink.SimulationInput(modelName);
simIn=simIn.setExternalInput(ds);
simIn=simIn.setModelParameter('StopTime','30');
simOut=sim(simIn);
yout=simOut.yout;

% Stable root Outport contract from build_fwp_hp_operation.m.
runEnable=dataOnGrid(signal(yout,1),t);
cbTrip=dataOnGrid(signal(yout,2),t);
cbClosed=dataOnGrid(signal(yout,3),t);
tripLatch=dataOnGrid(signal(yout,4),t);
ready=dataOnGrid(signal(yout,5),t);
starting=dataOnGrid(signal(yout,6),t);
running=dataOnGrid(signal(yout,7),t);
stopping=dataOnGrid(signal(yout,8),t);
tripped=dataOnGrid(signal(yout,9),t);
runFb=dataOnGrid(signal(yout,10),t);
speedRpm=dataOnGrid(signal(yout,11),t);
speedProven=dataOnGrid(signal(yout,12),t);
stateCode=dataOnGrid(signal(yout,13),t);
thermoSpeedInputRpm=dataOnGrid(signal(yout,14),t);

raw=table(t, ...
    double(runRequest),double(tripRequest),double(resetRequest),double(recloseRequest), ...
    double(remoteMode),double(feederCbReady),double(motorReady),double(processStartPermissive), ...
    busAVoltageKv,double(electricalTripActive), ...
    runEnable,cbTrip,cbClosed,tripLatch,ready,starting,running,stopping,tripped, ...
    runFb,speedRpm,speedProven,stateCode,thermoSpeedInputRpm, ...
    'VariableNames',{ ...
    'time_s','FWP_HP_RUN_REQUEST','FWP_HP_TRIP_REQUEST','FWP_HP_RESET_REQUEST', ...
    'VCB_A01_RECLOSE_CMD','REMOTE_MODE','VCB_A01_READY','FWP_HP_MOTOR_READY', ...
    'FWP_HP_PROCESS_START_PERMISSIVE','BUS_A_VOLTAGE_KV','ELECTRICAL_TRIP_ACTIVE', ...
    'FWP_HP_RUN_ENABLE_CMD','VCB_A01_TRIP_CMD','VCB_A01_CLOSED','FWP_HP_TRIP_LATCHED', ...
    'FWP_HP_READY','FWP_HP_STARTING','FWP_HP_RUNNING','FWP_HP_STOPPING','FWP_HP_TRIPPED', ...
    'FWP_HP_RUN_FB','FWP_HP_SPEED_RPM','FWP_HP_SPEED_PROVEN','FWP_HP_STATE_CODE', ...
    'THERMO_FWP_HP_SPEED_INPUT_RPM'});

rawPath=fullfile(outDir,'ecms_fwp_hp_raw_1ms.csv');
writetable(raw,rawPath,'Encoding','UTF-8');
tripWindow=raw(raw.time_s>=17.95 & raw.time_s<=19.20,:);
writetable(tripWindow,fullfile(outDir,'ecms_fwp_hp_raw_trip_window_1ms.csv'),'Encoding','UTF-8');

% RAW integrity and Trip-semantics audit.
assert(height(raw)==30001,'TripLens:RawRowCount','Expected 30001 rows, got %d.',height(raw));
dt=diff(raw.time_s);
assert(max(abs(dt-Ts))<1e-10,'TripLens:RawCadence','RAW cadence is not exactly 1 ms.');
idx18000=find(abs(raw.time_s-18.000)<1e-10,1);
idx18079=find(abs(raw.time_s-18.079)<1e-10,1);
idx18080=find(abs(raw.time_s-18.080)<1e-10,1);
idx18100=find(abs(raw.time_s-18.100)<1e-10,1);
assert(~isempty(idx18000)&&~isempty(idx18079)&&~isempty(idx18080)&&~isempty(idx18100), ...
    'TripLens:RawTimes','Required Trip audit timestamps are absent.');
assert(raw.FWP_HP_TRIP_REQUEST(idx18000)==1,'TripLens:TripStimulus','Trip request missing at 18.000 s.');
assert(raw.FWP_HP_TRIP_LATCHED(idx18000)==1,'TripLens:TripLatch','Trip latch missing at 18.000 s.');
assert(raw.VCB_A01_TRIP_CMD(idx18000)==1,'TripLens:TripCmd','VCB trip command missing at 18.000 s.');
assert(raw.VCB_A01_CLOSED(idx18079)==1,'TripLens:BreakerEarly','VCB opened before configured delay.');
assert(raw.VCB_A01_CLOSED(idx18080)==0,'TripLens:BreakerOpen','VCB-A01 did not open at 18.080 s.');
assert(raw.FWP_HP_SPEED_RPM(idx18080)>0,'TripLens:InstantZero','RPM was forced to zero at breaker opening.');
assert(raw.FWP_HP_SPEED_RPM(idx18100)<raw.FWP_HP_SPEED_RPM(idx18080), ...
    'TripLens:NoCoastdown','RPM did not coast down after breaker opening.');
idx6000=find(abs(raw.time_s-6.000)<1e-10,1);
idx6100=find(abs(raw.time_s-6.100)<1e-10,1);
assert(raw.VCB_A01_CLOSED(idx6000)==1 && raw.VCB_A01_CLOSED(idx6100)==1, ...
    'TripLens:StopOpenedBreaker','Normal STOP opened VCB-A01.');

firstOpen=find(raw.time_s>=18 & raw.VCB_A01_CLOSED==0,1,'first');
report=struct();
report.status='pass';
report.raw_file='outputs/ecms_fwp_hp_raw_1ms.csv';
report.rows=height(raw);
report.start_time_s=raw.time_s(1);
report.end_time_s=raw.time_s(end);
report.sample_time_s=Ts;
report.trip_request_time_s=18.000;
report.breaker_open_time_s=raw.time_s(firstOpen);
report.trip_latch_at_request=logical(raw.FWP_HP_TRIP_LATCHED(idx18000));
report.breaker_closed_at_18_079=logical(raw.VCB_A01_CLOSED(idx18079));
report.breaker_closed_at_18_080=logical(raw.VCB_A01_CLOSED(idx18080));
report.speed_rpm_at_trip_request=raw.FWP_HP_SPEED_RPM(idx18000);
report.speed_rpm_at_breaker_open=raw.FWP_HP_SPEED_RPM(firstOpen);
report.speed_rpm_at_18_100=raw.FWP_HP_SPEED_RPM(idx18100);
report.normal_stop_keeps_breaker_closed=true;
report.scenario_answer_column_present=false;
report.scope='ECMS R&D RAW only; ThermoSysPro physical E2E is a separate validation gate.';
report.guardrail='Motor time constants and breaker delay are virtual-model settings, not approved plant values.';
fid=fopen(fullfile(outDir,'ecms_fwp_hp_raw_1ms_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:RawReport','Could not create RAW report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);

fprintf(['TRIPLENS ECMS FWP-HP RAW EXPORTED\nROWS=%d\nDT=%.6f\n' ...
    'TRIP=18.000\nVCB_OPEN=%.3f\nRPM_TRIP=%.6f\nRPM_OPEN=%.6f\n'], ...
    height(raw),Ts,report.breaker_open_time_s,report.speed_rpm_at_trip_request, ...
    report.speed_rpm_at_breaker_open);
close_system(modelName,0);
end

function value=settingValue(raw,name)
settingIds=strtrim(string(raw(2:end,1)));
settingValues=strtrim(string(raw(2:end,3)));
idx=find(settingIds==string(name),1);
if isempty(idx), error('TripLens:MissingSetting','Missing setting %s',name); end
value=str2double(settingValues(idx));
if isnan(value), error('TripLens:BadSetting','Non-numeric setting %s',name); end
end

function ts=signal(yout,index)
element=yout.getElement(index);
if isa(element,'Simulink.SimulationData.Signal')
    ts=element.Values;
elseif isa(element,'timeseries')
    ts=element;
else
    error('TripLens:UnexpectedOutputType','Unexpected Outport %d type: %s',index,class(element));
end
end

function y=dataOnGrid(ts,t)
% Simulink can emit multiple event states at the same timestamp. ECMS RAW
% must represent the final settled discrete state for that 1 ms timestamp.
tt=double(ts.Time(:)); dd=double(ts.Data(:));
[ut,lastIdx]=unique(tt,'last');
ud=dd(lastIdx);
y=interp1(ut,ud,double(t),'previous','extrap');
y=double(y(:));
end
