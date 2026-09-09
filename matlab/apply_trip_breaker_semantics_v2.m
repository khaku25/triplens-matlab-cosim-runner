function apply_trip_breaker_semantics_v2()
%APPLY_TRIP_BREAKER_SEMANTICS_V2 Make breaker OPEN the canonical Trip result.
%
% This installer changes the integrated ECMS model semantics without changing
% ThermoSysPro physics:
%   * GT_TRIP no longer selects the old 150 kg/s / 550 K boundary.
%   * 150/550 is renamed GT DERATING and controlled by GT_Derate_CMD.
%   * 52GT/52ST trip commands drive stateful breaker CLOSED feedback 1 -> 0.
%   * Reset does not reclose a breaker. A future CLOSE command is separate.
%
% ST admission-valve closure remains a secondary shutdown effect. It is not the
% definition of Trip. The definition is breaker CLOSED feedback == 0.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs'); if ~isfolder(outDir), mkdir(outDir); end
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
modelName='TripLens_ECMS_DigitalTwin';
projectDir=fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
modelPath=fullfile(projectDir,[modelName '.slx']);
assert(isfile(modelPath),'TripLens:ModelMissing','Missing %s',modelPath);

% The integrated model contains Model blocks that reference generated ECMS
% cores and an FMU block that resolves the copied TripTAC FMU by filename.
% Resolve both locations before load/update; otherwise Simulink can load the
% parent but fails its diagram update before this installer can save changes.
modelsDir=fullfile(projectDir,'models');
fmuDir=fullfile(projectDir,'fmu');
assert(isfolder(modelsDir),'TripLens:ReferencedModelsMissing','Missing referenced-model directory %s',modelsDir);
assert(isfolder(fmuDir),'TripLens:FMUDirectoryMissing','Missing FMU directory %s',fmuDir);
assert(isfile(fullfile(fmuDir,'TripLens_CombinedCycle_TripTAC_CoSim.fmu')), ...
    'TripLens:FMUMissing','Missing TripTAC FMU in %s',fmuDir);
addpath(modelsDir,'-begin');
modelsPathCleanup=onCleanup(@()safeRmpath(modelsDir)); %#ok<NASGU>
addpath(fmuDir,'-begin');
fmuPathCleanup=onCleanup(@()safeRmpath(fmuDir)); %#ok<NASGU>
if isfolder(outDir)
    addpath(outDir,'-begin');
    outPathCleanup=onCleanup(@()safeRmpath(outDir)); %#ok<NASGU>
end

if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath); cleanup=onCleanup(@()close_system(modelName,0)); %#ok<NASGU>

protection=[modelName '/Protection_Control'];
assert(getSimulinkBlockHandle(protection)~=-1,'TripLens:ProtectionMissing');

%% 1) Reclassify the old 150/550 path as DERATING, not TRIP.
renameIfPresent(modelName,'GT_Trip_Flow','GT_Derate_Flow');
renameIfPresent(modelName,'GT_Trip_Temp','GT_Derate_Temp');
if getSimulinkBlockHandle([modelName '/GT_Derate_Flow'])~=-1
    set_param([modelName '/GT_Derate_Flow'],'Value','150');
end
if getSimulinkBlockHandle([modelName '/GT_Derate_Temp'])~=-1
    set_param([modelName '/GT_Derate_Temp'],'Value','550');
end
if getSimulinkBlockHandle([modelName '/GT_Derate_CMD'])==-1
    add_block('simulink/Sources/Constant',[modelName '/GT_Derate_CMD'], ...
        'Value','0','Position',[165 610 255 640]);
else
    set_param([modelName '/GT_Derate_CMD'],'Value','0');
end

for swName={'GT_Flow_Select','GT_Temp_Select'}
    p=[modelName '/' swName{1}];
    if getSimulinkBlockHandle(p)~=-1
        ph=get_param(p,'PortHandles');
        disconnectPort(ph.Inport(2));
        add_line(modelName,'GT_Derate_CMD/1',[swName{1} '/2'],'autorouting','on');
    end
end

% Ensure true GT_Trip_CMD reaches Protection_Control but does not directly drive
% either GT boundary selector.
assert(getSimulinkBlockHandle([modelName '/GT_Trip_CMD'])~=-1,'TripLens:GTTripCommandMissing');
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Flow_Select'), ...
    'TripLens:TripStillDrivesDerating','GT_Trip_CMD still drives GT_Flow_Select.');
assert(~sourceDrivesBlock(modelName,'GT_Trip_CMD','GT_Temp_Select'), ...
    'TripLens:TripStillDrivesDerating','GT_Trip_CMD still drives GT_Temp_Select.');

%% 2) Install stateful generator breaker actuator.
act=[modelName '/Generator_Breaker_State'];
if getSimulinkBlockHandle(act)~=-1, delete_block(act); end
cleanDanglingLines(modelName);
add_block('simulink/Ports & Subsystems/Subsystem',act,'Position',[1120 600 1430 760]);
buildGeneratorBreakerState(act,0.001);

% Resolve protection interface ports by named child blocks.
gtTripOut=portNumber(protection,'cb_52gt_trip_cmd','Outport');
stTripOut=portNumber(protection,'cb_52st_trip_cmd','Outport');
gtClosedIn=portNumber(protection,'cb_52gt_closed_fb','Inport');
stClosedIn=portNumber(protection,'cb_52st_closed_fb','Inport');

% Remove provisional constant CLOSED feedbacks from Protection_Control.
disconnectSubsystemInport(protection,gtClosedIn);
disconnectSubsystemInport(protection,stClosedIn);
if getSimulinkBlockHandle([modelName '/Default_52GT_Closed'])~=-1, delete_block([modelName '/Default_52GT_Closed']); end
if getSimulinkBlockHandle([modelName '/Default_52ST_Closed'])~=-1, delete_block([modelName '/Default_52ST_Closed']); end
cleanDanglingLines(modelName);

add_line(modelName,sprintf('Protection_Control/%d',gtTripOut),'Generator_Breaker_State/1','autorouting','on');
add_line(modelName,sprintf('Protection_Control/%d',stTripOut),'Generator_Breaker_State/2','autorouting','on');
add_line(modelName,'Generator_Breaker_State/1',sprintf('Protection_Control/%d',gtClosedIn),'autorouting','on');
add_line(modelName,'Generator_Breaker_State/2',sprintf('Protection_Control/%d',stClosedIn),'autorouting','on');

%% 3) Expose actual CLOSED states as evidence.
for x={'52GT_Closed_Log','52ST_Closed_Log'}
    p=[modelName '/' x{1}]; if getSimulinkBlockHandle(p)~=-1, delete_block(p); end
end
add_block('simulink/Sinks/To Workspace',[modelName '/52GT_Closed_Log'], ...
    'VariableName','cb52gt_closed_log','SaveFormat','Structure With Time','Position',[1490 610 1620 640]);
add_block('simulink/Sinks/To Workspace',[modelName '/52ST_Closed_Log'], ...
    'VariableName','cb52st_closed_log','SaveFormat','Structure With Time','Position',[1490 690 1620 720]);
add_line(modelName,'Generator_Breaker_State/1','52GT_Closed_Log/1','autorouting','on');
add_line(modelName,'Generator_Breaker_State/2','52ST_Closed_Log/1','autorouting','on');

set_param(modelName,'SimulationCommand','update');
save_system(modelName,modelPath);
copyfile(modelPath,fullfile(outDir,[modelName '_trip_semantics_v2.slx']),'f');

% Structural audit only: functional breaker state regression is performed in
% build_trip_breaker_semantics_core without depending on FMU initialization.
report=struct();
report.model=modelName;
report.trip_definition='TRIP_SUCCESS_IFF_ASSOCIATED_BREAKER_CLOSED_FEEDBACK_EQUALS_0';
report.gt_trip_boundary_effect='NONE_DIRECT; GT thermodynamic shutdown adapter is separate';
report.gt_derating=struct('flow_kg_s',150,'temperature_k',550,'control','GT_Derate_CMD', ...
    'classification','DERATING_NOT_TRIP');
report.gt_breaker_feedback='Generator_Breaker_State/52GT_CLOSED -> Protection_Control/cb_52gt_closed_fb';
report.st_breaker_feedback='Generator_Breaker_State/52ST_CLOSED -> Protection_Control/cb_52st_closed_fb';
report.reset_recloses_breaker=false;
report.st_valve_closure='SECONDARY_SHUTDOWN_EFFECT_NOT_TRIP_DEFINITION';
report.referenced_models_path=modelsDir;
report.fmu_path=fullfile(fmuDir,'TripLens_CombinedCycle_TripTAC_CoSim.fmu');
report.structural_pass=true;
report.note=['GT/ST Trip requests still resolve in Common_Trip_Matrix. The breaker actuator latches CLOSED from 1 to 0 when ' ...
    'the delayed breaker trip command operates. The old GT 150/550 path is now controlled only by GT_Derate_CMD.'];
fid=fopen(fullfile(outDir,'trip_semantics_v2_install_report.json'),'w','n','UTF-8'); assert(fid>=0);
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('TRIPLENS INTEGRATED TRIP SEMANTICS V2 STRUCTURAL PASS\n');
fprintf('GT_DERATING_RECLASSIFIED=1\n');
fprintf('GT_52_CLOSED_FEEDBACK_STATEFUL=1\n');
fprintf('ST_52_CLOSED_FEEDBACK_STATEFUL=1\n');
end

function buildGeneratorBreakerState(sub,Ts)
Simulink.SubSystem.deleteContents(sub);
add_block('simulink/Sources/In1',[sub '/52GT_Trip_Cmd'],'Port','1','Position',[20 45 145 65]);
add_block('simulink/Sources/In1',[sub '/52ST_Trip_Cmd'],'Port','2','Position',[20 115 145 135]);
add_block('simulink/Sinks/Out1',[sub '/52GT_CLOSED'],'Port','1','Position',[650 55 780 75]);
add_block('simulink/Sinks/Out1',[sub '/52ST_CLOSED'],'Port','2','Position',[650 135 780 155]);
for k=1:2
    y=45+(k-1)*80;
    add_block('simulink/Discrete/Unit Delay',[sub '/Closed_State_' num2str(k)], ...
        'SampleTime',num2str(Ts),'InitialCondition','1','Position',[420 y 500 y+30]);
    add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/Not_Trip_' num2str(k)], ...
        'Operator','NOT','Position',[190 y 235 y+30]);
    add_block('simulink/Logic and Bit Operations/Logical Operator',[sub '/Latch_Open_' num2str(k)], ...
        'Operator','AND','Inputs','2','Position',[300 y 350 y+35]);
    add_line(sub,sprintf('52%s_Trip_Cmd/1',ternary(k==1,'GT','ST')),['Not_Trip_' num2str(k) '/1'],'autorouting','on');
    add_line(sub,['Not_Trip_' num2str(k) '/1'],['Latch_Open_' num2str(k) '/1'],'autorouting','on');
    add_line(sub,['Closed_State_' num2str(k) '/1'],['Latch_Open_' num2str(k) '/2'],'autorouting','on');
    add_line(sub,['Latch_Open_' num2str(k) '/1'],['Closed_State_' num2str(k) '/1'],'autorouting','on');
end
add_line(sub,'Closed_State_1/1','52GT_CLOSED/1','autorouting','on');
add_line(sub,'Closed_State_2/1','52ST_CLOSED/1','autorouting','on');
set_param(sub,'Description','Generator breaker actuator. Trip latches CLOSED=0. Reset is not a reclose command.');
end

function out=ternary(cond,a,b)
if cond, out=a; else, out=b; end
end

function renameIfPresent(modelName,oldName,newName)
old=[modelName '/' oldName]; new=[modelName '/' newName];
if getSimulinkBlockHandle(old)~=-1
    if getSimulinkBlockHandle(new)~=-1, delete_block(new); cleanDanglingLines(modelName); end
    set_param(old,'Name',newName);
end
end

function pno=portNumber(subsystem,signalName,kind)
block=[subsystem '/' signalName];
assert(getSimulinkBlockHandle(block)~=-1,'TripLens:MissingInterfaceSignal','Missing %s',block);
if strcmp(kind,'Inport'), assert(strcmp(get_param(block,'BlockType'),'Inport')); else, assert(strcmp(get_param(block,'BlockType'),'Outport')); end
pno=str2double(get_param(block,'Port'));
end

function disconnectSubsystemInport(subsystem,index)
ph=get_param(subsystem,'PortHandles'); disconnectPort(ph.Inport(index));
end

function disconnectPort(h)
try
    line=get_param(h,'Line'); if line~=-1, delete_line(line); end
catch
end
end

function tf=sourceDrivesBlock(modelName,sourceName,destName)
tf=false;
try
    ph=get_param([modelName '/' sourceName],'PortHandles');
    l=get_param(ph.Outport(1),'Line');
    if l==-1, return; end
    dst=get_param(l,'DstBlockHandle');
    target=getSimulinkBlockHandle([modelName '/' destName]);
    tf=any(dst==target);
catch
end
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

function safeRmpath(p)
try
    if contains(path,p), rmpath(p); end
catch
end
end
