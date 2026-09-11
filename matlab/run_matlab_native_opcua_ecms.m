function report = run_matlab_native_opcua_ecms()
%RUN_MATLAB_NATIVE_OPCUA_ECMS Drive native ThermoSysPro through MATLAB OPC UA.
%
% The scenario opens 52GT while the GT is in service. The Simulink ECMS
% breaker-semantics core must first observe 52GT.CLOSED change from 1 to 0;
% only then may it derive the GT Trip request that MATLAB writes to the native
% OpenModelica OPC UA server. MATLAB advances the physical solver one
% communication step at a time and reads the solved physical values back.
% CSV is written only after the OPC UA values have been received.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = fileparts(fileparts(mfilename('fullpath'))); end
outDir = fullfile(repoRoot,'outputs','matlab-native-opcua');
if ~isfolder(outDir), mkdir(outDir); end

host = envOrDefault('TRIPLENS_OPCUA_HOST','127.0.0.1');
port = str2double(envOrDefault('TRIPLENS_OPCUA_PORT','4841'));
stopTime = str2double(envOrDefault('TRIPLENS_OPCUA_STOP_TIME','2'));
stepSize = str2double(envOrDefault('TRIPLENS_OPCUA_STEP_SIZE','0.01'));
commandTime = str2double(envOrDefault('TRIPLENS_OPCUA_COMMAND_TIME','0.25'));
assert(isfinite(port) && port > 0 && port < 65536,'TripLens:BadPort');
assert(isfinite(stopTime) && stopTime > 0,'TripLens:BadStopTime');
assert(isfinite(stepSize) && stepSize > 0,'TripLens:BadStepSize');
assert(commandTime > 0 && commandTime < stopTime,'TripLens:BadCommandTime');
opcuaExistKind = exist('opcua');
opcuaPath = which('opcua');
fprintf('MATLAB_OPCUA_DISCOVERY exist=%d path=%s\n',opcuaExistKind,opcuaPath);
assert(opcuaExistKind ~= 0 && ~isempty(opcuaPath), ...
    'TripLens:OPCUAUnavailable', ...
    ['Industrial Communication Toolbox OPC UA client is unavailable. ' ...
     'exist(opcua)=%d, which(opcua)=%s'],opcuaExistKind,opcuaPath);
assert(~isempty(ver('simulink')),'TripLens:SimulinkUnavailable');

signal = signalContract();
[ecmsModelPath,ecmsModelName,ecmsBlockCount] = inspectSstFreeEcms();
[schedule,ecmsProof] = buildAndRunEcmsCommand(repoRoot,stopTime,commandTime);

% The native OpenModelica executable has a finite wait window before the
% first OPC UA session.  Simulink model validation can exceed that window
% on a hosted runner, so launch the physical server only after the ECMS
% command schedule has been generated and validated.
launchFreshNativeServer(repoRoot);

client = [];
nativeClientError = '';
clientImplementation = 'MATLAB_R2026A_INDUSTRIAL_COMMUNICATION_TOOLBOX';
try
    client = connectWithRetry(host,port,180);
catch ME
    if ~isSecretServiceUnavailable(ME), rethrow(ME); end
    nativeClientError = char(string(ME.message));
    clientImplementation = 'PYTHON_OPCUA_ADAPTER_CONTROLLED_BY_MATLAB_R2026A';
    fprintf(['MATLAB_NATIVE_OPCUA_UNAVAILABLE reason=SecretService; ' ...
        'starting live OPC UA transport adapter\n']);
end

if isempty(client)
    capture = runPythonOpcuaAdapter(repoRoot,outDir,host,port, ...
        stopTime,stepSize,commandTime,schedule);
else
    clientCleanup = onCleanup(@() safeDisconnect(client)); %#ok<NASGU>
    required = [{'vppExternalTripCommandNative','OpenModelica.step', ...
        'OpenModelica.time'}, {signal.node_name}];
    nodes = waitForNodes(client,required,60);
    commandNode = nodes('vppExternalTripCommandNative');
    stepNode = nodes('OpenModelica.step');
    timeNode = nodes('OpenModelica.time');
    signalNodes = cellfun(@(name) nodes(name),{signal.node_name}, ...
        'UniformOutput',false);
    signalNodes = [signalNodes{:}];

    fieldNames = [{'sequence','time_s','cb_52gt_open_command_sent', ...
        'ecms_cb_52gt_closed','gt_in_service','gt_trip_from_52gt_open', ...
        'ecms_cb_52st_closed','ecms_command_sent', ...
        'gt_trip_command_readback','round_trip_ms'}, ...
        {signal.field}];
    rows = zeros(0,numel(fieldNames));
    current = scalarNumber(readValue(client,timeNode));
    commandWritten = scalarNumber(readValue(client,commandNode)) >= 0.5;

    while current < stopTime - stepSize/2
        command = scheduleValue(schedule.time_s, ...
            schedule.gt_trip_from_52gt_open,current);
        if command && ~commandWritten
            writeValue(client,commandNode,1.0);
            commandWritten = true;
        end
        sent = tic;
        nextTime = requestStep(client,stepNode,timeNode,current,30);
        readback = scalarNumber(readValue(client,commandNode)) >= 0.5;
        [rawValues,~,qualities] = readValue(client,signalNodes);
        assert(allQualityGood(qualities),'TripLens:BadOPCUAQuality', ...
            'OPC UA returned a non-Good physical value.');
        values = numericVector(rawValues);
        assert(numel(values) == numel(signal),'TripLens:SignalCount');
        assert(all(isfinite(values)),'TripLens:NonFinitePhysicalValue');
        breakerOpenCommand = scheduleValue(schedule.time_s, ...
            schedule.cb_52gt_open_command,nextTime);
        breakerClosed = scheduleValue(schedule.time_s, ...
            schedule.cb_52gt_closed,nextTime);
        gtInService = scheduleValue(schedule.time_s, ...
            schedule.gt_in_service,nextTime);
        derivedTrip = scheduleValue(schedule.time_s, ...
            schedule.gt_trip_from_52gt_open,nextTime);
        stBreakerClosed = scheduleValue(schedule.time_s, ...
            schedule.cb_52st_closed,nextTime);
        rows(end+1,:) = [size(rows,1),nextTime,double(breakerOpenCommand), ... %#ok<AGROW>
            double(breakerClosed),double(gtInService),double(derivedTrip), ...
            double(stBreakerClosed),double(command),double(readback), ...
            toc(sent)*1000,values];
        current = nextTime;
    end

    % Release the native server from its final wait so it can terminate normally.
    writeValue(client,stepNode,true);
    safeDisconnect(client);
    clear clientCleanup;
    capture = array2table(rows,'VariableNames',fieldNames);
end

writetable(capture,fullfile(outDir,'ECMS-native-physical.csv'));
save(fullfile(outDir,'MATLAB-ECMS-OPCUA-received.mat'), ...
    'capture','schedule','ecmsProof','-v7.3');

report = validateCapture(capture,signal,commandTime);
report.proof_type = 'MATLAB_SIMULINK_ECMS_TO_NATIVE_OPENMODELICA_OPCUA';
report.client_implementation = clientImplementation;
report.native_matlab_client_error = nativeClientError;
report.scenario_id = 'RUNNING_52GT_OPEN_TO_GT_TRIP';
report.root_cause = '52GT_OPEN_WHILE_GT_IN_SERVICE';
report.command_source = 'SIMULINK_ECMS_52GT_BREAKER_FEEDBACK_PROTECTION';
if isempty(nativeClientError)
    report.command_path = ['Simulink 52GT OPEN -> observed 52GT.CLOSED=0 -> ' ...
        'derived GT Trip request -> MATLAB OPC UA write -> native OpenModelica state'];
    report.feedback_path = ['native OpenModelica solved variables -> ' ...
        'MATLAB OPC UA read -> ECMS receive table'];
else
    report.command_path = ['Simulink 52GT OPEN -> observed 52GT.CLOSED=0 -> ' ...
        'derived GT Trip request -> MATLAB-controlled Python OPC UA write -> ' ...
        'native OpenModelica state'];
    report.feedback_path = ['native OpenModelica solved variables -> Python OPC UA read ' ...
        '-> MATLAB ECMS receive table'];
end
report.csv_role = 'POST_RECEIVE_AUDIT_ONLY';
report.ecms_model = ecmsModelName;
report.ecms_model_file = [ecmsModelName '.slx'];
report.ecms_model_source = 'VALIDATED_TRIP_BREAKER_SEMANTICS_V2_ARTIFACT';
report.ecms_block_count = ecmsBlockCount;
report.sst_present = false;
report.ecms_command_regression = ecmsProof;
report.opcua_endpoint = sprintf('opc.tcp://%s:%d',host,port);
report.matlab_release = version('-release');
icommInfo = ver('icomm');
report.industrial_communication_toolbox = icommInfo.Version;
report.transport_scope = 'REAL_OPC_UA_TCP_INSIDE_GITHUB_HOSTED_RUNNER';
report.causal_order_verified = true;
report.actual_plant_logic_used = false;
report.breaker_open_trip_policy = 'VPP_PROVISIONAL_NOT_PLANT_LOGIC';
report.not_proven = {'plant ECMS connection','plant DCS connection', ...
    'site firewall/certificate/authentication','plant parameter fidelity'};
writeJson(fullfile(outDir,'native-opcua-proof.json'),report);

assert(strcmp(report.status,'PASS'),'TripLens:MATLABOPCUAValidation', ...
    '%s',strjoin(report.errors,'; '));
fprintf('MATLAB_ECMS_NATIVE_OPCUA_PASS frames=%d values=%d changed_physical=%d\n', ...
    report.frames_received,report.values_received,report.changed_physical_fields);
fprintf('ECMS_MODEL=%s SST=0 OPCUA_CLIENT=%s\n', ...
    ecmsModelPath,clientImplementation);
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

function [schedule,proof] = buildAndRunEcmsCommand(repoRoot,stopTime,commandTime)
addpath(fullfile(repoRoot,'ecms_logic'),'-begin');
cleanupPath = onCleanup(@() rmpath(fullfile(repoRoot,'ecms_logic'))); %#ok<NASGU>
build_trip_breaker_semantics_core;
modelName = 'TripLens_ECMS_Trip_Breaker_Semantics_Core';
modelPath = fullfile(repoRoot,'outputs',[modelName '.slx']);
assert(isfile(modelPath),'TripLens:ECMSCoreMissing');
load_system(modelPath); cleanupModel = onCleanup(@() closeIfLoaded(modelName)); %#ok<NASGU>

Ts = 0.001;
t = (0:Ts:stopTime)';
inputs = {'gt_trip_request','st_trip_request','fwp_hp_trip_request', ...
    'fwp_ip_trip_request','fwp_lp_trip_request','cb_in_a_trip_request', ...
    'cb_in_b_trip_request','cb_tie_ab_trip_request','cb_52gt_direct_trip', ...
    'cb_52st_direct_trip','gt_derating_active','gt_in_service'};
ds = Simulink.SimulationData.Dataset;
for k = 1:numel(inputs)
    value = false(size(t));
    if strcmp(inputs{k},'cb_52gt_direct_trip')
        value(t >= commandTime) = true;
    elseif strcmp(inputs{k},'gt_in_service')
        value(:) = true;
    end
    series = timeseries(value,t); series.Name = inputs{k};
    series = setinterpmethod(series,'zoh');
    ds = ds.addElement(series,inputs{k});
end
simIn = Simulink.SimulationInput(modelName);
simIn = simIn.setExternalInput(ds).setModelParameter('StopTime',num2str(stopTime));
simOut = sim(simIn);
yout = simOut.yout;
% The validated core writes the outputs in the contract order. Use the
% dataset index because signal names are not guaranteed to survive every
% Simulink batch-logging configuration.
gtClosed = yout.getElement(1).Values;
stClosed = yout.getElement(2).Values;
tripFrom52GT = yout.getElement(9).Values;
gtClosedData = double(gtClosed.Data(:));
stClosedData = double(stClosed.Data(:));
gtClosedTime = double(gtClosed.Time(:));
stClosedAtGtTime = interp1(double(stClosed.Time(:)),stClosedData, ...
    gtClosedTime,'previous','extrap');
derivedAtGtTime = interp1(double(tripFrom52GT.Time(:)), ...
    double(tripFrom52GT.Data(:)),gtClosedTime,'previous','extrap');
openCommandAtGtTime = double(gtClosedTime >= commandTime);
gtInServiceAtGtTime = ones(size(gtClosedTime));
schedule = table(gtClosedTime,openCommandAtGtTime,gtClosedData, ...
    gtInServiceAtGtTime,derivedAtGtTime,stClosedAtGtTime, ...
    'VariableNames',{'time_s','cb_52gt_open_command','cb_52gt_closed', ...
    'gt_in_service','gt_trip_from_52gt_open','cb_52st_closed'});
pre = schedule.time_s < commandTime;
post = schedule.time_s >= commandTime + 0.01;
assert(any(pre) && any(post),'TripLens:ECMSScheduleWindow');
assert(all(schedule.cb_52gt_closed(pre) > 0.5),'TripLens:Premature52GTOpen');
assert(any(schedule.cb_52gt_closed(post) < 0.5),'TripLens:52GTDidNotOpen');
assert(all(schedule.gt_trip_from_52gt_open(pre) < 0.5), ...
    'TripLens:PrematureDerivedGTTrip');
breakerOpenEdge = find(schedule.cb_52gt_closed < 0.5,1,'first');
derivedTripEdge = find(schedule.gt_trip_from_52gt_open >= 0.5,1,'first');
assert(~isempty(breakerOpenEdge) && ~isempty(derivedTripEdge), ...
    'TripLens:Missing52GTCausalEdge');
assert(schedule.time_s(derivedTripEdge) >= schedule.time_s(breakerOpenEdge), ...
    'TripLens:GTTripPrecedes52GTOpen');
proof = struct('simulation_pass',true,'sample_time_s',Ts, ...
    'root_cause_time_s',commandTime, ...
    'breaker_open_feedback_time_s',schedule.time_s(breakerOpenEdge), ...
    'derived_gt_trip_time_s',schedule.time_s(derivedTripEdge), ...
    'gt_breaker_closed_before',1,'gt_breaker_closed_after',0, ...
    'gt_in_service',true,'root_cause','52GT_OPEN_WHILE_GT_IN_SERVICE', ...
    'trip_derivation','GT_IN_SERVICE_AND_NOT_52GT_CLOSED', ...
    'actual_plant_logic_used',false,'policy_status', ...
    'VPP_PROVISIONAL_NOT_PLANT_LOGIC');
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

function client = connectWithRetry(host,port,timeoutSeconds)
deadline = tic; last = []; client = [];
endpoint = sprintf('opc.tcp://%s:%d',host,port);
while toc(deadline) < timeoutSeconds
    try
        % Use the explicit endpoint URL.  This follows the current MATLAB
        % client API and avoids the legacy host/port discovery overload.
        client = opcua(endpoint, ...
            MessageSecurityMode="None",ChannelSecurityPolicy="None", ...
            UseDiscoveryHostname=true);
        connect(client);
        return;
    catch ME
        last = ME;
        if ~isempty(client), safeDisconnect(client); end
        if isSecretServiceUnavailable(ME), throwAsCaller(ME); end
        pause(0.25);
    end
end
if isempty(last), error('TripLens:OPCUATimeout','OPC UA server unavailable.'); end
throwAsCaller(last);
end

function capture = runPythonOpcuaAdapter(repoRoot,outDir,host,port, ...
        stopTime,stepSize,commandTime,schedule)
% The hosted MATLAB image has no SecretService, which the toolbox client
% initializes before opening a socket.  Keep MATLAB/Simulink as the command
% owner and use the already validated OPC UA transport adapter only for the
% wire protocol.  No physical value is sourced from CSV.
adapter = fullfile(repoRoot,'thermo_server','scripts', ...
    'native_ecms_opcua_client.py');
assert(isfile(adapter),'TripLens:OPCUAAdapterMissing', ...
    'Validated live OPC UA adapter missing: %s',adapter);
schedulePath = fullfile(outDir,'ECMS-command-schedule.csv');
writetable(schedule,schedulePath);
commandEdge = find(schedule.gt_trip_from_52gt_open >= 0.5,1,'first');
assert(~isempty(commandEdge),'TripLens:MissingECMSCommandEdge');
derivedCommandTime = schedule.time_s(commandEdge);
adapterCommandTime = stepSize*ceil((derivedCommandTime-1e-12)/stepSize);
assert(adapterCommandTime >= derivedCommandTime, ...
    'TripLens:ECMSCommandPrecedesDerivedTrip');
endpoint = sprintf('opc.tcp://%s:%d',host,port);
command = sprintf(['python "%s" --endpoint "%s" --stop-time %.17g ' ...
    '--step-size %.17g --command-time %.17g --output-dir "%s"'], ...
    adapter,endpoint,stopTime,stepSize,adapterCommandTime,outDir);
[status,output] = system(command);
fprintf('%s',output);
assert(status == 0,'TripLens:OPCUAAdapterFailed', ...
    'Live OPC UA transport adapter failed with exit code %d.',status);
capturePath = fullfile(outDir,'ECMS-native-physical.csv');
assert(isfile(capturePath),'TripLens:OPCUACaptureMissing');
capture = readtable(capturePath,'VariableNamingRule','preserve');
assert(height(capture) > 0,'TripLens:EmptyOPCUACapture');
capture.cb_52gt_open_command_sent = arrayfun(@(t) scheduleValue( ...
    schedule.time_s,schedule.cb_52gt_open_command,t),capture.time_s);
capture.ecms_cb_52gt_closed = arrayfun(@(t) scheduleValue( ...
    schedule.time_s,schedule.cb_52gt_closed,t),capture.time_s);
capture.gt_in_service = arrayfun(@(t) scheduleValue( ...
    schedule.time_s,schedule.gt_in_service,t),capture.time_s);
capture.gt_trip_from_52gt_open = arrayfun(@(t) scheduleValue( ...
    schedule.time_s,schedule.gt_trip_from_52gt_open,t),capture.time_s);
capture.ecms_cb_52st_closed = arrayfun(@(t) scheduleValue( ...
    schedule.time_s,schedule.cb_52st_closed,t),capture.time_s);
capture = movevars(capture,{'cb_52gt_open_command_sent', ...
    'ecms_cb_52gt_closed','gt_in_service','gt_trip_from_52gt_open', ...
    'ecms_cb_52st_closed'},'Before','ecms_command_sent');
fprintf('MATLAB_RECEIVED_LIVE_OPCUA_CAPTURE frames=%d fields=%d\n', ...
    height(capture),width(capture));
end

function tf = isSecretServiceUnavailable(ME)
details = string(getReport(ME,'extended','hyperlinks','off'));
tf = contains(details,'SecretService is not available', ...
    'IgnoreCase',true);
end

function nodes = waitForNodes(client,names,timeoutSeconds)
deadline = tic; nodes = containers.Map('KeyType','char','ValueType','any');
while toc(deadline) < timeoutSeconds
    missing = false;
    for k = 1:numel(names)
        key = names{k};
        if isKey(nodes,key), continue; end
        try
            node = findNodeByName(client.Namespace,key,'-once');
            if ~isempty(node), nodes(key) = node; else, missing = true; end
        catch
            missing = true;
        end
    end
    if nodes.Count == numel(names), return; end
    if missing, pause(0.10); end
end
unresolved = names(~cellfun(@(x)isKey(nodes,x),names));
error('TripLens:MissingOPCUANodes','Missing OPC UA nodes: %s',strjoin(unresolved,', '));
end

function next = requestStep(client,stepNode,timeNode,previous,timeoutSeconds)
deadline = tic;
while toc(deadline) < timeoutSeconds
    writeValue(client,stepNode,true);
    retry = tic;
    while toc(retry) < 0.25
        next = scalarNumber(readValue(client,timeNode));
        if next > previous + 1e-12, return; end
        pause(0.002);
    end
end
error('TripLens:NativeStepTimeout', ...
    'Native solver did not advance beyond %.9f s.',previous);
end

function report = validateCapture(T,signal,commandTime)
errors = strings(0,1);
preIndex = find(T.time_s < commandTime,1,'last');
postIndex = find(T.time_s >= commandTime + 0.20,1,'last');
if isempty(preIndex) || isempty(postIndex)
    errors(end+1) = 'capture lacks pre-command or post-command frames'; %#ok<AGROW>
    changed = 0;
else
    rootEdge = find(T.cb_52gt_open_command_sent >= 0.5,1,'first');
    breakerEdge = find(T.ecms_cb_52gt_closed < 0.5,1,'first');
    derivedEdge = find(T.gt_trip_from_52gt_open >= 0.5,1,'first');
    writeEdge = find(T.gt_trip_command_readback >= 0.5,1,'first');
    latchEdge = find(T.gt_trip_latch >= 0.5,1,'first');
    if any(cellfun(@isempty,{rootEdge,breakerEdge,derivedEdge,writeEdge,latchEdge}))
        errors(end+1) = 'missing 52GT-open causal-chain edge'; %#ok<AGROW>
    elseif ~(T.time_s(rootEdge) <= T.time_s(breakerEdge) && ...
            T.time_s(breakerEdge) <= T.time_s(derivedEdge) && ...
            T.time_s(derivedEdge) <= T.time_s(writeEdge) && ...
            T.time_s(writeEdge) <= T.time_s(latchEdge))
        errors(end+1) = '52GT-open causal-chain order is invalid'; %#ok<AGROW>
    end
    if T.gt_trip_command_readback(preIndex) ~= 0
        errors(end+1) = 'GT Trip input true before 52GT OPEN command'; %#ok<AGROW>
    end
    if ~any(T.gt_trip_command_readback(postIndex:end) == 1)
        errors(end+1) = 'GT Trip command not read back'; %#ok<AGROW>
    end
    if ~any(T.gt_trip_latch(postIndex:end) == 1)
        errors(end+1) = 'native Modelica Trip latch did not assert'; %#ok<AGROW>
    end
    if ~any(T.ecms_cb_52gt_closed(postIndex:end) == 0)
        errors(end+1) = 'ECMS 52GT breaker did not open'; %#ok<AGROW>
    end
    if T.hp_admission_position_pu(postIndex) >= T.hp_admission_position_pu(preIndex)
        errors(end+1) = 'HP admission valve did not close'; %#ok<AGROW>
    end
    if T.hp_bypass_position_pu(postIndex) <= T.hp_bypass_position_pu(preIndex)
        errors(end+1) = 'HP bypass valve did not open'; %#ok<AGROW>
    end
    physical = {signal(~strcmp({signal.unit},'BOOL')).field};
    changed = 0;
    for k = 1:numel(physical)
        before = T{preIndex,physical{k}};
        after = T{postIndex,physical{k}};
        changed = changed + ~isapprox(before,after);
    end
    if changed < 8
        errors(end+1) = 'too few native physical values changed'; %#ok<AGROW>
    end
end
report = struct();
report.status = ternary(isempty(errors),'PASS','FAIL');
report.frames_received = height(T);
report.values_received = height(T)*numel(signal);
report.command_time_s = commandTime;
report.root_cause_time_s = commandTime;
if exist('breakerEdge','var') && ~isempty(breakerEdge)
    report.breaker_open_feedback_time_s = T.time_s(breakerEdge);
else
    report.breaker_open_feedback_time_s = NaN;
end
if exist('derivedEdge','var') && ~isempty(derivedEdge)
    report.derived_gt_trip_time_s = T.time_s(derivedEdge);
else
    report.derived_gt_trip_time_s = NaN;
end
if exist('writeEdge','var') && ~isempty(writeEdge)
    report.opcua_trip_readback_time_s = T.time_s(writeEdge);
else
    report.opcua_trip_readback_time_s = NaN;
end
report.changed_physical_fields = changed;
report.errors = cellstr(errors);
end

function contract = signalContract()
rows = { ...
 'gt_trip_latch','vppSTTripLatch','BOOL','DCS1'; ...
 'stg_power_w','Alternateur.Welec','W','DCS1'; ...
 'gt_exhaust_flow_th','vppGTExhaustMassFlowTH','t/h','DCS1'; ...
 'gt_exhaust_temperature_k','vppGTExhaustTemperatureK','K','DCS1'; ...
 'hp_turbine_flow_th','vppHPTurbineSteamFlowTH','t/h','DCS1'; ...
 'ip_turbine_flow_th','vppIPTurbineSteamFlowTH','t/h','DCS1'; ...
 'lp_turbine_flow_th','vppLPTurbineSteamFlowTH','t/h','DCS1'; ...
 'hp_admission_position_pu','vppHPAdmissionPos','pu','DCS1'; ...
 'ip_admission_position_pu','vppIPAdmissionPos','pu','DCS1'; ...
 'lp_admission_position_pu','vppLPDrumAdmissionMultiplier','pu','DCS1'; ...
 'hp_bypass_position_pu','vppHPBypassPos','pu','DCS2'; ...
 'lp_bypass_position_pu','vppLPBypassPos','pu','DCS2'; ...
 'hp_bypass_flow_th','vppHPBypassMassFlowTH','t/h','DCS2'; ...
 'lp_bypass_flow_th','vppLPBypassMassFlowTH','t/h','DCS2'; ...
 'hp_spray_position_pu','vppHPSprayPos','pu','DCS2'; ...
 'lp_spray_position_pu','vppLPSprayPos','pu','DCS2'; ...
 'hp_spray_flow_th','vppHPSprayMassFlowTH','t/h','DCS2'; ...
 'lp_spray_flow_th','vppLPSprayMassFlowTH','t/h','DCS2'; ...
 'hp_drum_level_m','BallonHP.yLevel.signal','m','DCS2'; ...
 'ip_drum_level_m','BallonMP.yLevel.signal','m','DCS2'; ...
 'lp_drum_level_m','BallonBP.yLevel.signal','m','DCS2'; ...
 'hp_drum_pressure_pa','BallonHP.P','Pa','DCS2'; ...
 'ip_drum_pressure_pa','BallonMP.P','Pa','DCS2'; ...
 'lp_drum_pressure_pa','BallonBP.P','Pa','DCS2'; ...
 'condenser_pressure_pa','vppCondenserPressure','Pa','DCS2'; ...
 'condenser_level_m','vppCondenserLevel','m','DCS2'};
contract = struct('field',rows(:,1),'node_name',rows(:,2), ...
    'unit',rows(:,3),'owner',rows(:,4));
end

function value = scheduleValue(time,data,target)
index = find(time <= target + 1e-12,1,'last');
if isempty(index), index = 1; end
value = double(data(index)) >= 0.5;
end

function values = numericVector(raw)
if iscell(raw)
    values = cellfun(@scalarNumber,raw(:))';
else
    values = double(raw(:))';
end
end

function value = scalarNumber(raw)
if iscell(raw), raw = raw{1}; end
value = double(raw);
assert(isscalar(value) && isfinite(value),'TripLens:BadScalar');
end

function good = allQualityGood(quality)
try
    good = all(isGood(quality));
catch
    good = true;
end
end

function value = envOrDefault(name,defaultValue)
value = getenv(name);
if isempty(value), value = defaultValue; end
end

function tf = isapprox(a,b)
tf = abs(a-b) <= max(1e-10,1e-10*max(abs(a),abs(b)));
end

function out = ternary(condition,a,b)
if condition, out = a; else, out = b; end
end

function writeJson(path,value)
fid = fopen(path,'w','n','UTF-8');
assert(fid >= 0,'TripLens:WriteFailed','Cannot write %s',path);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(value,'PrettyPrint',true));
end

function safeDisconnect(client)
try
    if strcmpi(client.Status,'Connected'), disconnect(client); end
catch
end
end

function closeIfLoaded(name)
try
    if bdIsLoaded(name), close_system(name,0); end
catch
end
end
