function report = run_matlab_gt_trip_trend()
%RUN_MATLAB_GT_TRIP_TREND Optimized ThermoSysPro 3.1 GT Trip trend run.
%
% The only commanded value is the ECMS GT Trip request. Breaker feedback,
% Trip latch, valve positions, flows, drum levels and pressures are read
% from the native OpenModelica model over OPC UA; none is overwritten.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = fileparts(fileparts(mfilename('fullpath'))); end
outDir = fullfile(repoRoot,'outputs','matlab-native-opcua');
if ~isfolder(outDir), mkdir(outDir); end

host = envOrDefault('TRIPLENS_OPCUA_HOST','127.0.0.1');
port = str2double(envOrDefault('TRIPLENS_OPCUA_PORT','4841'));
stopTime = str2double(envOrDefault('TRIPLENS_OPCUA_STOP_TIME','130'));
stepSize = str2double(envOrDefault('TRIPLENS_OPCUA_STEP_SIZE','0.1'));
commandTime = str2double(envOrDefault('TRIPLENS_OPCUA_COMMAND_TIME','10'));
assert(isfinite(port) && port > 0 && port < 65536,'TripLens:BadPort');
assert(isfinite(stopTime) && stopTime > 0,'TripLens:BadStopTime');
assert(isfinite(stepSize) && stepSize > 0,'TripLens:BadStepSize');
assert(commandTime >= 5 && commandTime < stopTime,'TripLens:BadCommandTime');
assert(abs(stopTime/stepSize-round(stopTime/stepSize)) < 1e-9, ...
    'TripLens:BadTrendGrid','Stop time must be a multiple of trend sample time.');
assert(~isempty(ver('simulink')),'TripLens:SimulinkUnavailable');

[ecmsModelPath,ecmsModelName,ecmsBlockCount] = inspectSstFreeEcms();
[schedule,ecmsProof] = buildAndRunGtTripButton(repoRoot,stopTime,commandTime);
writetable(schedule,fullfile(outDir,'ECMS-GT-Trip-command-schedule.csv'));

launchFreshNativeServer(repoRoot);
capture = runPythonOpcuaAdapter(repoRoot,outDir,host,port, ...
    stopTime,stepSize,commandTime);
writetable(capture,fullfile(outDir,'ECMS-GT-Trip-trend.csv'));
save(fullfile(outDir,'MATLAB-ECMS-GT-Trip-trend.mat'), ...
    'capture','schedule','ecmsProof','-v7.3');
plotTrend(capture,commandTime,fullfile(outDir,'GT-Trip-trend.png'));

proofPath = fullfile(outDir,'gt-trip-trend-proof.json');
report = jsondecode(fileread(proofPath));
report.matlab_release = version('-release');
report.ecms_model = ecmsModelName;
report.ecms_model_file = [ecmsModelName '.slx'];
report.ecms_model_source = 'VALIDATED_TRIP_BREAKER_SEMANTICS_V2_ARTIFACT';
report.ecms_block_count = ecmsBlockCount;
report.ecms_command_regression = ecmsProof;
report.opcua_endpoint = sprintf('opc.tcp://%s:%d',host,port);
report.client_implementation = 'PYTHON_OPCUA_ADAPTER_CONTROLLED_BY_MATLAB_R2026A';
report.transport_scope = 'REAL_OPC_UA_TCP_INSIDE_GITHUB_HOSTED_RUNNER';
report.thermosyspro_version = '3.1';
report.modelica_standard_library = '3.2.3';
report.trend_sample_time_s = stepSize;
report.pre_trip_window_s = commandTime;
report.post_trip_window_s = stopTime-commandTime;
report.alarm_evaluation_enabled = false;
report.output_forcing = false;
report.actual_plant_logic_used = false;
report.not_proven = {'physical plant ECMS button','plant DCS connection', ...
    'site firewall/certificate/authentication','plant parameter fidelity'};
writeJson(proofPath,report);

if ~strcmp(report.status,'PASS')
    error('TripLens:GTTripTrendValidation','OPC UA trend validation failed.');
end
fprintf(['MATLAB_ECMS_GT_TRIP_TREND_PASS frames=%d sample=%.3fs ' ...
    'pre=%.1fs post=%.1fs changed_physical=%d\n'], ...
    report.frames_received,stepSize,commandTime,stopTime-commandTime, ...
    report.changed_physical_fields);
fprintf('ECMS_MODEL=%s SST=0 OPCUA_CLIENT=%s\n', ...
    ecmsModelPath,report.client_implementation);
end

function [path,name,count] = inspectSstFreeEcms()
path = char(string(getenv('TRIPLENS_ECMS_MODEL_PATH')));
assert(~isempty(path) && isfile(path),'TripLens:ECMSModelMissing', ...
    'TRIPLENS_ECMS_MODEL_PATH does not identify the validated ECMS model.');
[modelDir,~] = fileparts(path);
addpath(modelDir,'-begin'); cleanupPath = onCleanup(@() rmpath(modelDir)); %#ok<NASGU>
handle = load_system(path);
name = get_param(handle,'Name');
cleanupModel = onCleanup(@() closeIfLoaded(name)); %#ok<NASGU>
blocks = find_system(name,'LookUnderMasks','all','FollowLinks','on','Type','Block');
sst = strings(0,1);
for k = 1:numel(blocks)
    if ~isempty(regexp(upper(blocks{k}),'(^|[/_.-])SST($|[/_.-])','once'))
        sst(end+1,1) = string(blocks{k}); %#ok<AGROW>
    end
end
assert(isempty(sst),'TripLens:SSTPresent','SST blocks found: %s',strjoin(sst,', '));
required = {'Protection_Control','Thermo_Interface','GT_Trip_CMD'};
for k = 1:numel(required)
    assert(getSimulinkBlockHandle([name '/' required{k}]) ~= -1, ...
        'TripLens:ECMSContractMissing','Missing %s/%s',name,required{k});
end
count = numel(blocks);
end

function [schedule,proof] = buildAndRunGtTripButton(repoRoot,stopTime,commandTime)
addpath(fullfile(repoRoot,'ecms_logic'),'-begin');
cleanupPath = onCleanup(@() rmpath(fullfile(repoRoot,'ecms_logic'))); %#ok<NASGU>
build_trip_breaker_semantics_core;
modelName = 'TripLens_ECMS_Trip_Breaker_Semantics_Core';
modelPath = fullfile(repoRoot,'outputs',[modelName '.slx']);
assert(isfile(modelPath),'TripLens:ECMSCoreMissing');
load_system(modelPath); cleanupModel = onCleanup(@() closeIfLoaded(modelName)); %#ok<NASGU>

% The 1 ms ECMS logic is evaluated only through its causal transition. The
% expensive physical trend is then sampled at 100 ms over the full window.
Ts = 0.001;
ecmsStopTime = min(stopTime,commandTime+0.05);
t = (0:Ts:ecmsStopTime)';
inputs = {'gt_trip_request','st_trip_request','fwp_hp_trip_request', ...
    'fwp_ip_trip_request','fwp_lp_trip_request','cb_in_a_trip_request', ...
    'cb_in_b_trip_request','cb_tie_ab_trip_request','cb_52gt_direct_trip', ...
    'cb_52st_direct_trip','gt_derating_active','gt_in_service'};
ds = Simulink.SimulationData.Dataset;
for k = 1:numel(inputs)
    value = false(size(t));
    if strcmp(inputs{k},'gt_trip_request')
        value(t >= commandTime) = true;
    elseif strcmp(inputs{k},'gt_in_service')
        value(:) = true;
    end
    series = timeseries(value,t); series.Name = inputs{k};
    series = setinterpmethod(series,'zoh');
    ds = ds.addElement(series,inputs{k});
end
simIn = Simulink.SimulationInput(modelName);
simIn = simIn.setExternalInput(ds).setModelParameter('StopTime',num2str(ecmsStopTime));
simOut = sim(simIn);
yout = simOut.yout;
gtClosed = yout.getElement(1).Values;
stClosed = yout.getElement(2).Values;
tripFrom52GT = yout.getElement(9).Values;
time = double(gtClosed.Time(:));
gtClosedData = double(gtClosed.Data(:));
stClosedData = interp1(double(stClosed.Time(:)),double(stClosed.Data(:)), ...
    time,'previous','extrap');
observedTrip = interp1(double(tripFrom52GT.Time(:)), ...
    double(tripFrom52GT.Data(:)),time,'previous','extrap');
button = double(time >= commandTime);
command = button;
schedule = table(time,button,command,gtClosedData,stClosedData,observedTrip, ...
    'VariableNames',{'time_s','gt_trip_button','gt_trip_command', ...
    'ecms_cb_52gt_closed','ecms_cb_52st_closed','gt_trip_from_52gt_open'});
if schedule.time_s(end) < stopTime
    schedule(end+1,:) = {stopTime,1,1,schedule.ecms_cb_52gt_closed(end), ...
        schedule.ecms_cb_52st_closed(end),schedule.gt_trip_from_52gt_open(end)};
end

buttonEdge = find(schedule.gt_trip_button >= 0.5,1,'first');
breakerEdge = find(schedule.ecms_cb_52gt_closed < 0.5,1,'first');
assert(~isempty(buttonEdge) && ~isempty(breakerEdge), ...
    'TripLens:MissingDirectGTTripEdge');
assert(schedule.time_s(buttonEdge) <= schedule.time_s(breakerEdge), ...
    'TripLens:52GTOpenPrecedesGTTripButton');
assert(all(schedule.ecms_cb_52gt_closed(schedule.time_s < commandTime) > 0.5), ...
    'TripLens:Premature52GTOpen');
assert(all(schedule.gt_trip_from_52gt_open(schedule.time_s < commandTime) < 0.5), ...
    'TripLens:PrematureDerivedTrip');
proof = struct('simulation_pass',true,'logic_sample_time_s',Ts, ...
    'simulated_logic_duration_s',ecmsStopTime, ...
    'button_press_time_s',schedule.time_s(buttonEdge), ...
    'breaker_open_feedback_time_s',schedule.time_s(breakerEdge), ...
    'root_cause','ECMS_GT_TRIP_BUTTON', ...
    'command_input','gt_trip_request', ...
    'direct_52gt_open_input_used',false, ...
    'derived_52gt_open_trip_used_as_command',false, ...
    'output_forcing',false);
end

function launchFreshNativeServer(repoRoot)
launcher = fullfile(repoRoot,'matlab','start_native_opcua_server.ps1');
assert(isfile(launcher),'TripLens:NativeServerLauncherMissing', ...
    'Native OPC UA server launcher missing: %s',launcher);
command = sprintf(['powershell -NoProfile -ExecutionPolicy Bypass ' ...
    '-File "%s"'],launcher);
[status,output] = system(command);
fprintf('%s',output);
assert(status == 0,'TripLens:NativeServerLaunchFailed', ...
    'Native OPC UA server launch failed with exit code %d.',status);
end

function capture = runPythonOpcuaAdapter(repoRoot,outDir,host,port, ...
        stopTime,stepSize,commandTime)
adapter = fullfile(repoRoot,'matlab','gt_trip_trend_opcua_client.py');
assert(isfile(adapter),'TripLens:OPCUAAdapterMissing', ...
    'GT Trip trend OPC UA adapter missing: %s',adapter);
endpoint = sprintf('opc.tcp://%s:%d',host,port);
command = sprintf(['python "%s" --endpoint "%s" --stop-time %.17g ' ...
    '--step-size %.17g --command-time %.17g --output-dir "%s"'], ...
    adapter,endpoint,stopTime,stepSize,commandTime,outDir);
[status,output] = system(command);
fprintf('%s',output);
assert(status == 0,'TripLens:OPCUAAdapterFailed', ...
    'Live OPC UA trend adapter failed with exit code %d.',status);
capturePath = fullfile(outDir,'ECMS-GT-Trip-trend.csv');
assert(isfile(capturePath),'TripLens:OPCUACaptureMissing');
capture = readtable(capturePath,'VariableNamingRule','preserve');
assert(height(capture) > 0,'TripLens:EmptyOPCUACapture');
assert(all(isfinite(capture.time_s)),'TripLens:BadOPCUATime');
fprintf('MATLAB_RECEIVED_GT_TRIP_TREND frames=%d fields=%d\n', ...
    height(capture),width(capture));
end

function plotTrend(T,commandTime,path)
figureHandle = figure('Visible','off','Color','white','Position',[100 100 1400 900]);
cleanupFigure = onCleanup(@() close(figureHandle)); %#ok<NASGU>
layout = tiledlayout(4,1,'TileSpacing','compact','Padding','compact');
title(layout,'ThermoSysPro 3.1 - ECMS GT TRIP button trend');

nexttile;
stairs(T.time_s,T.ecms_gt_trip_button,'LineWidth',1.2); hold on;
stairs(T.time_s,T.gt_trip_latch,'LineWidth',1.2);
stairs(T.time_s,1-T.breaker_52gt_closed,'LineWidth',1.2);
xline(commandTime,'--k','GT TRIP'); grid on; ylim([-0.05 1.15]);
ylabel('logic'); legend('button','trip latch','52GT open','Location','eastoutside');

nexttile;
plot(T.time_s,T.hp_admission_position_pu,'LineWidth',1.2); hold on;
plot(T.time_s,T.hp_bypass_position_pu,'LineWidth',1.2);
plot(T.time_s,T.lp_bypass_position_pu,'LineWidth',1.2);
xline(commandTime,'--k'); grid on; ylabel('position (pu)');
legend('HP admission','HP bypass','LP bypass','Location','eastoutside');

nexttile;
plot(T.time_s,T.hp_drum_level_m,'LineWidth',1.2); hold on;
plot(T.time_s,T.ip_drum_level_m,'LineWidth',1.2);
plot(T.time_s,T.lp_drum_level_m,'LineWidth',1.2);
xline(commandTime,'--k'); grid on; ylabel('drum level (m)');
legend('HP drum','IP drum','LP drum','Location','eastoutside');

nexttile;
plot(T.time_s,T.hp_drum_pressure_pa/1e6,'LineWidth',1.2); hold on;
plot(T.time_s,T.ip_drum_pressure_pa/1e6,'LineWidth',1.2);
plot(T.time_s,T.lp_drum_pressure_pa/1e6,'LineWidth',1.2);
xline(commandTime,'--k'); grid on; ylabel('pressure (MPa)'); xlabel('time (s)');
legend('HP drum','IP drum','LP drum','Location','eastoutside');
exportgraphics(figureHandle,path,'Resolution',150);
end

function value = envOrDefault(name,defaultValue)
value = getenv(name);
if isempty(value), value = defaultValue; end
end

function writeJson(path,value)
fid = fopen(path,'w','n','UTF-8');
assert(fid >= 0,'TripLens:WriteFailed','Cannot write %s',path);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(value,'PrettyPrint',true));
end

function closeIfLoaded(name)
try
    if bdIsLoaded(name), close_system(name,0); end
catch
end
end
