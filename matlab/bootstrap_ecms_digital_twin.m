function bootstrap_ecms_digital_twin()
%BOOTSTRAP_ECMS_DIGITAL_TWIN Create the TripLens ECMS digital-twin shell in MATLAB Drive.
% Idempotent: creates the model once, then only ensures required top-level subsystems exist.

modelName = 'TripLens_ECMS_DigitalTwin';
projectName = 'TripLens_ECMS_DigitalTwin';

% Resolve MATLAB Drive without scanning the machine.
mdrive = '';
try
    if exist('matlabdrive','file') == 2
        mdrive = matlabdrive;
    end
catch
end
if isempty(mdrive)
    candidate = fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate)
        mdrive = candidate;
    end
end
if isempty(mdrive) || ~isfolder(mdrive)
    error('TripLens:MATLABDriveUnavailable', ...
        'MATLAB Drive local folder is not available to this runner session.');
end

projectDir = fullfile(mdrive, projectName);
if ~isfolder(projectDir)
    mkdir(projectDir);
end
modelPath = fullfile(projectDir, [modelName '.slx']);

if bdIsLoaded(modelName)
    close_system(modelName,0);
end

if isfile(modelPath)
    load_system(modelPath);
else
    new_system(modelName);
end

requiredSubsystems = {
    'ECMS_IO',             [60 60 250 145];
    'Electrical_Twin',     [340 60 550 145];
    'Protection_Control',  [640 60 860 145];
    'Thermo_Interface',    [340 230 550 315];
    'Alarm_Output',        [640 230 860 315]
};

for k = 1:size(requiredSubsystems,1)
    blockName = requiredSubsystems{k,1};
    blockPath = [modelName '/' blockName];
    if getSimulinkBlockHandle(blockPath) == -1
        add_block('simulink/Ports & Subsystems/Subsystem', blockPath, ...
            'Position', requiredSubsystems{k,2]);
    end
end

% Annotate interfaces so tag-contract generators can replace placeholders later.
set_param([modelName '/ECMS_IO'],'Description', ...
    'Generated I/O boundary. Final A-program, ECMS and Thermo tag contracts will populate this subsystem.');
set_param([modelName '/Electrical_Twin'],'Description', ...
    'Electrical state solver boundary: bus, breaker, transformer, feeder, V/I/f.');
set_param([modelName '/Protection_Control'],'Description', ...
    'A-program logic migration target: thresholds, delay, latch, permissive, relay/control logic.');
set_param([modelName '/Thermo_Interface'],'Description', ...
    'ThermoSysPro command/state adapter boundary. No synthetic process physics here.');
set_param([modelName '/Alarm_Output'],'Description', ...
    'DCS1/DCS2/ECMS alarm/event export boundary for TripLens.');

set_param(modelName,'SolverType','Fixed-step');
set_param(modelName,'FixedStep','0.1');
set_param(modelName,'StopTime','10');
save_system(modelName,modelPath);
close_system(modelName,0);

% Write a small machine-readable report back to the checked-out repository.
repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot)
    repoRoot = pwd;
end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir)
    mkdir(outDir);
end
report.model = modelName;
report.model_path = modelPath;
report.matlab_drive = mdrive;
report.project_dir = projectDir;
report.created_or_verified = true;
report.placeholder_subsystems = requiredSubsystems(:,1)';
report.logic_loaded = false;
report.thermo_connected = false;
report.electrical_twin_connected = false;
report.note = 'Shell only. Ready for finalized A-program/ECMS/Thermo contracts; no synthetic plant logic inserted.';

fid = fopen(fullfile(outDir,'ecms_digital_twin_bootstrap.json'),'w','n','UTF-8');
cleanupObj = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true));

fprintf('TRIPLENS ECMS DIGITAL TWIN SHELL READY\n');
fprintf('MODEL=%s\n',modelPath);
end
