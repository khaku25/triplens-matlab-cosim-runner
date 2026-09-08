function build_triptac_cosim_dashboard()
% Build and smoke-test a real Simulink <-> ThermoSysPro FMI 2.0 Co-Simulation path.
% Uses the already validated CombinedCycle_TripTAC FMU artifact and installs it
% into the existing TripLens_ECMS_DigitalTwin model in MATLAB Drive.

modelName = 'TripLens_ECMS_DigitalTwin';
repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = pwd; end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

%% Locate downloaded golden FMU artifact
hits = dir(fullfile(repoRoot,'fmu_artifact','**','TripLens_CombinedCycle_TripTAC_CoSim.fmu'));
assert(~isempty(hits),'TripLens:FMUMissing','Downloaded TripTAC FMU artifact not found.');
fmuSource = fullfile(hits(1).folder,hits(1).name);

%% Resolve MATLAB Drive and project
mdrive = '';
try
    if exist('matlabdrive','file') == 2, mdrive = matlabdrive; end
catch
end
if isempty(mdrive)
    candidate = fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive = candidate; end
end
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable', ...
    'MATLAB Drive local folder is unavailable to the runner.');
projectDir = fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
if ~isfolder(projectDir), mkdir(projectDir); end
fmuDir = fullfile(projectDir,'fmu');
if ~isfolder(fmuDir), mkdir(fmuDir); end
fmuWork = fullfile(fmuDir,'TripLens_CombinedCycle_TripTAC_CoSim.fmu');
copyfile(fmuSource,fmuWork,'f');

%% Inspect FMU payload and compile a Windows binary if needed
inspectDir = fullfile(tempdir,['triplens_fmu_' char(java.util.UUID.randomUUID)]);
mkdir(inspectDir);
unzip(fmuWork,inspectDir);
hasWin64 = isfolder(fullfile(inspectDir,'binaries','win64')) && ...
    ~isempty(dir(fullfile(inspectDir,'binaries','win64','*')));
hasSources = isfolder(fullfile(inspectDir,'sources')) && ...
    ~isempty(dir(fullfile(inspectDir,'sources','*.c')));
rmdir(inspectDir,'s');

compilerName = '';
try
    cc = mex.getCompilerConfigurations('C','Selected');
    if ~isempty(cc), compilerName = cc.Name; end
catch
end

if ~hasWin64
    assert(hasSources,'TripLens:FMUNoWindowsOrSources', ...
        'FMU has no win64 binary and no C sources to compile on Windows.');
    oldDir = pwd;
    cleanupCd = onCleanup(@() cd(oldDir));
    cd(fmuDir);
    fmudialog.compileFMUSources(fmuWork,'FMUMode','Co-Simulation');
    clear cleanupCd;
    cd(oldDir);
end
assert(isfile(fmuWork),'TripLens:FMUCompileMissing','Windows-ready FMU was not generated.');

% Verify win64 exists after optional compilation.
inspectDir = fullfile(tempdir,['triplens_fmu_' char(java.util.UUID.randomUUID)]);
mkdir(inspectDir); unzip(fmuWork,inspectDir);
winFiles = dir(fullfile(inspectDir,'binaries','win64','*'));
hasWin64After = ~isempty(winFiles);
rmdir(inspectDir,'s');
assert(hasWin64After,'TripLens:FMUWin64Missing','FMU still has no win64 binary after preparation.');

%% Load/create existing ECMS shell and keep one pre-co-sim backup
modelPath = fullfile(projectDir,[modelName '.slx']);
if bdIsLoaded(modelName), close_system(modelName,0); end
if isfile(modelPath)
    backupPath = fullfile(projectDir,[modelName '_pre_cosim_backup.slx']);
    if ~isfile(backupPath), copyfile(modelPath,backupPath); end
    load_system(modelPath);
else
    new_system(modelName);
end
ensureSubsystem(modelName,'ECMS_IO',[60 60 250 145]);
ensureSubsystem(modelName,'Electrical_Twin',[340 60 550 145]);
ensureSubsystem(modelName,'Protection_Control',[640 60 860 145]);
ensureSubsystem(modelName,'Thermo_Interface',[470 390 690 610]);
ensureSubsystem(modelName,'Alarm_Output',[640 230 860 315]);

%% Replace only an untouched placeholder Thermo_Interface, or our own prior build
thermoSub = [modelName '/Thermo_Interface'];
children = find_system(thermoSub,'SearchDepth',1,'Type','Block');
childNames = string(get_param(children,'Name'));
known = all(ismember(childNames,["Thermo_Interface","In1","Out1","GT_Exhaust_Flow","GT_Exhaust_Temperature", ...
    "Thermo_FMU","ST_Electrical_Power","HP_Drum_Level","IP_Drum_Level","LP_Drum_Level", ...
    "HP_Drum_Pressure","IP_Drum_Pressure","LP_Drum_Pressure"]));
assert(known,'TripLens:ThermoInterfaceNotPlaceholder', ...
    'Thermo_Interface contains unknown user logic; refusing to overwrite it.');
Simulink.SubSystem.deleteContents(thermoSub);

add_block('simulink/Ports & Subsystems/In1',[thermoSub '/GT_Exhaust_Flow'], ...
    'Port','1','Position',[30 70 60 90]);
add_block('simulink/Ports & Subsystems/In1',[thermoSub '/GT_Exhaust_Temperature'], ...
    'Port','2','Position',[30 130 60 150]);
load_system('simulink_extras');
fmuBlock = [thermoSub '/Thermo_FMU'];
add_block('simulink_extras/FMU Import/FMU',fmuBlock,'Position',[150 45 470 360]);
set_param(fmuBlock,'FMUName',fmuWork,'FMUInputMapping','Flat','FMUOutputMapping','Flat', ...
    'FMUSampleTime','0.1');
set_param(modelName,'SimulationCommand','update');
ph = get_param(fmuBlock,'PortHandles');
assert(numel(ph.Inport)==2,'TripLens:FMUInputCount','Expected 2 FMU input ports, got %d.',numel(ph.Inport));
assert(numel(ph.Outport)>=7,'TripLens:FMUOutputCount','Expected >=7 FMU output ports, got %d.',numel(ph.Outport));

outNames = {'ST_Electrical_Power','HP_Drum_Level','IP_Drum_Level','LP_Drum_Level', ...
            'HP_Drum_Pressure','IP_Drum_Pressure','LP_Drum_Pressure'};
for k = 1:7
    y = 30 + k*45;
    add_block('simulink/Ports & Subsystems/Out1',[thermoSub '/' outNames{k}], ...
        'Port',num2str(k),'Position',[560 y 590 y+20]);
    add_line(thermoSub,sprintf('Thermo_FMU/%d',k),[outNames{k} '/1'],'autorouting','on');
end
add_line(thermoSub,'GT_Exhaust_Flow/1','Thermo_FMU/1','autorouting','on');
add_line(thermoSub,'GT_Exhaust_Temperature/1','Thermo_FMU/2','autorouting','on');

%% Remove only prior generated top-level control/dashboard blocks
owned = {'GT_Flow_SP','GT_Temp_SP','GT_Trip_CMD','GT_Trip_Flow','GT_Trip_Temp', ...
    'GT_Flow_Select','GT_Temp_Select','ST_MW','HP_Level','IP_Level','LP_Level', ...
    'HP_Pressure_MPa','IP_Pressure_MPa','LP_Pressure_MPa','ST_MW_Display', ...
    'HP_Level_Display','IP_Level_Display','LP_Level_Display','HP_Pressure_Display', ...
    'IP_Pressure_Display','LP_Pressure_Display','ST_MW_Log','HP_Level_Log', ...
    'GT Flow Control','GT Temp Control','GT TRIP','TRIP Lamp','Thermo Response Scope'};
for i=1:numel(owned)
    p = [modelName '/' owned{i}];
    if getSimulinkBlockHandle(p) ~= -1
        delete_block(p);
    end
end
% Delete generated lines that are no longer connected after block removal.
try
    ls = find_system(modelName,'FindAll','on','SearchDepth',1,'Type','line');
    for h = reshape(ls,1,[])
        if get_param(h,'SrcPortHandle') == -1 || any(get_param(h,'DstPortHandle') == -1)
            delete_line(h);
        end
    end
catch
end

%% Real operator setpoints and trip selection
add_block('simulink/Sources/Constant',[modelName '/GT_Flow_SP'],'Value','606.94','Position',[40 430 120 460]);
add_block('simulink/Sources/Constant',[modelName '/GT_Temp_SP'],'Value','893.75','Position',[40 500 120 530]);
add_block('simulink/Sources/Constant',[modelName '/GT_Trip_CMD'],'Value','0','Position',[40 570 120 600]);
add_block('simulink/Sources/Constant',[modelName '/GT_Trip_Flow'],'Value','150','Position',[170 405 240 435]);
add_block('simulink/Sources/Constant',[modelName '/GT_Trip_Temp'],'Value','550','Position',[170 535 240 565]);
add_block('simulink/Signal Routing/Switch',[modelName '/GT_Flow_Select'],'Threshold','0.5','Position',[300 420 350 475]);
add_block('simulink/Signal Routing/Switch',[modelName '/GT_Temp_Select'],'Threshold','0.5','Position',[300 510 350 565]);

add_line(modelName,'GT_Trip_Flow/1','GT_Flow_Select/1','autorouting','on');
add_line(modelName,'GT_Trip_CMD/1','GT_Flow_Select/2','autorouting','on');
add_line(modelName,'GT_Flow_SP/1','GT_Flow_Select/3','autorouting','on');
add_line(modelName,'GT_Trip_Temp/1','GT_Temp_Select/1','autorouting','on');
add_line(modelName,'GT_Trip_CMD/1','GT_Temp_Select/2','autorouting','on');
add_line(modelName,'GT_Temp_SP/1','GT_Temp_Select/3','autorouting','on');
add_line(modelName,'GT_Flow_Select/1','Thermo_Interface/1','autorouting','on');
add_line(modelName,'GT_Temp_Select/1','Thermo_Interface/2','autorouting','on');

%% Engineering-unit output channels
scaleNames = {'ST_MW','HP_Level','IP_Level','LP_Level','HP_Pressure_MPa','IP_Pressure_MPa','LP_Pressure_MPa'};
gains = {'1e-6','1','1','1','1e-6','1e-6','1e-6'};
for k=1:7
    y = 390 + (k-1)*48;
    add_block('simulink/Math Operations/Gain',[modelName '/' scaleNames{k}], ...
        'Gain',gains{k},'Position',[760 y 830 y+28]);
    add_line(modelName,sprintf('Thermo_Interface/%d',k),[scaleNames{k} '/1'],'autorouting','on');
end

dispNames = {'ST_MW_Display','HP_Level_Display','IP_Level_Display','LP_Level_Display', ...
             'HP_Pressure_Display','IP_Pressure_Display','LP_Pressure_Display'};
for k=1:7
    y = 390 + (k-1)*48;
    add_block('simulink/Sinks/Display',[modelName '/' dispNames{k}], ...
        'Position',[900 y 1010 y+32]);
    add_line(modelName,[scaleNames{k} '/1'],[dispNames{k} '/1'],'autorouting','on');
end

% Two channels used by the CI smoke report.
add_block('simulink/Sinks/To Workspace',[modelName '/ST_MW_Log'], ...
    'VariableName','st_mw_log','SaveFormat','Structure With Time','Position',[1060 390 1160 420]);
add_block('simulink/Sinks/To Workspace',[modelName '/HP_Level_Log'], ...
    'VariableName','hp_level_log','SaveFormat','Structure With Time','Position',[1060 438 1160 468]);
add_line(modelName,'ST_MW/1','ST_MW_Log/1','autorouting','on');
add_line(modelName,'HP_Level/1','HP_Level_Log/1','autorouting','on');

%% Dashboard: actual tunable controls and live signal displays
load_system('simulink_hmi_blocks');
flowSlider = [modelName '/GT Flow Control'];
add_block('simulink_hmi_blocks/Slider',flowSlider,'Position',[40 700 270 820]);
bindParameter(flowSlider,[modelName '/GT_Flow_SP'],'Value');
set_param(flowSlider,'Limits',[50 50 650]);

tempSlider = [modelName '/GT Temp Control'];
add_block('simulink_hmi_blocks/Slider',tempSlider,'Position',[300 700 530 820]);
bindParameter(tempSlider,[modelName '/GT_Temp_SP'],'Value');
set_param(tempSlider,'Limits',[423 50 923]);

tripControl = [modelName '/GT TRIP'];
try
    add_block('simulink_hmi_blocks/Toggle Switch',tripControl,'Position',[560 700 680 820]);
catch
    add_block('simulink_hmi_blocks/Slider',tripControl,'Position',[560 700 680 820]);
    set_param(tripControl,'Limits',[0 1 1]);
end
bindParameter(tripControl,[modelName '/GT_Trip_CMD'],'Value');

lamp = [modelName '/TRIP Lamp'];
add_block('simulink_hmi_blocks/Lamp',lamp,'Position',[710 715 800 805]);
bindSignal(lamp,[modelName '/GT_Trip_CMD'],1);
try
    s1.Value = 0; s1.Color = [0.25 0.25 0.25];
    s2.Value = 1; s2.Color = [1 0 0];
    set_param(lamp,'StateColors',[s1 s2]);
catch
end

scope = [modelName '/Thermo Response Scope'];
add_block('simulink_hmi_blocks/Dashboard Scope',scope,'Position',[830 680 1180 900]);
specs = cell(1,4);
for k=1:4
    specs{k} = Simulink.HMI.SignalSpecification;
    specs{k}.BlockPath = Simulink.BlockPath([modelName '/' scaleNames{k}]);
    specs{k}.OutputPortIndex = 1;
end
set_param(scope,'Binding',specs);

try
    a = Simulink.Annotation(modelName,'TRIPLENS ECMS DIGITAL TWIN - LIVE THERMO CONTROL');
    a.Position = [40 350 520 380];
    a.FontSize = 16; a.FontWeight = 'bold';
catch
end

set_param(modelName,'SolverType','Fixed-step','FixedStep','0.1','StopTime','0.2');
set_param(modelName,'SimulationMode','normal');
set_param(modelName,'SimulationCommand','update');
save_system(modelName,modelPath);

%% Actual Windows Simulink <-> FMU smoke execution
simOut = sim(modelName,'ReturnWorkspaceOutputs','on');
st = simOut.get('st_mw_log');
hp = simOut.get('hp_level_log');
assert(~isempty(st) && ~isempty(st.signals.values),'TripLens:NoSTOutput','No ST output returned from FMU.');
assert(~isempty(hp) && ~isempty(hp.signals.values),'TripLens:NoHPOutput','No HP drum output returned from FMU.');
finalST = st.signals.values(end);
finalHP = hp.signals.values(end);
assert(isfinite(finalST) && isfinite(finalHP),'TripLens:NonFiniteFMUOutput','FMU returned non-finite outputs.');

% Save again with dashboard ready for interactive operation.
set_param(modelName,'StopTime','1000');
save_system(modelName,modelPath);

report = struct();
report.model = modelName;
report.model_path = modelPath;
report.fmu_path = fmuWork;
report.fmi = '2.0 Co-Simulation';
report.windows_binary = true;
report.fmu_sources_present_in_original_artifact = hasSources;
report.compiler = compilerName;
report.communication_step_s = 0.1;
report.input_ports = numel(ph.Inport);
report.output_ports = numel(ph.Outport);
report.simulink_smoke_pass = true;
report.final_st_mw_at_0p2s = finalST;
report.final_hp_drum_level_at_0p2s = finalHP;
report.dashboard_controls = {'GT Flow Control','GT Temp Control','GT TRIP'};
report.dashboard_displays = {'TRIP Lamp','Thermo Response Scope','ST/Drum/Pressure numeric displays'};
report.note = 'Real FMU Import smoke passed on Windows MATLAB/Simulink. Dashboard controls are bound to real setpoint/trip parameters.';

fid = fopen(fullfile(outDir,'triptac_cosim_dashboard_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write co-sim report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
copyfile(modelPath,fullfile(outDir,[modelName '.slx']),'f');

fprintf('TRIPLENS SIMULINK <-> THERMO FMU SMOKE PASS\n');
fprintf('MODEL=%s\n',modelPath);
fprintf('FMU=%s\n',fmuWork);
fprintf('STEP=0.1 s\n');
fprintf('ST_MW@0.2s=%.9g\n',finalST);
fprintf('HP_LEVEL@0.2s=%.9g\n',finalHP);
close_system(modelName,0);
end

function ensureSubsystem(modelName,blockName,position)
blockPath = [modelName '/' blockName];
if getSimulinkBlockHandle(blockPath) == -1
    add_block('simulink/Ports & Subsystems/Subsystem',blockPath,'Position',position);
else
    set_param(blockPath,'Position',position);
end
end

function bindParameter(dashboardBlock,targetBlock,paramName)
p = Simulink.HMI.ParamSourceInfo;
p.BlockPath = Simulink.BlockPath(targetBlock);
p.ParamName = paramName;
set_param(dashboardBlock,'Binding',p);
end

function bindSignal(dashboardBlock,sourceBlock,portIndex)
s = Simulink.HMI.SignalSpecification;
s.BlockPath = Simulink.BlockPath(sourceBlock);
s.OutputPortIndex = portIndex;
set_param(dashboardBlock,'Binding',s);
end
