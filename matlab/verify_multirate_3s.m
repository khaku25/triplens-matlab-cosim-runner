function verify_multirate_3s()
%VERIFY_MULTIRATE_3S Verify a 100 ms physical stream on a 1 ms ECMS grid.
%
% This is a timing/causality verification, not a replacement physical model.
% A slowly declining LP drum level is sampled at 0.1 s, held on the 0.001 s
% protection grid, qualified by the configured LL persistence, and then fed
% into the generated ECMS A-logic Simulink model.  No trip output is injected.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

logicSettings=readtable(fullfile(repoRoot,'ecms_logic','a_logic_settings_v1.csv'), ...
    'TextType','string','VariableNamingRule','preserve');
alarmSettings=readtable(fullfile(repoRoot,'ecms_logic','drum_level_first_order_settings.csv'), ...
    'TextType','string','VariableNamingRule','preserve');

logicStep=settingValue(logicSettings,'LOGIC_SAMPLE_TIME_MS')/1000;
physicalStep=0.1;
stopTime=3.0;
assert(abs(logicStep-0.001)<eps,'TripLens:LogicStep','Expected a 1 ms logic step.');

lpRow=alarmSettings(alarmSettings.signal=="lp_drum_level" & ...
    alarmSettings.alarm_type=="LL",:);
assert(height(lpRow)==1,'TripLens:LPSetting','Expected one LP drum LL setting.');
llThreshold=double(lpRow.threshold_m(1));
llDelay=double(lpRow.delay_s(1));

% Physical source: normal through 0.5 s, then a slow 0.4 m/s decline.
% Only the 31 source samples below exist; the 1 ms layer must not invent
% intermediate physical measurements.
tPhysical=(0:physicalStep:stopTime)';
lpPhysical=1.70-0.4*max(tPhysical-0.5,0);

% Explicit zero-order hold onto the protection clock.
tLogic=(0:logicStep:stopTime)';
lpHeld=interp1(tPhysical,lpPhysical,tLogic,'previous');
rawLL=lpHeld<=llThreshold;
lpLL=qualifyContinuous(rawLL,tLogic,llDelay);

firstThresholdTime=firstTrueVector(tLogic,rawLL);
firstAlarmTime=firstTrueVector(tLogic,lpLL);
assert(abs(firstThresholdTime-0.9)<=logicStep+1e-12, ...
    'TripLens:ThresholdTime','Unexpected sampled LL threshold time.');
assert(abs(firstAlarmTime-(firstThresholdTime+llDelay))<=logicStep+1e-12, ...
    'TripLens:AlarmDelay','LL persistence timing is not 0.5 s on the 1 ms grid.');

modelName='TripLens_ECMS_A_Logic_Core';
modelPath=fullfile(outDir,[modelName '.slx']);
assert(isfile(modelPath),'TripLens:MissingCore','Run build_a_logic_core first.');
if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath);
cleanup=onCleanup(@() close_system(modelName,0)); %#ok<NASGU>

inputNames={'gt_trip_cmd','st_trip_cmd', ...
    'hp_drum_level_hh','hp_drum_level_ll','ip_drum_level_hh','ip_drum_level_ll', ...
    'lp_drum_level_hh','lp_drum_level_ll','relay_86gt_healthy', ...
    'cb_52gt_reset_cmd','cb_52gt_closed_fb','cb_52st_reset_cmd','cb_52st_closed_fb', ...
    'bus_a_voltage_kv','bus_b_voltage_kv','bus_a_native_live','bus_b_native_live', ...
    'bus_a_fault_active','bus_b_fault_active','stg_power_mw', ...
    'auto_bus_tie_enable','allow_source_parallel'};
N=numel(tLogic);
inputs=cell(1,22);
for k=1:22, inputs{k}=false(N,1); end
inputs{8}=lpLL;
inputs{9}=true(N,1);       % 86GT healthy feedback
inputs{11}=true(N,1);      % 52GT initially closed
inputs{13}=true(N,1);      % 52ST initially closed
inputs{14}=6.9*ones(N,1);  % bus A normal
inputs{15}=6.9*ones(N,1);  % bus B normal
inputs{16}=true(N,1);
inputs{17}=true(N,1);
inputs{20}=277*ones(N,1);  % ST initially loaded

ds=Simulink.SimulationData.Dataset;
for k=1:numel(inputNames)
    tsx=timeseries(inputs{k},tLogic);
    tsx.Name=inputNames{k};
    tsx=setinterpmethod(tsx,'zoh');
    ds=ds.addElement(tsx,inputNames{k});
end
simIn=Simulink.SimulationInput(modelName);
simIn=simIn.setExternalInput(ds);
simIn=simIn.setModelParameter('StopTime','3','FixedStep','0.001');
simOut=sim(simIn);
yout=simOut.yout;

actual=struct();
actual.lp_ll_alarm_s=firstAlarmTime;
actual.gt_trip_request_s=firstTrueDataset(yout,1);
actual.st_trip_request_s=firstTrueDataset(yout,2);
actual.relay_86gt_received_s=firstTrueDataset(yout,3);
actual.relay_86gt_operated_s=firstTrueDataset(yout,4);
actual.cb_52gt_trip_s=firstTrueDataset(yout,5);
actual.cb_52st_trip_s=firstTrueDataset(yout,6);

expected=struct();
expected.lp_ll_alarm_s=firstThresholdTime+llDelay;
expected.gt_trip_request_s=expected.lp_ll_alarm_s;
expected.st_trip_request_s=expected.lp_ll_alarm_s;
expected.relay_86gt_received_s=expected.lp_ll_alarm_s+ ...
    settingValue(logicSettings,'TRIP_RECEIVE_DELAY_MS')/1000;
expected.relay_86gt_operated_s=expected.lp_ll_alarm_s+ ...
    (settingValue(logicSettings,'TRIP_RECEIVE_DELAY_MS')+ ...
     settingValue(logicSettings,'LOCKOUT_OPERATE_DELAY_MS'))/1000;
expected.cb_52gt_trip_s=expected.lp_ll_alarm_s+ ...
    settingValue(logicSettings,'GT_BREAKER_OPEN_DELAY_MS')/1000;
expected.cb_52st_trip_s=expected.lp_ll_alarm_s+ ...
    settingValue(logicSettings,'ST_BREAKER_OPEN_DELAY_MS')/1000;

names=fieldnames(expected);
checks=struct();
for k=1:numel(names)
    name=names{k};
    checks.(name)=abs(actual.(name)-expected.(name))<=logicStep+1e-12;
end
pass=all(structfun(@logical,checks));
assert(pass,'TripLens:MultirateTiming','One or more 3 s multirate checks failed.');

timeline=table( ...
    [firstThresholdTime;actual.lp_ll_alarm_s;actual.gt_trip_request_s; ...
     actual.st_trip_request_s;actual.relay_86gt_received_s; ...
     actual.relay_86gt_operated_s;actual.cb_52gt_trip_s;actual.cb_52st_trip_s], ...
    ["LP_DRUM_LL_THRESHOLD_SAMPLED";"LP_DRUM_LL_ACTIVE";"GT_TRIP_REQUEST"; ...
     "ST_TRIP_REQUEST";"86GT_TRIP_RECEIVED";"86GT_OPERATED"; ...
     "52GT_TRIP_CMD";"52ST_TRIP_CMD"], ...
    'VariableNames',{'time_s','event'});
timeline=sortrows(timeline,'time_s');
writetable(timeline,fullfile(outDir,'multirate_3s_timeline.csv'));

physical=table(tPhysical,lpPhysical,'VariableNames',{'time_s','lp_drum_level_m'});
writetable(physical,fullfile(outDir,'multirate_3s_physical_samples.csv'));

report=struct();
report.test='TripLens 3 s multirate protection timing';
report.status='PASS';
report.stop_time_s=stopTime;
report.physical_sample_s=physicalStep;
report.physical_sample_count=numel(tPhysical);
report.logic_sample_s=logicStep;
report.logic_scan_count=numel(tLogic);
report.rate_adapter='ZERO_ORDER_HOLD';
report.lp_ll_threshold_m=llThreshold;
report.lp_ll_persistence_s=llDelay;
report.first_sampled_threshold_crossing_s=firstThresholdTime;
report.expected=expected;
report.actual=actual;
report.checks=checks;
report.scope=['Timing harness only: verifies 100 ms physical samples, 1 ms alarm/protection ' ...
    'execution, and the generated ECMS Simulink core. It does not claim a 1 ms Thermo FMU solve.'];
fid=fopen(fullfile(outDir,'multirate_3s_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);

fprintf('TRIPLENS 3S MULTIRATE PASS\n');
fprintf('PHYSICAL=%.3f s (%d samples) LOGIC=%.3f s (%d scans)\n', ...
    physicalStep,numel(tPhysical),logicStep,numel(tLogic));
fprintf('LL_SAMPLED=%.3f LL_ACTIVE=%.3f 86GT=%.3f 52GT=%.3f 52ST=%.3f\n', ...
    firstThresholdTime,actual.lp_ll_alarm_s,actual.relay_86gt_operated_s, ...
    actual.cb_52gt_trip_s,actual.cb_52st_trip_s);
end

function y=qualifyContinuous(condition,t,delay)
y=false(size(condition)); pickup=-1;
for k=1:numel(t)
    if condition(k)
        if pickup<0, pickup=t(k); end
        y(k)=(t(k)-pickup)>=delay-1e-12;
    else
        pickup=-1;
    end
end
end

function t=firstTrueVector(time,value)
idx=find(value,1);
if isempty(idx), t=NaN; else, t=double(time(idx)); end
end

function t=firstTrueDataset(ds,index)
v=ds.getElement(index).Values;
idx=find(logical(v.Data),1);
if isempty(idx), t=NaN; else, t=double(v.Time(idx)); end
end

function value=settingValue(tbl,name)
idx=find(tbl.setting_id==string(name),1);
assert(~isempty(idx),'TripLens:MissingSetting','Missing %s.',name);
value=str2double(string(tbl.value(idx)));
assert(isfinite(value),'TripLens:BadSetting','Bad %s.',name);
end
