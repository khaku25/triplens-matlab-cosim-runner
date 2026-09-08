function bootstrap_ecms_digital_twin()
% Create/verify TripLens ECMS digital-twin shell in MATLAB Drive.

modelName = 'TripLens_ECMS_DigitalTwin';
projectName = 'TripLens_ECMS_DigitalTwin';

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

projectDir = fullfile(mdrive,projectName);
if ~isfolder(projectDir)
    mkdir(projectDir);
end
modelPath = fullfile(projectDir,[modelName '.slx']);

if bdIsLoaded(modelName)
    close_system(modelName,0);
end
if isfile(modelPath)
    load_system(modelPath);
else
    new_system(modelName);
end

ensureSubsystem(modelName,'ECMS_IO',[60 60 250 145]);
ensureSubsystem(modelName,'Electrical_Twin',[340 60 550 145]);
ensureSubsystem(modelName,'Protection_Control',[640 60 860 145]);
ensureSubsystem(modelName,'Thermo_Interface',[340 230 550 315]);
ensureSubsystem(modelName,'Alarm_Output',[640 230 860 315]);

set_param(strcat(modelName,'/ECMS_IO'),'Description', ...
    'Generated I/O boundary for finalized A-program, ECMS and Thermo tag contracts.');
set_param(strcat(modelName,'/Electrical_Twin'),'Description', ...
    'Electrical state solver boundary: bus, breaker, transformer, feeder, V/I/f.');
set_param(strcat(modelName,'/Protection_Control'),'Description', ...
    'A-program logic migration target: threshold, delay, latch, permissive and protection/control logic.');
set_param(strcat(modelName,'/Thermo_Interface'),'Description', ...
    'ThermoSysPro command/state adapter boundary. No synthetic process physics.');
set_param(strcat(modelName,'/Alarm_Output'),'Description', ...
    'DCS1/DCS2/ECMS alarm and event export boundary for TripLens.');

set_param(modelName,'SolverType','Fixed-step');
set_param(modelName,'FixedStep','0.1');
set_param(modelName,'StopTime','10');
save_system(modelName,modelPath);
close_system(modelName,0);

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot)
    repoRoot = pwd;
end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir)
    mkdir(outDir);
end

report = struct();
report.model = modelName;
report.model_path = modelPath;
report.matlab_drive = mdrive;
report.project_dir = projectDir;
report.created_or_verified = true;
report.placeholder_subsystems = {'ECMS_IO','Electrical_Twin','Protection_Control','Thermo_Interface','Alarm_Output'};
report.logic_loaded = false;
report.thermo_connected = false;
report.electrical_twin_connected = false;
report.note = 'Shell only. Ready for finalized A-program/ECMS/Thermo contracts; no synthetic plant logic inserted.';

reportPath = fullfile(outDir,'ecms_digital_twin_bootstrap.json');
fid = fopen(reportPath,'w','n','UTF-8');
if fid < 0
    error('TripLens:ReportWriteFailed','Could not write bootstrap report.');
end
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true));
fclose(fid);

fprintf('TRIPLENS ECMS DIGITAL TWIN SHELL READY\n');
fprintf('MODEL=%s\n',modelPath);
end

function ensureSubsystem(modelName,blockName,position)
blockPath = strcat(modelName,'/',blockName);
if getSimulinkBlockHandle(blockPath) == -1
    add_block('simulink/Ports & Subsystems/Subsystem',blockPath,'Position',position);
end
end
