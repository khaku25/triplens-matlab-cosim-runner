function run_gt_ecms_thermo_closed_loop
%RUN_GT_ECMS_THERMO_CLOSED_LOOP Verify ECMS<->Thermo FMU coupling in one model.
% The test executes the existing ECMS A-logic referenced model and the
% proven Windows CVODE FMI 2.0 Co-Simulation FMU on one Simulink clock.

repo = getenv('GITHUB_WORKSPACE');
if isempty(repo), repo = pwd; end
outDir = fullfile(repo,'verification_outputs');
if ~isfolder(outDir), mkdir(outDir); end

setenv('TRIPLENS_USE_NATIVE_SEED','1');
setenv('TRIPLENS_RETAIN_VALIDATED_NLS_GUESS','1');

f = dir(fullfile(outDir,'*win64*.fmu'));
assert(numel(f)==1,'Expected exactly one proven Windows CVODE FMU.');
fmuPath = fullfile(f.folder,f.name);
addpath(outDir);
addpath(fullfile(repo,'ecms_logic'));
pathCleanup = onCleanup(@() cleanupPath(outDir,fullfile(repo,'ecms_logic'))); %#ok<NASGU>

% Build and independently gate the existing A-program -> ECMS logic core.
build_a_logic_core;
coreName = 'TripLens_ECMS_A_Logic_Core';
corePath = fullfile(repo,'outputs',[coreName '.slx']);
assert(isfile(corePath),'ECMS A-logic core was not generated.');
addpath(fullfile(repo,'outputs'));
load_system(corePath);

mdl = 'TripLens_GT_ECMS_Thermo_ClosedLoop_Verification';
if bdIsLoaded(mdl), bdclose(mdl); end
new_system(mdl);
modelCleanup = onCleanup(@() closeModel(mdl)); %#ok<NASGU>

ecms = [mdl '/ECMS_A_Logic'];
add_block('built-in/Subsystem',ecms,'Position',[390 90 670 500]);
Simulink.SubSystem.deleteContents(ecms);
Simulink.BlockDiagram.copyContentsToSubsystem(coreName,ecms);
set_param(ecms,'TreatAsAtomicUnit','on');

thermo = [mdl '/Thermo_CVODE_FMU'];
add_block('simulink_extras/FMU Import/FMU',thermo,'FMUName',f.name, ...
    'Position',[1030 90 1300 500]);
set_param(thermo,'FMUInputMapping','Flat','FMUOutputMapping','Flat', ...
    'FMUSampleTime','0.001','FMUDebugLogging','on', ...
    'FMUDebugLoggingRedirect','File');

ecmsPorts = get_param(ecms,'PortHandles');
fmuPorts = get_param(thermo,'PortHandles');
assert(numel(ecmsPorts.Inport)==13 && numel(ecmsPorts.Outport)==7, ...
    'Unexpected ECMS A-logic interface.');
assert(numel(fmuPorts.Inport)==2 && numel(fmuPorts.Outport)==7, ...
    'Unexpected Thermo FMU interface.');

% Operator/GT trip episode: the event identity is not supplied to TripLens;
% this is only a deterministic integration stimulus for the verification.
add_block('simulink/Sources/Step',[mdl '/GT_Trip_Request'], ...
    'Time','0.05','Before','0','After','1','SampleTime','0.001', ...
    'Position',[30 85 155 115]);
add_block('simulink/Signal Attributes/Data Type Conversion',[mdl '/GT_Trip_Boolean'], ...
    'OutDataTypeStr','boolean','Position',[185 85 245 115]);
add_line(mdl,'GT_Trip_Request/1','GT_Trip_Boolean/1','autorouting','on');
add_line(mdl,'GT_Trip_Boolean/1','ECMS_A_Logic/1','autorouting','on');

% Fixed external inputs required by the v2 ECMS interface contract.
constantInputs = { ...
    2,'Relay_86GT_Healthy','1','boolean'; ...
    3,'CB_52GT_Reset','0','boolean'; ...
    5,'Bus_A_kV','6.9','double'; ...
    6,'Bus_B_kV','6.9','double'; ...
    7,'Bus_A_Native_Live','1','boolean'; ...
    8,'Bus_B_Native_Live','1','boolean'; ...
    9,'Bus_A_Fault','0','boolean'; ...
    10,'Bus_B_Fault','0','boolean'; ...
    12,'Auto_Tie_Enable','0','boolean'; ...
    13,'Allow_Source_Parallel','0','boolean'};
for k=1:size(constantInputs,1)
    port = constantInputs{k,1}; name = constantInputs{k,2};
    value = constantInputs{k,3}; dtype = constantInputs{k,4};
    y = 115 + 30*k;
    add_block('simulink/Sources/Constant',[mdl '/' name], ...
        'Value',value,'OutDataTypeStr',dtype,'Position',[35 y 175 y+20]);
    add_line(mdl,[name '/1'],['ECMS_A_Logic/' num2str(port)],'autorouting','on');
end

% 52GT physical-position surrogate for the verification only.  A 1 ms
% delay breaks the feedback cycle and represents state feedback after trip.
add_block('simulink/Logic and Bit Operations/Logical Operator',[mdl '/Not_52GT_Trip'], ...
    'Operator','NOT','OutDataTypeStr','boolean','Position',[720 215 770 245]);
add_block('simulink/Discrete/Unit Delay',[mdl '/CB_52GT_Feedback_Delay'], ...
    'InitialCondition','1','SampleTime','0.001','Position',[800 215 870 245]);
add_line(mdl,'ECMS_A_Logic/3','Not_52GT_Trip/1','autorouting','on');
add_line(mdl,'Not_52GT_Trip/1','CB_52GT_Feedback_Delay/1','autorouting','on');
add_line(mdl,'CB_52GT_Feedback_Delay/1','ECMS_A_Logic/4','autorouting','on');

% ECMS breaker trip drives both Thermo boundary commands.
addTripSelector(mdl,'GT_Flow_Selector','606.94','600.8706',540);
addTripSelector(mdl,'GT_Temperature_Selector','893.75','889.28125',610);
add_line(mdl,'ECMS_A_Logic/3','GT_Flow_Selector/2','autorouting','on');
add_line(mdl,'ECMS_A_Logic/3','GT_Temperature_Selector/2','autorouting','on');
% Preserve the exact nominal FMI initialization values.  The FMU must see
% these before any switched command is evaluated, as in the proven input
% response probe.  Subsequent values still come from the ECMS selectors.
add_block('simulink/Discrete/Unit Delay',[mdl '/Initialized_GT_Flow'], ...
    'InitialCondition','606.94','SampleTime','0.001','Position',[950 525 1010 555]);
add_block('simulink/Discrete/Unit Delay',[mdl '/Initialized_GT_Temperature'], ...
    'InitialCondition','893.75','SampleTime','0.001','Position',[950 595 1010 625]);
add_line(mdl,'GT_Flow_Selector/1','Initialized_GT_Flow/1','autorouting','on');
add_line(mdl,'GT_Temperature_Selector/1','Initialized_GT_Temperature/1','autorouting','on');
add_line(mdl,'Initialized_GT_Flow/1','Thermo_CVODE_FMU/1','autorouting','on');
add_line(mdl,'Initialized_GT_Temperature/1','Thermo_CVODE_FMU/2','autorouting','on');

% Thermo ST power is fed back to the ECMS state monitor in MW.
add_block('simulink/Math Operations/Gain',[mdl '/ST_W_to_MW'], ...
    'Gain','1e-6','Position',[1370 410 1440 440]);
add_block('simulink/Discrete/Unit Delay',[mdl '/Initialized_ST_MW_Feedback'], ...
    'InitialCondition','263.1122932842558','SampleTime','0.001', ...
    'Position',[1460 410 1535 440]);
add_line(mdl,'Thermo_CVODE_FMU/7','ST_W_to_MW/1','autorouting','on');
add_line(mdl,'ST_W_to_MW/1','Initialized_ST_MW_Feedback/1','autorouting','on');
add_line(mdl,'Initialized_ST_MW_Feedback/1','ECMS_A_Logic/11','autorouting','on');

ecmsNames = {'relay_86gt_trip_received','relay_86gt_operated', ...
    'cb_52gt_trip_cmd','bus_a_27uv_operate','bus_b_27uv_operate', ...
    'cb_tie_ab_auto_close_permissive','stg_low_state'};
for k=1:numel(ecmsNames)
    addWorkspaceSink(mdl,['log_' ecmsNames{k}],ecmsNames{k}, ...
        [1510 45+50*k 1730 70+50*k]);
    add_line(mdl,['ECMS_A_Logic/' num2str(k)],['log_' ecmsNames{k} '/1'],'autorouting','on');
end
addWorkspaceSink(mdl,'log_gt_trip_cmd','gt_trip_cmd',[270 35 455 60]);
add_line(mdl,'GT_Trip_Boolean/1','log_gt_trip_cmd/1','autorouting','on');
addWorkspaceSink(mdl,'log_cb_52gt_closed_fb','cb_52gt_closed_fb',[900 210 1010 240]);
add_line(mdl,'CB_52GT_Feedback_Delay/1','log_cb_52gt_closed_fb/1','autorouting','on');
addWorkspaceSink(mdl,'log_stg_power_feedback_mw','stg_power_feedback_mw',[1460 410 1685 440]);
add_line(mdl,'Initialized_ST_MW_Feedback/1','log_stg_power_feedback_mw/1','autorouting','on');
addWorkspaceSink(mdl,'log_applied_gt_flow','applied_gt_flow',[860 530 1010 555]);
add_line(mdl,'Initialized_GT_Flow/1','log_applied_gt_flow/1','autorouting','on');
addWorkspaceSink(mdl,'log_applied_gt_temperature','applied_gt_temperature',[820 600 1010 625]);
add_line(mdl,'Initialized_GT_Temperature/1','log_applied_gt_temperature/1','autorouting','on');

thermoNames = {'hpDrumLevel','hpDrumPressure','ipDrumLevel', ...
    'ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower'};
for k=1:numel(thermoNames)
    addWorkspaceSink(mdl,['log_' thermoNames{k}],thermoNames{k}, ...
        [1370 40+45*k 1570 65+45*k]);
    add_line(mdl,['Thermo_CVODE_FMU/' num2str(k)],['log_' thermoNames{k} '/1'],'autorouting','on');
end

set_param(mdl,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'FixedStep','0.001','StopTime','0.2','SaveTime','on','TimeSaveName','tout');
save_system(mdl,fullfile(outDir,[mdl '.slx']));

checkpoint = struct('status','sim_running','same_simulink_model',true, ...
    'actual_fmi2_cosimulation',true,'csv_replay',false, ...
    'command_path','ECMS cb_52gt_trip_cmd -> FMU GT exhaust flow/temperature', ...
    'feedback_path','FMU stElectricalPower -> ECMS stg_power_mw');
writeJson(fullfile(outDir,'closed_loop_verification.json'),checkpoint);

wallStart = tic;
try
    simOut = sim(mdl,'ReturnWorkspaceOutputs','on');
catch ME
    checkpoint.status = 'failed';
    checkpoint.error_identifier = ME.identifier;
    checkpoint.error_message = ME.message;
    writeJson(fullfile(outDir,'closed_loop_verification.json'),checkpoint);
    copyFmuLogs(repo,outDir);
    rethrow(ME);
end
wallSeconds = toc(wallStart);

% ECMS raw tag timeline at the native 1 ms logic rate.
base = simOut.get(ecmsNames{1}); ecmsTime = base.Time(:);
assert(~isempty(ecmsTime) && ecmsTime(end)>=0.199,'ECMS timeline incomplete.');
ecmsData = zeros(numel(ecmsTime),numel(ecmsNames));
for k=1:numel(ecmsNames)
    ts = simOut.get(ecmsNames{k});
    ecmsData(:,k) = samplePrevious(ts,ecmsTime);
end
gtTrip = samplePrevious(simOut.get('gt_trip_cmd'),ecmsTime);
cbClosed = samplePrevious(simOut.get('cb_52gt_closed_fb'),ecmsTime);
stMw = samplePrevious(simOut.get('stg_power_feedback_mw'),ecmsTime);
ecmsTable = array2table([ecmsTime gtTrip ecmsData(:,1:3) cbClosed ecmsData(:,4:7) stMw], ...
    'VariableNames',[{'time_s','gt_trip_cmd'},ecmsNames(1:3), ...
    {'cb_52gt_closed_fb'},ecmsNames(4:7),{'stg_power_feedback_mw'}]);
writetable(ecmsTable,fullfile(outDir,'ecms_tag_raw.csv'));

% Thermo physical RAW uses the same 1 ms rate as ECMS for this integration gate.
firstThermo = simOut.get(thermoNames{1}); thermoTime = firstThermo.Time(:);
assert(~isempty(thermoTime) && thermoTime(end)>=0.199,'Thermo timeline incomplete.');
thermoData = zeros(numel(thermoTime),numel(thermoNames));
for k=1:numel(thermoNames)
    ts = simOut.get(thermoNames{k});
    thermoData(:,k) = samplePrevious(ts,thermoTime);
end
flow = samplePrevious(simOut.get('applied_gt_flow'),thermoTime);
temperature = samplePrevious(simOut.get('applied_gt_temperature'),thermoTime);
thermoTable = array2table([thermoTime flow temperature thermoData], ...
    'VariableNames',[{'time_s','gtExhaustFlowCmd','gtExhaustTemperatureCmd'},thermoNames]);
writetable(thermoTable,fullfile(outDir,'thermo_physics_raw.csv'));

assert(all(isfinite(thermoData(:))),'Non-finite Thermo output.');
assert(all(thermoData(:,[1 3 5])>-1 & thermoData(:,[1 3 5])<5,'all'), ...
    'Invalid drum level.');
assert(all(thermoData(:,[2 4 6])>1e3 & thermoData(:,[2 4 6])<1e8,'all'), ...
    'Invalid drum pressure.');

tTrip = firstTrueTime(ecmsTime,gtTrip);
tRecv = firstTrueTime(ecmsTime,ecmsData(:,1));
tLock = firstTrueTime(ecmsTime,ecmsData(:,2));
tBreaker = firstTrueTime(ecmsTime,ecmsData(:,3));
tOpen = firstFalseAfter(ecmsTime,cbClosed,tBreaker);
tFlow = firstChangedTime(thermoTime,flow,606.94);
assert(tTrip>=0.05 && tRecv>tTrip && tLock>tRecv && tBreaker>tLock, ...
    'ECMS protection sequence ordering failed.');
assert(tOpen>=tBreaker && tFlow>=tBreaker, ...
    'Command did not propagate from ECMS to Thermo in causal order.');

pre = thermoTime>=0.04 & thermoTime<0.05;
post = thermoTime>=0.18 & thermoTime<=0.2;
assert(any(pre) && any(post),'Missing pre/post physical windows.');
preMean = mean(thermoData(pre,:),1);
postMean = mean(thermoData(post,:),1);
delta = postMean-preMean;
assert(any(abs(delta)>1e-8),'Thermo outputs did not physically respond to ECMS trip.');

report = struct();
report.status = 'pass';
report.same_simulink_model = true;
report.actual_fmi2_cosimulation = true;
report.csv_replay = false;
report.full_time_axis_end_s = min(ecmsTime(end),thermoTime(end));
report.logic_step_s = 0.001;
report.fmu_communication_step_s = 0.001;
report.wall_seconds = wallSeconds;
report.command_path = checkpoint.command_path;
report.feedback_path = checkpoint.feedback_path;
report.event_times_s = struct('gt_trip_request',tTrip, ...
    'trip_received',tRecv,'lockout_86gt',tLock, ...
    'trip_52gt_command',tBreaker,'breaker_open_feedback',tOpen, ...
    'thermo_command_change',tFlow);
report.pre_to_post_delta = cell2struct(num2cell(delta),thermoNames,2);
report.outputs = {'ecms_tag_raw.csv','thermo_physics_raw.csv'};
report.guardrail = ['52GT position is a one-sample verification surrogate; ' ...
    'replace with solved electrical breaker physics before plant-grade claims.'];
writeJson(fullfile(outDir,'closed_loop_verification.json'),report);
fprintf('GT_ECMS_THERMO_CLOSED_LOOP_PASS trip=%.3f 52GT=%.3f thermo=%.3f stop=%.3f\n', ...
    tTrip,tBreaker,tFlow,report.full_time_axis_end_s);
end

function addTripSelector(mdl,name,normalValue,tripValue,y)
add_block('simulink/Sources/Constant',[mdl '/' name '_Normal'], ...
    'Value',normalValue,'Position',[720 y+35 790 y+55]);
add_block('simulink/Sources/Constant',[mdl '/' name '_Trip'], ...
    'Value',tripValue,'Position',[720 y-35 790 y-15]);
add_block('simulink/Signal Routing/Switch',[mdl '/' name], ...
    'Criteria','u2 ~= 0','Threshold','0.5','Position',[850 y-20 925 y+45]);
add_line(mdl,[name '_Trip/1'],[name '/1'],'autorouting','on');
add_line(mdl,[name '_Normal/1'],[name '/3'],'autorouting','on');
end

function addWorkspaceSink(mdl,blockName,varName,position)
add_block('simulink/Sinks/To Workspace',[mdl '/' blockName], ...
    'VariableName',varName,'SaveFormat','Timeseries','Position',position);
end

function y=samplePrevious(ts,t)
y=interp1(double(ts.Time(:)),double(ts.Data(:)),double(t(:)),'previous','extrap');
end

function t=firstTrueTime(time,data)
idx=find(logical(data),1,'first'); assert(~isempty(idx),'Expected true transition.'); t=time(idx);
end

function t=firstFalseAfter(time,data,after)
idx=find(time>=after & ~logical(data),1,'first'); assert(~isempty(idx),'Expected false transition.'); t=time(idx);
end

function t=firstChangedTime(time,data,initial)
idx=find(abs(data-initial)>1e-8,1,'first'); assert(~isempty(idx),'Expected changed input.'); t=time(idx);
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8'); assert(fid>=0,'Could not write report.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true));
end

function closeModel(mdl)
if bdIsLoaded(mdl), bdclose(mdl); end
end

function cleanupPath(varargin)
for k=1:nargin
    if contains(path,varargin{k}), rmpath(varargin{k}); end
end
end

function copyFmuLogs(repo,outDir)
hits=dir(fullfile(repo,'slprj','**','*.txt'));
logDir=fullfile(outDir,'fmu_debug_logs');
if ~isfolder(logDir), mkdir(logDir); end
for k=1:numel(hits)
    copyfile(fullfile(hits(k).folder,hits(k).name), ...
        fullfile(logDir,sprintf('%03d_%s',k,hits(k).name)));
end
end
