function build_closed_loop_trip_cosim()
%BUILD_CLOSED_LOOP_TRIP_COSIM Wire model-backed alarms and ECMS trip decisions
% back into actual ThermoSysPro physical inputs.
%
% Closed-loop path implemented here:
%   Thermo raw drum level
%     -> Layer1 H/HH/L/LL (absolute model thresholds)
%     -> Common Trip Matrix in Protection_Control
%     -> immediate latched GT/ST physical trip
%     -> GT exhaust boundary / ST HP+MP admission valves
%     -> ThermoSysPro physical response
%
% Electrical breaker commands (52GT/52ST) remain separately latched inside
% Protection_Control. This file does NOT fabricate breaker position feedback;
% baseline constants are explicitly marked as provisional until Electrical_Twin
% feedback is connected.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = fileparts(fileparts(mfilename('fullpath'))); end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end
settingsPath = fullfile(repoRoot,'ecms_logic','drum_level_first_order_settings.csv');
assert(isfile(settingsPath),'TripLens:MissingLayer1Settings','Missing %s',settingsPath);
settings = readtable(settingsPath,'TextType','string','VariableNamingRule','preserve');

mdrive = '';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable', ...
    'MATLAB Drive local folder is unavailable.');
projectDir=fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
modelName='TripLens_ECMS_DigitalTwin';
modelPath=fullfile(projectDir,[modelName '.slx']);
assert(isfile(modelPath),'TripLens:MissingECMSModel','Missing ECMS model: %s',modelPath);

if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath);
cleanupModel=onCleanup(@() close_system(modelName,0)); %#ok<NASGU>

thermo=[modelName '/Thermo_Interface'];
protection=[modelName '/Protection_Control'];
assert(getSimulinkBlockHandle(thermo)~=-1,'TripLens:MissingThermoInterface','Thermo_Interface missing.');
assert(getSimulinkBlockHandle(protection)~=-1,'TripLens:MissingProtectionControl','Protection_Control missing.');
thermoPorts=get_param(thermo,'PortHandles');
protectionPorts=get_param(protection,'PortHandles');
assert(numel(thermoPorts.Inport)==3 && numel(thermoPorts.Outport)>=9, ...
    'TripLens:ThermoInterfaceContract','Thermo_Interface must expose 3 inputs and >=9 outputs.');
assert(numel(protectionPorts.Inport)==22 && numel(protectionPorts.Outport)==10, ...
    'TripLens:ProtectionInterfaceContract','Protection_Control must expose 22 inputs and 10 outputs.');

% Remove only blocks owned by this closed-loop installer.
owned={ ...
    'First_Order_Drum_Alarms','Physical_Trip_Latch','GT_Physical_Trip_Delay','ST_Physical_Trip_Delay', ...
    'Default_86GT_Healthy','GT_Reset_CMD','Default_52GT_Closed','ST_Reset_CMD','Default_52ST_Closed', ...
    'Default_Bus_A_kV','Default_Bus_B_kV','Default_Bus_A_Live','Default_Bus_B_Live', ...
    'Default_Bus_A_Fault','Default_Bus_B_Fault','Default_Auto_Tie','Default_Allow_Parallel', ...
    'GT_Trip_Request_Log','ST_Trip_Request_Log','GT_Physical_Trip_Log','ST_Physical_Trip_Log', ...
    'CB52GT_Trip_Log','CB52ST_Trip_Log','HP_HH_Log','HP_LL_Log','IP_HH_Log','IP_LL_Log','LP_HH_Log','LP_LL_Log', ...
    'Prot_Term_3','Prot_Term_4','Prot_Term_7','Prot_Term_8','Prot_Term_9','Prot_Term_10', ...
    'Alarm_Term_HP_H','Alarm_Term_HP_L','Alarm_Term_IP_H','Alarm_Term_IP_L', ...
    'Alarm_Term_LP_H','Alarm_Term_LP_L','GT_Flow_Phys_Log','GT_Temp_Phys_Log'};
for k=1:numel(owned)
    p=[modelName '/' owned{k}];
    if getSimulinkBlockHandle(p)~=-1, delete_block(p); end
end
cleanDanglingLines(modelName);

% Clear all external Protection_Control connections. Its internal model-reference
% wiring was independently validated; this step owns only the external boundary.
for k=1:numel(protectionPorts.Inport), disconnectPort(protectionPorts.Inport(k)); end
for k=1:numel(protectionPorts.Outport), disconnectPort(protectionPorts.Outport(k)); end

%% Layer1: actual raw drum levels -> H/HH/L/LL
layer1=[modelName '/First_Order_Drum_Alarms'];
add_block('simulink/Ports & Subsystems/Subsystem',layer1,'Position',[1140 80 1430 350]);
buildFirstOrderAlarmSubsystem(modelName,'First_Order_Drum_Alarms',settings,0.001);

% Thermo_Interface stable outputs: 1 HP level, 3 IP level, 5 LP level.
add_line(modelName,'Thermo_Interface/1','First_Order_Drum_Alarms/1','autorouting','on');
add_line(modelName,'Thermo_Interface/3','First_Order_Drum_Alarms/2','autorouting','on');
add_line(modelName,'Thermo_Interface/5','First_Order_Drum_Alarms/3','autorouting','on');

% Layer1 output order: HP H,HH,L,LL, IP H,HH,L,LL, LP H,HH,L,LL.
alarmToProtection={2,'hp_drum_level_hh';4,'hp_drum_level_ll'; ...
                   6,'ip_drum_level_hh';8,'ip_drum_level_ll'; ...
                  10,'lp_drum_level_hh';12,'lp_drum_level_ll'};
for k=1:size(alarmToProtection,1)
    outNo=alarmToProtection{k,1}; sig=alarmToProtection{k,2};
    pno=portNumber(protection,sig,'Inport');
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',outNo), ...
        sprintf('Protection_Control/%d',pno),'autorouting','on');
end

% Preserve all H/L outputs as explicit Layer1 signals even though they are not
% trip sources in the common matrix.
termMap={1,'Alarm_Term_HP_H';3,'Alarm_Term_HP_L';5,'Alarm_Term_IP_H';7,'Alarm_Term_IP_L'; ...
         9,'Alarm_Term_LP_H';11,'Alarm_Term_LP_L'};
for k=1:size(termMap,1)
    add_block('simulink/Sinks/Terminator',[modelName '/' termMap{k,2}], ...
        'Position',[1500 80+35*k 1520 100+35*k]);
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',termMap{k,1]),[termMap{k,2} '/1'],'autorouting','on');
end

%% Protection_Control external inputs
% Direct operator/scenario commands are decisions only; they do not bypass
% Protection_Control to actuate Thermo physics.
connectSource(modelName,'GT_Trip_CMD',protection,'gt_trip_cmd');
connectSource(modelName,'ST_Trip_CMD',protection,'st_trip_cmd');

% Physical ST power is fed back from Thermo (ST_MW is the W->MW gain installed
% by build_triptac_cosim_dashboard). It is state indication only, not a trip cause.
connectSource(modelName,'ST_MW',protection,'stg_power_mw');

% Provisional electrical/default inputs. These are explicit boundary placeholders,
% not process physics. They will be replaced by Electrical_Twin outputs later.
defaults={ ...
    'Default_86GT_Healthy','1','relay_86gt_healthy'; ...
    'GT_Reset_CMD','0','cb_52gt_reset_cmd'; ...
    'Default_52GT_Closed','1','cb_52gt_closed_fb'; ...
    'ST_Reset_CMD','0','cb_52st_reset_cmd'; ...
    'Default_52ST_Closed','1','cb_52st_closed_fb'; ...
    'Default_Bus_A_kV','6.9','bus_a_voltage_kv'; ...
    'Default_Bus_B_kV','6.9','bus_b_voltage_kv'; ...
    'Default_Bus_A_Live','1','bus_a_native_live'; ...
    'Default_Bus_B_Live','1','bus_b_native_live'; ...
    'Default_Bus_A_Fault','0','bus_a_fault_active'; ...
    'Default_Bus_B_Fault','0','bus_b_fault_active'; ...
    'Default_Auto_Tie','0','auto_bus_tie_enable'; ...
    'Default_Allow_Parallel','0','allow_source_parallel'};
for k=1:size(defaults,1)
    y=390+35*k;
    add_block('simulink/Sources/Constant',[modelName '/' defaults{k,1}], ...
        'Value',defaults{k,2},'Position',[60 y 150 y+22]);
    connectSource(modelName,defaults{k,1},protection,defaults{k,3});
end

%% Layer3 immediate physical trip latch
% Trip requests are latched before they reach physical actuators so an alarm
% recovering after the trip cannot reopen turbine valves or restore GT exhaust.
latch=[modelName '/Physical_Trip_Latch'];
add_block('simulink/Ports & Subsystems/Subsystem',latch,'Position',[1470 390 1730 520]);
buildPhysicalTripLatch(modelName,'Physical_Trip_Latch');

gtReqPort=portNumber(protection,'gt_trip_request','Outport');
stReqPort=portNumber(protection,'st_trip_request','Outport');
add_line(modelName,sprintf('Protection_Control/%d',gtReqPort),'Physical_Trip_Latch/1','autorouting','on');
add_line(modelName,sprintf('Protection_Control/%d',stReqPort),'Physical_Trip_Latch/2','autorouting','on');
add_line(modelName,'GT_Reset_CMD/1','Physical_Trip_Latch/3','autorouting','on');
add_line(modelName,'ST_Reset_CMD/1','Physical_Trip_Latch/4','autorouting','on');

% One 1-ms unit delay explicitly breaks the discrete feedback loop. Physical
% actuation therefore begins one protection tick after the trip decision.
add_block('simulink/Discrete/Unit Delay',[modelName '/GT_Physical_Trip_Delay'], ...
    'SampleTime','0.001','InitialCondition','0','Position',[1770 410 1830 440]);
add_block('simulink/Discrete/Unit Delay',[modelName '/ST_Physical_Trip_Delay'], ...
    'SampleTime','0.001','InitialCondition','0','Position',[1770 470 1830 500]);
add_line(modelName,'Physical_Trip_Latch/1','GT_Physical_Trip_Delay/1','autorouting','on');
add_line(modelName,'Physical_Trip_Latch/2','ST_Physical_Trip_Delay/1','autorouting','on');

% Remove the old manual bypass from GT switch controls and ST FMU input.
disconnectBlockInport([modelName '/GT_Flow_Select'],2);
disconnectBlockInport([modelName '/GT_Temp_Select'],2);
thermoPorts=get_param(thermo,'PortHandles'); disconnectPort(thermoPorts.Inport(3));

% Actual GT physical actuation starts from resolved/latching GT trip, not 52GT
% breaker-open timing. Actual ST physical actuation closes HP/MP admission valves
% from resolved/latching ST trip, not 52ST breaker timing.
add_line(modelName,'GT_Physical_Trip_Delay/1','GT_Flow_Select/2','autorouting','on');
add_line(modelName,'GT_Physical_Trip_Delay/1','GT_Temp_Select/2','autorouting','on');
add_line(modelName,'ST_Physical_Trip_Delay/1','Thermo_Interface/3','autorouting','on');

%% Trace/log the resolved decisions, electrical trips and physical trips
addWorkspaceLog(modelName,'GT_Trip_Request_Log','gt_trip_request_log');
addWorkspaceLog(modelName,'ST_Trip_Request_Log','st_trip_request_log');
addWorkspaceLog(modelName,'GT_Physical_Trip_Log','gt_physical_trip_log');
addWorkspaceLog(modelName,'ST_Physical_Trip_Log','st_physical_trip_log');
addWorkspaceLog(modelName,'CB52GT_Trip_Log','cb52gt_trip_log');
addWorkspaceLog(modelName,'CB52ST_Trip_Log','cb52st_trip_log');
addWorkspaceLog(modelName,'GT_Flow_Phys_Log','gt_flow_phys_log');
addWorkspaceLog(modelName,'GT_Temp_Phys_Log','gt_temp_phys_log');

add_line(modelName,sprintf('Protection_Control/%d',gtReqPort),'GT_Trip_Request_Log/1','autorouting','on');
add_line(modelName,sprintf('Protection_Control/%d',stReqPort),'ST_Trip_Request_Log/1','autorouting','on');
add_line(modelName,'GT_Physical_Trip_Delay/1','GT_Physical_Trip_Log/1','autorouting','on');
add_line(modelName,'ST_Physical_Trip_Delay/1','ST_Physical_Trip_Log/1','autorouting','on');
add_line(modelName,'GT_Flow_Select/1','GT_Flow_Phys_Log/1','autorouting','on');
add_line(modelName,'GT_Temp_Select/1','GT_Temp_Phys_Log/1','autorouting','on');

cbGtPort=portNumber(protection,'cb_52gt_trip_cmd','Outport');
cbStPort=portNumber(protection,'cb_52st_trip_cmd','Outport');
add_line(modelName,sprintf('Protection_Control/%d',cbGtPort),'CB52GT_Trip_Log/1','autorouting','on');
add_line(modelName,sprintf('Protection_Control/%d',cbStPort),'CB52ST_Trip_Log/1','autorouting','on');

% Terminate remaining protection outputs so every interface output has an
% intentional external connection and traceability can distinguish wiring from
% a missing consumer.
remainingOutputs={'relay_86gt_trip_received','relay_86gt_operated','bus_a_27uv_operate', ...
    'bus_b_27uv_operate','cb_tie_ab_auto_close_permissive','stg_low_state'};
for k=1:numel(remainingOutputs)
    pno=portNumber(protection,remainingOutputs{k},'Outport');
    bname=['Prot_Term_' num2str(pno)];
    add_block('simulink/Sinks/Terminator',[modelName '/' bname], ...
        'Position',[1870 560+35*k 1890 580+35*k]);
    add_line(modelName,sprintf('Protection_Control/%d',pno),[bname '/1'],'autorouting','on');
end

% Log trip-driving alarm states for evidence.
alarmLogs={2,'HP_HH_Log','hp_hh_log';4,'HP_LL_Log','hp_ll_log'; ...
           6,'IP_HH_Log','ip_hh_log';8,'IP_LL_Log','ip_ll_log'; ...
          10,'LP_HH_Log','lp_hh_log';12,'LP_LL_Log','lp_ll_log'};
for k=1:size(alarmLogs,1)
    addWorkspaceLog(modelName,alarmLogs{k,2},alarmLogs{k,3});
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',alarmLogs{k,1]), ...
        [alarmLogs{k,2} '/1'],'autorouting','on');
end

set_param(modelName,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','0.001');
set_param(modelName,'SimulationCommand','update');
save_system(modelName,modelPath);

%% Closed-loop regression: baseline, direct ST trip, GT trip + ST intertrip
originalGT=get_param([modelName '/GT_Trip_CMD'],'Value');
originalST=get_param([modelName '/ST_Trip_CMD'],'Value');
restore=onCleanup(@() restoreCommands(modelName,originalGT,originalST)); %#ok<NASGU>

% Baseline: no trip reaches Thermo; native admission remains 0.8.
set_param([modelName '/GT_Trip_CMD'],'Value','0');
set_param([modelName '/ST_Trip_CMD'],'Value','0');
base=sim(modelName,'StopTime','0.2','ReturnWorkspaceOutputs','on');
baseHPValve=lastValue(base,'hp_valve_log');
baseMPValve=lastValue(base,'mp_valve_log');
assert(abs(baseHPValve-0.8)<1e-6 && abs(baseMPValve-0.8)<1e-6, ...
    'TripLens:BaselineValve','Baseline HP/MP ST inlet valves must remain at 0.8.');
assert(lastValue(base,'gt_physical_trip_log')<0.5 && lastValue(base,'st_physical_trip_log')<0.5, ...
    'TripLens:BaselineTrip','Physical trip unexpectedly active in baseline.');

% Direct ST Trip: ST physical admission closes, GT physical boundary stays normal.
set_param([modelName '/GT_Trip_CMD'],'Value','0');
set_param([modelName '/ST_Trip_CMD'],'Value','1');
stcase=sim(modelName,'StopTime','0.2','ReturnWorkspaceOutputs','on');
assert(lastValue(stcase,'st_trip_request_log')>0.5 && lastValue(stcase,'st_physical_trip_log')>0.5, ...
    'TripLens:STTripRequest','Direct ST trip did not reach physical ST latch.');
assert(lastValue(stcase,'gt_physical_trip_log')<0.5, ...
    'TripLens:STTripBackfeed','Direct ST trip incorrectly tripped GT.');
assert(lastValue(stcase,'hp_valve_log')<1e-6 && lastValue(stcase,'mp_valve_log')<1e-6, ...
    'TripLens:STValveNotClosed','Direct ST trip did not close actual HP/MP turbine inlet valves.');
assert(abs(lastValue(stcase,'gt_flow_phys_log')-606.94)<1e-6 && ...
       abs(lastValue(stcase,'gt_temp_phys_log')-893.75)<1e-6, ...
    'TripLens:STTripChangedGT','ST-only trip incorrectly changed GT physical boundary.');

% GT Trip: GT physical boundary trips and Common Matrix intertrips ST physically.
set_param([modelName '/GT_Trip_CMD'],'Value','1');
set_param([modelName '/ST_Trip_CMD'],'Value','0');
gtcase=sim(modelName,'StopTime','0.2','ReturnWorkspaceOutputs','on');
assert(lastValue(gtcase,'gt_trip_request_log')>0.5 && lastValue(gtcase,'st_trip_request_log')>0.5, ...
    'TripLens:GTIntertripRequest','GT trip did not resolve both GT and ST requests.');
assert(lastValue(gtcase,'gt_physical_trip_log')>0.5 && lastValue(gtcase,'st_physical_trip_log')>0.5, ...
    'TripLens:GTIntertripPhysical','GT trip did not reach both physical trip latches.');
assert(abs(lastValue(gtcase,'gt_flow_phys_log')-150)<1e-6 && ...
       abs(lastValue(gtcase,'gt_temp_phys_log')-550)<1e-6, ...
    'TripLens:GTBoundaryNotTripped','GT trip did not reach actual Thermo GT boundary inputs.');
assert(lastValue(gtcase,'hp_valve_log')<1e-6 && lastValue(gtcase,'mp_valve_log')<1e-6, ...
    'TripLens:GTIntertripSTValve','GT intertrip did not close actual ST inlet valves.');
assert(lastValue(gtcase,'cb52gt_trip_log')>0.5 && lastValue(gtcase,'cb52st_trip_log')>0.5, ...
    'TripLens:BreakerTripLatch','GT trip did not produce both delayed breaker trip latches by 0.2 s.');

% Restore interactive defaults and save the wired model.
set_param([modelName '/GT_Trip_CMD'],'Value','0');
set_param([modelName '/ST_Trip_CMD'],'Value','0');
set_param(modelName,'StopTime','1000');
save_system(modelName,modelPath);
copyfile(modelPath,fullfile(outDir,[modelName '_closed_loop.slx']),'f');

% External-line counts for the Protection_Control boundary.
protectionPorts=get_param(protection,'PortHandles');
inputLines=countConnected(protectionPorts.Inport);
outputLines=countConnected(protectionPorts.Outport);

report=struct();
report.model=modelName; report.model_path=modelPath;
report.closed_loop_thermo_trip_pass=true;
report.layer0_raw_sources={'Thermo_Interface/HP_Drum_Level','Thermo_Interface/IP_Drum_Level','Thermo_Interface/LP_Drum_Level'};
report.layer1='RAW single drum-level value -> H/HH/L/LL using absolute model thresholds';
report.layer2_policy=struct('gt_trip_intertrips_st',true,'drum_hh','ST_ONLY','drum_ll','GT_AND_ST');
report.layer3_physical=struct('gt','gt_trip_request -> latched -> GT exhaust flow/temperature boundary', ...
    'st','st_trip_request -> latched -> actual HP/MP turbine admission valves');
report.breaker_logic=struct('gt','52GT trip latch remains independent/delayed', ...
    'st','52ST trip latch remains independent/delayed');
report.protection_input_external_lines=inputLines;
report.protection_output_external_lines=outputLines;
report.baseline=struct('hp_valve',baseHPValve,'mp_valve',baseMPValve,'pass',true);
report.direct_st_trip=struct('st_physical',lastValue(stcase,'st_physical_trip_log'), ...
    'gt_physical',lastValue(stcase,'gt_physical_trip_log'), ...
    'hp_valve',lastValue(stcase,'hp_valve_log'),'mp_valve',lastValue(stcase,'mp_valve_log'), ...
    'pass',true);
report.gt_trip_intertrip=struct('gt_physical',lastValue(gtcase,'gt_physical_trip_log'), ...
    'st_physical',lastValue(gtcase,'st_physical_trip_log'), ...
    'gt_flow_cmd',lastValue(gtcase,'gt_flow_phys_log'),'gt_temp_cmd',lastValue(gtcase,'gt_temp_phys_log'), ...
    'hp_valve',lastValue(gtcase,'hp_valve_log'),'mp_valve',lastValue(gtcase,'mp_valve_log'), ...
    'cb52gt_trip',lastValue(gtcase,'cb52gt_trip_log'),'cb52st_trip',lastValue(gtcase,'cb52st_trip_log'), ...
    'pass',true);
report.drum_hh_ll_end_to_end='WIRED_FROM_REAL_THERMO_LEVELS; NATURAL_THRESHOLD_CROSSING_NOT_FORCED_IN_THIS TEST';
report.electrical_feedback_scope='PROVISIONAL CONSTANTS FOR 86/52/BUS INPUTS; Electrical_Twin feedback still pending';
report.threshold_status='MODEL_ABSOLUTE_NOT_PLANT_APPROVED';
report.note=['This proves ECMS trip decisions reach actual Thermo physical actuators. ' ...
    'It does not claim a complete electrical closed loop or a naturally occurring drum HH/LL incident.'];

reportPath=fullfile(outDir,'closed_loop_trip_cosim_report.json');
fid=fopen(reportPath,'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write closed-loop report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);

fprintf('TRIPLENS CLOSED-LOOP THERMO TRIP PASS\n');
fprintf('PROTECTION_INPUT_LINES=%d/22\n',inputLines);
fprintf('PROTECTION_OUTPUT_LINES=%d/10\n',outputLines);
fprintf('ST_ONLY: HP_VALVE=%.6g MP_VALVE=%.6g GT_FLOW=%.6g\n', ...
    lastValue(stcase,'hp_valve_log'),lastValue(stcase,'mp_valve_log'),lastValue(stcase,'gt_flow_phys_log'));
fprintf('GT_INTERTRIP: GT_FLOW=%.6g ST_HP_VALVE=%.6g ST_MP_VALVE=%.6g 52GT=%.0f 52ST=%.0f\n', ...
    lastValue(gtcase,'gt_flow_phys_log'),lastValue(gtcase,'hp_valve_log'),lastValue(gtcase,'mp_valve_log'), ...
    lastValue(gtcase,'cb52gt_trip_log'),lastValue(gtcase,'cb52st_trip_log'));
end

function buildFirstOrderAlarmSubsystem(modelName,subName,T,Ts)
sub=[modelName '/' subName];
Simulink.SubSystem.deleteContents(sub);
inputs={'HP_Drum_Level','IP_Drum_Level','LP_Drum_Level'};
for k=1:3
    y=50+(k-1)*70;
    add_block('simulink/Sources/In1',[sub '/' inputs{k}],'Port',num2str(k), ...
        'Position',[25 y 145 y+22]);
end
outs={'HP_H','HP_HH','HP_L','HP_LL','IP_H','IP_HH','IP_L','IP_LL','LP_H','LP_HH','LP_L','LP_LL'};
for k=1:12
    y=30+(k-1)*35;
    add_block('simulink/Sinks/Out1',[sub '/' outs{k}],'Port',num2str(k), ...
        'Position',[720 y 800 y+20]);
end
logic=[sub '/Logic'];
add_block('simulink/User-Defined Functions/MATLAB Function',logic,'Position',[210 35 640 450]);
rt=sfroot; chart=rt.find('-isa','Stateflow.EMChart','Path',logic);
assert(~isempty(chart),'TripLens:AlarmFunction','Could not create Layer1 MATLAB Function block.');
chart.Script=firstOrderCode(T,Ts);
for k=1:3, add_line(sub,[inputs{k} '/1'],['Logic/' num2str(k)],'autorouting','on'); end
for k=1:12, add_line(sub,['Logic/' num2str(k)],[outs{k} '/1'],'autorouting','on'); end
set_param(sub,'Description',['Layer1 model-backed drum level alarms. Absolute thresholds; ' ...
    'not approved plant settings. H/HH/L/LL only.']);
end

function code=firstOrderCode(T,Ts)
order={ ...
    'hp_drum_level','H','hp','hpH'; 'hp_drum_level','HH','hp','hpHH'; ...
    'hp_drum_level','L','hp','hpL'; 'hp_drum_level','LL','hp','hpLL'; ...
    'ip_drum_level','H','ip','ipH'; 'ip_drum_level','HH','ip','ipHH'; ...
    'ip_drum_level','L','ip','ipL'; 'ip_drum_level','LL','ip','ipLL'; ...
    'lp_drum_level','H','lp','lpH'; 'lp_drum_level','HH','lp','lpHH'; ...
    'lp_drum_level','L','lp','lpL'; 'lp_drum_level','LL','lp','lpLL'};
lines={'function [hpH,hpHH,hpL,hpLL,ipH,ipHH,ipL,ipLL,lpH,lpHH,lpL,lpLL] = Logic(hp,ip,lp)'};
lines{end+1}='persistent c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12';
lines{end+1}='persistent s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12';
lines{end+1}='if isempty(c1)';
lines{end+1}='  c1=0;c2=0;c3=0;c4=0;c5=0;c6=0;c7=0;c8=0;c9=0;c10=0;c11=0;c12=0;';
lines{end+1}='  s1=false;s2=false;s3=false;s4=false;s5=false;s6=false;s7=false;s8=false;s9=false;s10=false;s11=false;s12=false;';
lines{end+1}='end';
for k=1:12
    row=T(T.signal==string(order{k,1}) & T.alarm_type==string(order{k,2}),:);
    assert(height(row)==1,'TripLens:Layer1Setting','Expected one setting for %s %s.',order{k,1},order{k,2});
    th=double(row.threshold_m); hy=double(row.hysteresis_m); n=max(1,round(double(row.delay_s)/Ts));
    x=order{k,3}; state=['s' num2str(k)]; count=['c' num2str(k)];
    isHigh=strcmpi(char(row.direction),'HIGH');
    lines{end+1}=sprintf('TH%d=%.17g; HY%d=%.17g; N%d=%.17g;',k,th,k,hy,k,n); %#ok<AGROW>
    lines{end+1}=sprintf('if %s',state); %#ok<AGROW>
    if isHigh
        lines{end+1}=sprintf('  if %s <= TH%d-HY%d; %s=false; %s=0; end',x,k,k,state,count); %#ok<AGROW>
    else
        lines{end+1}=sprintf('  if %s >= TH%d+HY%d; %s=false; %s=0; end',x,k,k,state,count); %#ok<AGROW>
    end
    lines{end+1}='else'; %#ok<AGROW>
    if isHigh
        lines{end+1}=sprintf('  if %s >= TH%d; %s=%s+1; else; %s=0; end',x,k,count,count,count); %#ok<AGROW>
    else
        lines{end+1}=sprintf('  if %s <= TH%d; %s=%s+1; else; %s=0; end',x,k,count,count,count); %#ok<AGROW>
    end
    lines{end+1}=sprintf('  if %s >= N%d; %s=true; end',count,k,state); %#ok<AGROW>
    lines{end+1}='end'; %#ok<AGROW>
end
for k=1:12, lines{end+1}=sprintf('%s=s%d;',order{k,4},k); end %#ok<AGROW>
lines{end+1}='end';
code=strjoin(lines,newline);
end

function buildPhysicalTripLatch(modelName,subName)
sub=[modelName '/' subName]; Simulink.SubSystem.deleteContents(sub);
ins={'GT_Trip_Request','ST_Trip_Request','GT_Reset','ST_Reset'};
for k=1:4
    y=35+(k-1)*45;
    add_block('simulink/Sources/In1',[sub '/' ins{k}],'Port',num2str(k),'Position',[25 y 150 y+20]);
end
outs={'GT_Physical_Trip','ST_Physical_Trip'};
for k=1:2
    y=70+(k-1)*70;
    add_block('simulink/Sinks/Out1',[sub '/' outs{k}],'Port',num2str(k),'Position',[590 y 750 y+20]);
end
logic=[sub '/Logic']; add_block('simulink/User-Defined Functions/MATLAB Function',logic,'Position',[220 45 510 200]);
rt=sfroot; chart=rt.find('-isa','Stateflow.EMChart','Path',logic);
chart.Script=strjoin({ ...
'function [gtTrip,stTrip] = Logic(gtReq,stReq,gtReset,stReset)', ...
'persistent gtLatch stLatch', ...
'if isempty(gtLatch); gtLatch=false; stLatch=false; end', ...
'gtReq=gtReq>0.5; stReq=stReq>0.5; gtReset=gtReset>0.5; stReset=stReset>0.5;', ...
'if gtReq; gtLatch=true; elseif gtReset; gtLatch=false; end', ...
'if stReq; stLatch=true; elseif stReset; stLatch=false; end', ...
'gtTrip=gtLatch; stTrip=stLatch;', ...
'end'},newline);
for k=1:4, add_line(sub,[ins{k} '/1'],['Logic/' num2str(k)],'autorouting','on'); end
for k=1:2, add_line(sub,['Logic/' num2str(k)],[outs{k} '/1'],'autorouting','on'); end
set_param(sub,'Description','Immediate latched physical trip commands; reset only after request clears.');
end

function connectSource(modelName,sourceBlock,subsystem,signalName)
pno=portNumber(subsystem,signalName,'Inport');
add_line(modelName,[sourceBlock '/1'],sprintf('%s/%d',get_param(subsystem,'Name'),pno),'autorouting','on');
end

function pno=portNumber(subsystem,signalName,kind)
block=[subsystem '/' signalName];
assert(getSimulinkBlockHandle(block)~=-1,'TripLens:MissingInterfaceSignal','Missing %s.',block);
actual=get_param(block,'BlockType');
if strcmp(kind,'Inport'), assert(strcmp(actual,'Inport')); else, assert(strcmp(actual,'Outport')); end
pno=str2double(get_param(block,'Port'));
end

function disconnectPort(portHandle)
try
    line=get_param(portHandle,'Line');
    if line~=-1, delete_line(line); end
catch
end
end

function disconnectBlockInport(blockPath,index)
ph=get_param(blockPath,'PortHandles'); disconnectPort(ph.Inport(index));
end

function cleanDanglingLines(modelName)
try
    ls=find_system(modelName,'FindAll','on','SearchDepth',1,'Type','line');
    for h=reshape(ls,1,[])
        src=get_param(h,'SrcPortHandle'); dst=get_param(h,'DstPortHandle');
        if src==-1 || isempty(dst) || any(dst==-1), delete_line(h); end
    end
catch
end
end

function addWorkspaceLog(modelName,blockName,varName)
add_block('simulink/Sinks/To Workspace',[modelName '/' blockName], ...
    'VariableName',varName,'SaveFormat','Structure With Time','Position',[1950 80 2070 105]);
end

function value=lastValue(simOut,name)
x=simOut.get(name);
assert(~isempty(x) && isfield(x,'signals') && ~isempty(x.signals.values), ...
    'TripLens:MissingEvidence','Missing simulation evidence %s.',name);
v=x.signals.values;
value=double(v(end));
end

function n=countConnected(handles)
n=0;
for k=1:numel(handles)
    try
        if get_param(handles(k),'Line')~=-1, n=n+1; end
    catch
    end
end
end

function restoreCommands(modelName,gtValue,stValue)
try
    if bdIsLoaded(modelName)
        set_param([modelName '/GT_Trip_CMD'],'Value',gtValue);
        set_param([modelName '/ST_Trip_CMD'],'Value',stValue);
    end
catch
end
end
