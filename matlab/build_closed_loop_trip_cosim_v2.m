function build_closed_loop_trip_cosim_v2()
%BUILD_CLOSED_LOOP_TRIP_COSIM_V2 Canonical TripLens closed-loop wiring.
%
% Canonical semantics:
%   TRIP request -> protection -> breaker trip command -> breaker CLOSED=0.
%   DERATING -> process boundary reduction while breaker remains CLOSED=1.
%
% Protection policy:
%   GT Trip       -> 52GT OPEN + ST intertrip -> 52ST OPEN
%   ST Trip       -> 52ST OPEN only
%   Drum HH       -> ST request -> 52ST OPEN only
%   Drum LL       -> GT + ST requests -> 52GT OPEN + 52ST OPEN
%
% Thermodynamic secondary effects:
%   ST Trip request additionally closes the actual HP/MP turbine admission
%   valves through Thermo_Interface/stTripCmd. This valve action is NOT the
%   definition of Trip; breaker CLOSED=0 is.
%
% GT thermodynamic shutdown is intentionally NOT fabricated. The old
% 606.94/893.75 -> 150/550 boundary change is retained only as GT DERATING.
% A future native GT shutdown/rundown adapter may be added separately.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs'); if ~isfolder(outDir), mkdir(outDir); end
settingsPath=fullfile(repoRoot,'ecms_logic','drum_level_first_order_settings.csv');
assert(isfile(settingsPath),'TripLens:MissingLayer1Settings');
settings=readtable(settingsPath,'TextType','string','VariableNamingRule','preserve');

mdrive='';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable');
projectDir=fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
modelsDir=fullfile(projectDir,'models');
fmuDir=fullfile(projectDir,'fmu');
modelName='TripLens_ECMS_DigitalTwin';
modelPath=fullfile(projectDir,[modelName '.slx']);
assert(isfile(modelPath),'TripLens:MissingECMSModel');
assert(isfolder(modelsDir),'TripLens:ReferencedModelsMissing');
assert(isfolder(fmuDir) && isfile(fullfile(fmuDir,'TripLens_CombinedCycle_TripTAC_CoSim.fmu')), ...
    'TripLens:FMUMissing');
addpath(modelsDir,'-begin'); c1=onCleanup(@()safeRmpath(modelsDir)); %#ok<NASGU>
addpath(fmuDir,'-begin'); c2=onCleanup(@()safeRmpath(fmuDir)); %#ok<NASGU>

if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath); c3=onCleanup(@()close_system(modelName,0)); %#ok<NASGU>
thermo=[modelName '/Thermo_Interface'];
protection=[modelName '/Protection_Control'];
assert(getSimulinkBlockHandle(thermo)~=-1,'TripLens:MissingThermoInterface');
assert(getSimulinkBlockHandle(protection)~=-1,'TripLens:MissingProtectionControl');
thermoPorts=get_param(thermo,'PortHandles');
protectionPorts=get_param(protection,'PortHandles');
assert(numel(thermoPorts.Inport)==3 && numel(thermoPorts.Outport)>=9,'TripLens:ThermoContract');
assert(numel(protectionPorts.Inport)==22 && numel(protectionPorts.Outport)==10,'TripLens:ProtectionContract');

%% Remove prior integration-owned blocks and external Protection_Control lines.
owned={ ...
 'First_Order_Drum_Alarms','Generator_Breaker_State','ST_Shutdown_Latch','ST_Shutdown_Delay', ...
 'Default_86GT_Healthy','GT_Reset_CMD','ST_Reset_CMD','Default_Bus_A_kV','Default_Bus_B_kV', ...
 'Default_Bus_A_Live','Default_Bus_B_Live','Default_Bus_A_Fault','Default_Bus_B_Fault', ...
 'Default_Auto_Tie','Default_Allow_Parallel','Default_52GT_Closed','Default_52ST_Closed', ...
 'GT_Trip_Request_Log','ST_Trip_Request_Log','CB52GT_Trip_Log','CB52ST_Trip_Log', ...
 '52GT_Closed_Log','52ST_Closed_Log','ST_Shutdown_Log','GT_Derate_Log', ...
 'HP_HH_Log','HP_LL_Log','IP_HH_Log','IP_LL_Log','LP_HH_Log','LP_LL_Log', ...
 'Alarm_Term_HP_H','Alarm_Term_HP_L','Alarm_Term_IP_H','Alarm_Term_IP_L','Alarm_Term_LP_H','Alarm_Term_LP_L', ...
 'Prot_Term_3','Prot_Term_4','Prot_Term_7','Prot_Term_8','Prot_Term_9','Prot_Term_10'};
for k=1:numel(owned)
    p=[modelName '/' owned{k}]; if getSimulinkBlockHandle(p)~=-1, delete_block(p); end
end
cleanDanglingLines(modelName);
for k=1:numel(protectionPorts.Inport), disconnectPort(protectionPorts.Inport(k)); end
for k=1:numel(protectionPorts.Outport), disconnectPort(protectionPorts.Outport(k)); end

%% Reclassify 150/550 as DERATING, never Trip.
renameIfPresent(modelName,'GT_Trip_Flow','GT_Derate_Flow');
renameIfPresent(modelName,'GT_Trip_Temp','GT_Derate_Temp');
ensureConstant(modelName,'GT_Derate_Flow','150',[170 405 250 435]);
ensureConstant(modelName,'GT_Derate_Temp','550',[170 535 250 565]);
ensureConstant(modelName,'GT_Derate_CMD','0',[170 610 260 640]);
for swName={'GT_Flow_Select','GT_Temp_Select'}
    p=[modelName '/' swName{1}];
    assert(getSimulinkBlockHandle(p)~=-1,'TripLens:MissingDerateSelector');
    ph=get_param(p,'PortHandles'); disconnectPort(ph.Inport(2));
    add_line(modelName,'GT_Derate_CMD/1',[swName{1} '/2'],'autorouting','on');
end
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Flow_Select'),'TripLens:GTTripStillDeratesFlow');
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Temp_Select'),'TripLens:GTTripStillDeratesTemp');

%% Layer 1: real Thermo drum levels -> H/HH/L/LL.
layer1=[modelName '/First_Order_Drum_Alarms'];
add_block('simulink/Ports & Subsystems/Subsystem',layer1,'Position',[1140 80 1430 350]);
buildFirstOrderAlarmSubsystem(modelName,'First_Order_Drum_Alarms',settings,0.001);
add_line(modelName,'Thermo_Interface/1','First_Order_Drum_Alarms/1','autorouting','on');
add_line(modelName,'Thermo_Interface/3','First_Order_Drum_Alarms/2','autorouting','on');
add_line(modelName,'Thermo_Interface/5','First_Order_Drum_Alarms/3','autorouting','on');
alarmToProtection={2,'hp_drum_level_hh';4,'hp_drum_level_ll';6,'ip_drum_level_hh';8,'ip_drum_level_ll';10,'lp_drum_level_hh';12,'lp_drum_level_ll'};
for k=1:size(alarmToProtection,1)
    pno=portNumber(protection,alarmToProtection{k,2},'Inport');
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',alarmToProtection{k,1}), ...
        sprintf('Protection_Control/%d',pno),'autorouting','on');
end
termMap={1,'Alarm_Term_HP_H';3,'Alarm_Term_HP_L';5,'Alarm_Term_IP_H';7,'Alarm_Term_IP_L';9,'Alarm_Term_LP_H';11,'Alarm_Term_LP_L'};
for k=1:size(termMap,1)
    add_block('simulink/Sinks/Terminator',[modelName '/' termMap{k,2}],'Position',[1500 70+35*k 1520 90+35*k]);
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',termMap{k,1}),[termMap{k,2} '/1'],'autorouting','on');
end

%% Protection_Control inputs.
connectSource(modelName,'GT_Trip_CMD',protection,'gt_trip_cmd');
connectSource(modelName,'ST_Trip_CMD',protection,'st_trip_cmd');
connectSource(modelName,'ST_MW',protection,'stg_power_mw');
defaults={ ...
 'Default_86GT_Healthy','1','relay_86gt_healthy'; ...
 'GT_Reset_CMD','0','cb_52gt_reset_cmd'; ...
 'ST_Reset_CMD','0','cb_52st_reset_cmd'; ...
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
    ensureConstant(modelName,defaults{k,1},defaults{k,2},[60 y 155 y+22]);
    connectSource(modelName,defaults{k,1},protection,defaults{k,3});
end

%% Canonical generator breaker actuator: Trip success == CLOSED=0.
breaker=[modelName '/Generator_Breaker_State'];
add_block('simulink/Ports & Subsystems/Subsystem',breaker,'Position',[1480 390 1740 520]);
buildGeneratorBreakerState(breaker,0.001);
gtBreakerTrip=portNumber(protection,'cb_52gt_trip_cmd','Outport');
stBreakerTrip=portNumber(protection,'cb_52st_trip_cmd','Outport');
gtClosed=portNumber(protection,'cb_52gt_closed_fb','Inport');
stClosed=portNumber(protection,'cb_52st_closed_fb','Inport');
add_line(modelName,sprintf('Protection_Control/%d',gtBreakerTrip),'Generator_Breaker_State/1','autorouting','on');
add_line(modelName,sprintf('Protection_Control/%d',stBreakerTrip),'Generator_Breaker_State/2','autorouting','on');
add_line(modelName,'Generator_Breaker_State/1',sprintf('Protection_Control/%d',gtClosed),'autorouting','on');
add_line(modelName,'Generator_Breaker_State/2',sprintf('Protection_Control/%d',stClosed),'autorouting','on');

%% ST thermodynamic shutdown is a secondary effect, not the Trip definition.
stReq=portNumber(protection,'st_trip_request','Outport');
stLatch=[modelName '/ST_Shutdown_Latch'];
add_block('simulink/Ports & Subsystems/Subsystem',stLatch,'Position',[1480 550 1740 650]);
buildSTShutdownLatch(stLatch,0.001);
add_line(modelName,sprintf('Protection_Control/%d',stReq),'ST_Shutdown_Latch/1','autorouting','on');
add_line(modelName,'ST_Reset_CMD/1','ST_Shutdown_Latch/2','autorouting','on');
thermoPorts=get_param(thermo,'PortHandles'); disconnectPort(thermoPorts.Inport(3));
add_line(modelName,'ST_Shutdown_Latch/1','Thermo_Interface/3','autorouting','on');

%% Evidence logs.
gtReq=portNumber(protection,'gt_trip_request','Outport');
logs={ ...
 'GT_Trip_Request_Log','gt_trip_request_log',sprintf('Protection_Control/%d',gtReq); ...
 'ST_Trip_Request_Log','st_trip_request_log',sprintf('Protection_Control/%d',stReq); ...
 'CB52GT_Trip_Log','cb52gt_trip_log',sprintf('Protection_Control/%d',gtBreakerTrip); ...
 'CB52ST_Trip_Log','cb52st_trip_log',sprintf('Protection_Control/%d',stBreakerTrip); ...
 '52GT_Closed_Log','cb52gt_closed_log','Generator_Breaker_State/1'; ...
 '52ST_Closed_Log','cb52st_closed_log','Generator_Breaker_State/2'; ...
 'ST_Shutdown_Log','st_shutdown_log','ST_Shutdown_Latch/1'; ...
 'GT_Derate_Log','gt_derate_log','GT_Derate_CMD/1'};
for k=1:size(logs,1)
    addWorkspaceLog(modelName,logs{k,1},logs{k,2});
    add_line(modelName,logs{k,3},[logs{k,1} '/1'],'autorouting','on');
end
alarmLogs={2,'HP_HH_Log','hp_hh_log';4,'HP_LL_Log','hp_ll_log';6,'IP_HH_Log','ip_hh_log';8,'IP_LL_Log','ip_ll_log';10,'LP_HH_Log','lp_hh_log';12,'LP_LL_Log','lp_ll_log'};
for k=1:size(alarmLogs,1)
    addWorkspaceLog(modelName,alarmLogs{k,2},alarmLogs{k,3});
    add_line(modelName,sprintf('First_Order_Drum_Alarms/%d',alarmLogs{k,1}),[alarmLogs{k,2} '/1'],'autorouting','on');
end

% Intentionally terminate remaining protection outputs after relevant consumers.
remaining={'relay_86gt_trip_received','relay_86gt_operated','bus_a_27uv_operate','bus_b_27uv_operate','cb_tie_ab_auto_close_permissive','stg_low_state'};
for k=1:numel(remaining)
    pno=portNumber(protection,remaining{k},'Outport');
    b=['Prot_Term_' num2str(pno)];
    add_block('simulink/Sinks/Terminator',[modelName '/' b],'Position',[1880 580+32*k 1900 600+32*k]);
    add_line(modelName,sprintf('Protection_Control/%d',pno),[b '/1'],'autorouting','on');
end

set_param(modelName,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','0.001');
set_param(modelName,'SimulationCommand','update');
save_system(modelName,modelPath);
copyfile(modelPath,fullfile(outDir,[modelName '_closed_loop_v2.slx']),'f');

% Structural invariants. Dynamic breaker regression is separately proven by
% build_trip_breaker_semantics_core so this installer does not cold-start the FMU.
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Flow_Select'));
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Temp_Select'));
assert(sourceDrivesBlock(modelName,'GT_Derate_CMD','GT_Flow_Select'));
assert(sourceDrivesBlock(modelName,'GT_Derate_CMD','GT_Temp_Select'));
report=struct();
report.model=modelName;
report.structural_pass=true;
report.trip_definition='TRIP_SUCCESS_IFF_ASSOCIATED_BREAKER_CLOSED_FEEDBACK_EQUALS_0';
report.derating_definition='GT 150/550 boundary reduction with generator breaker remaining CLOSED';
report.gt_trip=struct('breaker','52GT.CLOSED=0','st_intertrip','52ST.CLOSED=0','direct_gt_boundary_reduction',false);
report.st_trip=struct('breaker','52ST.CLOSED=0','gt_breaker_unchanged',true,'secondary_valve_shutdown',true);
report.drum_hh='ST request only -> 52ST.CLOSED=0';
report.drum_ll='GT + ST requests -> 52GT.CLOSED=0 and 52ST.CLOSED=0';
report.gt_thermodynamic_shutdown='PENDING_NATIVE_GT_SHUTDOWN_ADAPTER; 150/550 IS NOT USED AS TRIP';
report.runtime_breaker_semantics='PROVEN_SEPARATELY_BY_TRIP_BREAKER_SEMANTICS_CORE';
report.full_native_seeded_ecms_thermo_runtime='PENDING';
report.threshold_status='MODEL_ABSOLUTE_NOT_PLANT_APPROVED';
fid=fopen(fullfile(outDir,'closed_loop_trip_cosim_v2_report.json'),'w','n','UTF-8'); assert(fid>=0);
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('TRIPLENS CLOSED LOOP TRIP SEMANTICS V2 STRUCTURAL PASS\n');
fprintf('TRIP_REQUIRES_BREAKER_CLOSED_ZERO=1\n');
fprintf('GT_150_550_CLASSIFICATION=DERATING\n');
end

function buildFirstOrderAlarmSubsystem(modelName,subName,T,Ts)
sub=[modelName '/' subName]; Simulink.SubSystem.deleteContents(sub);
inputs={'HP_Drum_Level','IP_Drum_Level','LP_Drum_Level'};
for k=1:3
    y=50+(k-1)*70;
    add_block('simulink/Sources/In1',[sub '/' inputs{k}],'Port',num2str(k),'Position',[25 y 145 y+22]);
end
outs={'HP_H','HP_HH','HP_L','HP_LL','IP_H','IP_HH','IP_L','IP_LL','LP_H','LP_HH','LP_L','LP_LL'};
for k=1:12
    y=30+(k-1)*35;
    add_block('simulink/Sinks/Out1',[sub '/' outs{k}],'Port',num2str(k),'Position',[720 y 800 y+20]);
end
logic=[sub '/Logic'];
add_block('simulink/User-Defined Functions/MATLAB Function',logic,'Position',[210 35 640 450]);
rt=sfroot; chart=rt.find('-isa','Stateflow.EMChart','Path',logic); assert(~isempty(chart));
chart.Script=firstOrderCode(T,Ts);
for k=1:3, add_line(sub,[inputs{k} '/1'],['Logic/' num2str(k)],'autorouting','on'); end
for k=1:12, add_line(sub,['Logic/' num2str(k)],[outs{k} '/1'],'autorouting','on'); end
set_param(sub,'Description','Layer1 H/HH/L/LL from actual Thermo drum levels; model absolute thresholds.');
end

function code=firstOrderCode(T,Ts)
order={ ...
 'hp_drum_level','H','hp','hpH';'hp_drum_level','HH','hp','hpHH';'hp_drum_level','L','hp','hpL';'hp_drum_level','LL','hp','hpLL'; ...
 'ip_drum_level','H','ip','ipH';'ip_drum_level','HH','ip','ipHH';'ip_drum_level','L','ip','ipL';'ip_drum_level','LL','ip','ipLL'; ...
 'lp_drum_level','H','lp','lpH';'lp_drum_level','HH','lp','lpHH';'lp_drum_level','L','lp','lpL';'lp_drum_level','LL','lp','lpLL'};
lines={'function [hpH,hpHH,hpL,hpLL,ipH,ipHH,ipL,ipLL,lpH,lpHH,lpL,lpLL] = Logic(hp,ip,lp)'};
lines{end+1}='persistent c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12';
lines{end+1}='persistent s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12';
lines{end+1}='if isempty(c1); c1=0;c2=0;c3=0;c4=0;c5=0;c6=0;c7=0;c8=0;c9=0;c10=0;c11=0;c12=0; s1=false;s2=false;s3=false;s4=false;s5=false;s6=false;s7=false;s8=false;s9=false;s10=false;s11=false;s12=false; end';
for k=1:12
    row=T(T.signal==string(order{k,1}) & T.alarm_type==string(order{k,2}),:); assert(height(row)==1);
    th=double(row.threshold_m); hy=double(row.hysteresis_m); n=max(1,round(double(row.delay_s)/Ts));
    x=order{k,3}; s=['s' num2str(k)]; c=['c' num2str(k)]; high=strcmpi(char(row.direction),'HIGH');
    lines{end+1}=sprintf('TH%d=%.17g; HY%d=%.17g; N%d=%.17g;',k,th,k,hy,k,n); %#ok<AGROW>
    lines{end+1}=sprintf('if %s',s); %#ok<AGROW>
    if high, lines{end+1}=sprintf(' if %s<=TH%d-HY%d; %s=false; %s=0; end',x,k,k,s,c); else, lines{end+1}=sprintf(' if %s>=TH%d+HY%d; %s=false; %s=0; end',x,k,k,s,c); end %#ok<AGROW>
    lines{end+1}='else'; %#ok<AGROW>
    if high, lines{end+1}=sprintf(' if %s>=TH%d; %s=%s+1; else; %s=0; end',x,k,c,c,c); else, lines{end+1}=sprintf(' if %s<=TH%d; %s=%s+1; else; %s=0; end',x,k,c,c,c); end %#ok<AGROW>
    lines{end+1}=sprintf(' if %s>=N%d; %s=true; end',c,k,s); %#ok<AGROW>
    lines{end+1}='end'; %#ok<AGROW>
end
for k=1:12, lines{end+1}=sprintf('%s=s%d;',order{k,4},k); end %#ok<AGROW>
lines{end+1}='end'; code=strjoin(lines,newline);
end

function buildGeneratorBreakerState(sub,Ts)
Simulink.SubSystem.deleteContents(sub);
add_block('simulink/Sources/In1',[sub '/52GT_Trip_Cmd'],'Port','1','Position',[20 45 145 65]);
add_block('simulink/Sources/In1',[sub '/52ST_Trip_Cmd'],'Port','2','Position',[20 115 145 135]);
add_block('simulink/Sinks/Out1',[sub '/52GT_CLOSED'],'Port','1','Position',[650 55 780 75]);
add_block('simulink/Sinks/Out1',[sub '/52ST_CLOSED'],'Port','2','Position',[650 135 780 155]);
for k=1:2
    y=45+(k-1)*80;
    add_block('simulink/Discrete/Unit Delay',[sub '/Closed_State_' num2str(k)],'SampleTime',num2str(Ts),'InitialCondition','1','Position',[420 y 500 y+30]);
    add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/Not_Trip_' num2str(k)],'Operator','NOT','Position',[190 y 235 y+30]);
    add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/Latch_Open_' num2str(k)],'Operator','AND','Inputs','2','Position',[300 y 350 y+35]);
    tag=ternary(k==1,'GT','ST');
    add_line(sub,['52' tag '_Trip_Cmd/1'],['Not_Trip_' num2str(k) '/1'],'autorouting','on');
    add_line(sub,['Not_Trip_' num2str(k) '/1'],['Latch_Open_' num2str(k) '/1'],'autorouting','on');
    add_line(sub,['Closed_State_' num2str(k) '/1'],['Latch_Open_' num2str(k) '/2'],'autorouting','on');
    add_line(sub,['Latch_Open_' num2str(k) '/1'],['Closed_State_' num2str(k) '/1'],'autorouting','on');
end
add_line(sub,'Closed_State_1/1','52GT_CLOSED/1','autorouting','on');
add_line(sub,'Closed_State_2/1','52ST_CLOSED/1','autorouting','on');
end

function buildSTShutdownLatch(sub,Ts)
Simulink.SubSystem.deleteContents(sub);
add_block('simulink/Sources/In1',[sub '/ST_Trip_Request'],'Port','1','Position',[20 40 150 60]);
add_block('simulink/Sources/In1',[sub '/ST_Reset'],'Port','2','Position',[20 100 150 120]);
add_block('simulink/Sinks/Out1',[sub '/ST_Shutdown'],'Port','1','Position',[620 65 750 85]);
add_block('simulink/Discrete/Unit Delay',[sub '/Latch'],'SampleTime',num2str(Ts),'InitialCondition','0','Position',[440 55 500 85]);
add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/OR'],'Operator','OR','Inputs','2','Position',[220 45 270 85]);
add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/NOT_Reset'],'Operator','NOT','Position',[220 105 270 130]);
add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/AND'],'Operator','AND','Inputs','2','Position',[330 55 380 95]);
add_line(sub,'ST_Trip_Request/1','OR/1','autorouting','on'); add_line(sub,'Latch/1','OR/2','autorouting','on');
add_line(sub,'ST_Reset/1','NOT_Reset/1','autorouting','on'); add_line(sub,'OR/1','AND/1','autorouting','on');
add_line(sub,'NOT_Reset/1','AND/2','autorouting','on'); add_line(sub,'AND/1','Latch/1','autorouting','on'); add_line(sub,'Latch/1','ST_Shutdown/1','autorouting','on');
set_param(sub,'Description','Secondary ST thermodynamic shutdown latch. Breaker OPEN remains canonical Trip result.');
end

function ensureConstant(modelName,name,value,pos)
p=[modelName '/' name];
if getSimulinkBlockHandle(p)==-1, add_block('simulink/Sources/Constant',p,'Value',value,'Position',pos); else, set_param(p,'Value',value); end
end
function connectSource(modelName,source,subsystem,signal)
pno=portNumber(subsystem,signal,'Inport'); add_line(modelName,[source '/1'],sprintf('%s/%d',get_param(subsystem,'Name'),pno),'autorouting','on');
end
function pno=portNumber(subsystem,signal,kind)
b=[subsystem '/' signal]; assert(getSimulinkBlockHandle(b)~=-1,'TripLens:MissingInterfaceSignal','Missing %s',b);
if strcmp(kind,'Inport'), assert(strcmp(get_param(b,'BlockType'),'Inport')); else, assert(strcmp(get_param(b,'BlockType'),'Outport')); end
pno=str2double(get_param(b,'Port'));
end
function disconnectPort(h)
try, l=get_param(h,'Line'); if l~=-1, delete_line(l); end, catch, end
end
function cleanDanglingLines(modelName)
try
    ls=find_system(modelName,'FindAll','on','SearchDepth',1,'Type','line');
    for h=reshape(ls,1,[]), src=get_param(h,'SrcPortHandle'); dst=get_param(h,'DstPortHandle'); if src==-1||isempty(dst)||any(dst==-1), delete_line(h); end, end
catch
end
end
function renameIfPresent(modelName,oldName,newName)
old=[modelName '/' oldName]; new=[modelName '/' newName];
if getSimulinkBlockHandle(old)~=-1, if getSimulinkBlockHandle(new)~=-1, delete_block(new); cleanDanglingLines(modelName); end, set_param(old,'Name',newName); end
end
function tf=sourceDrivesBlock(modelName,sourceName,destName)
tf=false; try, ph=get_param([modelName '/' sourceName],'PortHandles'); l=get_param(ph.Outport(1),'Line'); if l==-1, return; end, dst=get_param(l,'DstBlockHandle'); target=getSimulinkBlockHandle([modelName '/' destName]); tf=any(dst==target); catch, end
end
function addWorkspaceLog(modelName,blockName,varName)
add_block('simulink/Sinks/To Workspace',[modelName '/' blockName],'VariableName',varName,'SaveFormat','Structure With Time','Position',[1960 80 2080 105]);
end
function out=ternary(c,a,b), if c, out=a; else, out=b; end, end
function safeRmpath(p), try, if contains(path,p), rmpath(p); end, catch, end, end
