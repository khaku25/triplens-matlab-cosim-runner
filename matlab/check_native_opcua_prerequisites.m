function report = check_native_opcua_prerequisites()
%CHECK_NATIVE_OPCUA_PREREQUISITES Verify the real Windows MATLAB ECMS host.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot)
    repoRoot = fileparts(fileparts(mfilename('fullpath')));
end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

report = struct();
report.status = 'STARTED';
report.matlab_release = version('-release');
report.matlab_version = version;
report.simulink_available = ~isempty(ver('simulink'));
report.opcua_function_available = exist('opcua','file') == 2;
report.opcua_read_available = exist('readValue','file') == 2;
report.opcua_write_available = exist('writeValue','file') == 2;
report.industrial_communication_toolbox = ~isempty(ver('icomm'));
report.openmodelica_executable = '';

try
    fprintf('MATLAB_RELEASE=%s\n',report.matlab_release);
    fprintf('SIMULINK_INSTALLED=%d\n',report.simulink_available);
    fprintf('OPCUA_FUNCTION=%d READ=%d WRITE=%d ICOMM=%d\n', ...
        report.opcua_function_available,report.opcua_read_available, ...
        report.opcua_write_available,report.industrial_communication_toolbox);
    fprintf('OPENMODELICA=%s\n',report.openmodelica_executable);
    report.openmodelica_executable = findOpenModelica();
    assert(report.simulink_available, ...
        'TripLens:SimulinkUnavailable','Simulink is not available.');
    assert(report.opcua_function_available && report.opcua_read_available && ...
        report.opcua_write_available, ...
        'TripLens:OPCUAUnavailable', ...
        'MATLAB OPC UA client functions are not available.');
    assert(report.industrial_communication_toolbox, ...
        'TripLens:IndustrialCommunicationToolboxUnavailable', ...
        'Industrial Communication Toolbox is not installed.');
    assert(~isempty(report.openmodelica_executable), ...
        'TripLens:OpenModelicaUnavailable','OpenModelica omc.exe was not found.');

    [modelPath,modelName] = resolveEcmsModel();
    if bdIsLoaded(modelName), close_system(modelName,0); end
    load_system(modelPath);
    cleanup = onCleanup(@() closeIfLoaded(modelName)); %#ok<NASGU>

    blocks = find_system(modelName,'LookUnderMasks','all', ...
        'FollowLinks','on','Type','Block');
    sst = strings(0,1);
    for k = 1:numel(blocks)
        tokens = regexp(upper(blocks{k}),'(^|[/_.-])SST($|[/_.-])','once');
        if ~isempty(tokens), sst(end+1,1) = string(blocks{k}); end %#ok<AGROW>
    end
    assert(isempty(sst),'TripLens:SSTPresent', ...
        'The selected ECMS model contains SST blocks: %s',strjoin(sst,', '));

    required = {'ECMS_IO','Electrical_Twin','Protection_Control', ...
        'Thermo_Interface','Alarm_Output','GT_Trip_CMD'};
    missing = strings(0,1);
    for k = 1:numel(required)
        if getSimulinkBlockHandle([modelName '/' required{k}]) == -1
            missing(end+1,1) = string(required{k}); %#ok<AGROW>
        end
    end
    assert(isempty(missing),'TripLens:ECMSContractMissing', ...
        'Required ECMS blocks are missing: %s',strjoin(missing,', '));

    set_param(modelName,'SimulationCommand','update');
    report.ecms_model = modelName;
    report.ecms_model_file = [modelName '.slx'];
    report.ecms_block_count = numel(blocks);
    report.sst_present = false;
    report.diagram_update_pass = true;
    report.required_blocks = required;
    report.status = 'PASS';
    report.scope = 'REAL_MATLAB_R2025B_ECMS_AND_OPCUA_PREREQUISITES';
    writeJson(fullfile(outDir,'matlab_opcua_prerequisites.json'),report);
    fprintf('MATLAB_NATIVE_OPCUA_PREREQUISITES_PASS\n');
    fprintf('ECMS_MODEL=%s BLOCKS=%d SST=0\n',modelName,numel(blocks));
    fprintf('OPCUA_FUNCTION=%d ICOMM=%d\n', ...
        report.opcua_function_available,report.industrial_communication_toolbox);
catch ME
    report.status = 'FAIL';
    report.error_identifier = ME.identifier;
    report.error_message = ME.message;
    writeJson(fullfile(outDir,'matlab_opcua_prerequisites.json'),report);
    rethrow(ME);
end
end

function [path,name] = resolveEcmsModel()
raw = string(getenv('TRIPLENS_ECMS_MODEL_PATH'));
if strlength(raw) > 0 && isfile(raw)
    path = char(raw);
else
    mdrive = '';
    try
        if exist('matlabdrive','file') == 2, mdrive = matlabdrive; end
    catch
    end
    if isempty(mdrive)
        candidate = fullfile(getenv('USERPROFILE'),'MATLAB Drive');
        if isfolder(candidate), mdrive = candidate; end
    end
    assert(~isempty(mdrive) && isfolder(mdrive), ...
        'TripLens:MATLABDriveUnavailable','MATLAB Drive is unavailable.');
    path = fullfile(mdrive,'TripLens_ECMS_DigitalTwin', ...
        'TripLens_ECMS_DigitalTwin.slx');
end
assert(isfile(path),'TripLens:ECMSModelMissing', ...
    'The actual ECMS model was not found: %s',path);
[~,name] = fileparts(path);
end

function path = findOpenModelica()
path = '';
raw = string(getenv('TRIPLENS_OPENMODELICA_HOME'));
if strlength(raw) > 0
    candidate = fullfile(raw,'bin','omc.exe');
    if isfile(candidate), path = candidate; return; end
end
roots = ["C:\Program Files\OpenModelica*\bin\omc.exe"; ...
    "C:\OpenModelica*\bin\omc.exe"];
for pattern = roots'
    found = dir(pattern);
    if ~isempty(found)
        [~,order] = sort(string({found.folder}),'descend');
        item = found(order(1));
        path = fullfile(item.folder,item.name);
        return;
    end
end
end

function writeJson(path,value)
fid = fopen(path,'w','n','UTF-8');
assert(fid >= 0,'TripLens:WriteFailed','Cannot write %s',path);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(value,'PrettyPrint',true));
end

function closeIfLoaded(modelName)
try
    if bdIsLoaded(modelName), close_system(modelName,0); end
catch
end
end
