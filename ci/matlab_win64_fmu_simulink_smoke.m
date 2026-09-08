function matlab_win64_fmu_simulink_smoke()
% Import the already Windows-compiled TripTAC FMI 2.0 Co-Simulation FMU
% into Simulink and execute a short physical smoke simulation.

repo = getenv('GITHUB_WORKSPACE');
if isempty(repo), repo = pwd; end

hits = dir(fullfile(repo,'fmu_artifact','**','TripLens_CombinedCycle_TripTAC_CoSim_win64.fmu'));
assert(~isempty(hits),'TripLens:Win64FMUMissing','Windows-ready TripTAC FMU artifact not found.');
fmu = fullfile(hits(1).folder,hits(1).name);
disp("SIMULINK_INPUT_FMU=" + string(fmu));

outDir = fullfile(repo,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

% Verify this is really a Windows binary FMU before asking Simulink to load it.
inspectDir = fullfile(outDir,'win64_fmu_inspect');
if isfolder(inspectDir), rmdir(inspectDir,'s'); end
mkdir(inspectDir);
unzip(fmu,inspectDir);
dlls = dir(fullfile(inspectDir,'binaries','win64','*.dll'));
assert(~isempty(dlls),'TripLens:NoWin64DLL','FMU does not contain binaries/win64 DLL.');
disp("SIMULINK_FMU_DLL=" + string(dlls(1).name));
rmdir(inspectDir,'s');

% The FMU Import block does not accept an absolute FMUName path. Put the
% artifact directory on the current MATLAB path and pass only the file name.
fmuFolder = fileparts(fmu);
[~,fmuStem,fmuExt] = fileparts(fmu);
fmuName = [fmuStem fmuExt];
addpath(fmuFolder);
pathCleanup = onCleanup(@() rmpath(fmuFolder)); %#ok<NASGU>
disp("SIMULINK_FMU_PATH_ADDED=" + string(fmuFolder));
disp("SIMULINK_FMU_NAME=" + string(fmuName));

mdl = 'TripLens_TripTAC_FMU_Smoke';
if bdIsLoaded(mdl), bdclose(mdl); end
new_system(mdl);
cleanupObj = onCleanup(@() localCloseModel(mdl)); %#ok<NASGU>

add_block('simulink/Sources/Constant',[mdl '/GT_Flow'], ...
    'Value','606.94','Position',[30 70 100 100]);
add_block('simulink/Sources/Constant',[mdl '/GT_Temperature'], ...
    'Value','893.75','Position',[30 145 100 175]);

add_block('simulink_extras/FMU Import/FMU',[mdl '/Thermo_FMU'], ...
    'FMUName',fmuName,'Position',[190 45 510 285]);
set_param([mdl '/Thermo_FMU'],'FMUInputMapping','Flat','FMUOutputMapping','Flat');

ph = get_param([mdl '/Thermo_FMU'],'PortHandles');
disp("SIMULINK_FMU_INPUT_PORTS=" + string(numel(ph.Inport)));
disp("SIMULINK_FMU_OUTPUT_PORTS=" + string(numel(ph.Outport)));
assert(numel(ph.Inport)==2,'TripLens:FMUInputCount', ...
    'Expected exactly two TripTAC FMU inputs.');
assert(numel(ph.Outport)>=7,'TripLens:FMUOutputCount', ...
    'Expected at least seven TripTAC FMU outputs.');

add_line(mdl,'GT_Flow/1','Thermo_FMU/1','autorouting','on');
add_line(mdl,'GT_Temperature/1','Thermo_FMU/2','autorouting','on');

% The wrapper declares these as the first two RealOutputs:
% 1=stElectricalPower, 2=hpDrumLevel.
add_block('simulink/Sinks/To Workspace',[mdl '/ST_Power_Out'], ...
    'VariableName','stElectricalPower_out','SaveFormat','Array', ...
    'Position',[590 65 710 95]);
add_block('simulink/Sinks/To Workspace',[mdl '/HP_Drum_Level_Out'], ...
    'VariableName','hpDrumLevel_out','SaveFormat','Array', ...
    'Position',[590 125 710 155]);
add_line(mdl,'Thermo_FMU/1','ST_Power_Out/1','autorouting','on');
add_line(mdl,'Thermo_FMU/2','HP_Drum_Level_Out/1','autorouting','on');

set_param(mdl, ...
    'SolverType','Fixed-step', ...
    'Solver','FixedStepDiscrete', ...
    'FixedStep','0.1', ...
    'StopTime','0.2');

slxPath = fullfile(outDir,[mdl '.slx']);
save_system(mdl,slxPath);
disp("SIMULINK_MODEL_SAVED=" + string(slxPath));

simOut = sim(mdl,'ReturnWorkspaceOutputs','on');
st = simOut.get('stElectricalPower_out');
hp = simOut.get('hpDrumLevel_out');
assert(~isempty(st),'TripLens:NoSTPower','No ST electrical power output returned from FMU.');
assert(~isempty(hp),'TripLens:NoHPLevel','No HP drum-level output returned from FMU.');
assert(all(isfinite(st(:))),'TripLens:BadSTPower','ST electrical power contains non-finite values.');
assert(all(isfinite(hp(:))),'TripLens:BadHPLevel','HP drum level contains non-finite values.');

disp("ST_POWER_FIRST=" + string(st(1)));
disp("ST_POWER_LAST=" + string(st(end)));
disp("HP_DRUM_LEVEL_FIRST=" + string(hp(1)));
disp("HP_DRUM_LEVEL_LAST=" + string(hp(end)));

reportPath = fullfile(outDir,'triptac_win64_fmu_simulink_smoke.txt');
fid = fopen(reportPath,'w');
assert(fid>=0,'TripLens:ReportOpen','Could not open smoke report output.');
fprintf(fid,'SIMULINK WIN64 FMU SMOKE PASS\n');
fprintf(fid,'inputs=%d\n',numel(ph.Inport));
fprintf(fid,'outputs=%d\n',numel(ph.Outport));
fprintf(fid,'st_power_first=%.17g\n',st(1));
fprintf(fid,'st_power_last=%.17g\n',st(end));
fprintf(fid,'hp_drum_level_first=%.17g\n',hp(1));
fprintf(fid,'hp_drum_level_last=%.17g\n',hp(end));
fclose(fid);

disp('SIMULINK WIN64 FMU SMOKE PASS');
bdclose(mdl);
end

function localCloseModel(mdl)
if bdIsLoaded(mdl)
    bdclose(mdl);
end
end
