function install_a_logic_into_ecms()
%INSTALL_A_LOGIC_INTO_ECMS Install the validated A logic core into ECMS shell.
% Refuses to overwrite an unknown Protection_Control implementation.
% Port lists are read from a_logic_interface_v1.csv so the installed shell
% always follows the validated model-reference interface.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = fileparts(fileparts(mfilename('fullpath'))); end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end
interfacePath = fullfile(repoRoot,'ecms_logic','a_logic_interface_v1.csv');
assert(isfile(interfacePath),'TripLens:MissingInterface','Missing ECMS interface: %s',interfacePath);
T = readtable(interfacePath,'TextType','string','VariableNamingRule','preserve');
inputs = cellstr(T.signal_name(upper(T.direction)=="IN"));
outputs = cellstr(T.signal_name(upper(T.direction)=="OUT"));

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
    'MATLAB Drive local folder is unavailable.');

projectDir = fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
mainName = 'TripLens_ECMS_DigitalTwin';
mainPath = fullfile(projectDir,[mainName '.slx']);
coreName = 'TripLens_ECMS_A_Logic_Core';
corePath = fullfile(projectDir,'models',[coreName '.slx']);
assert(isfile(mainPath),'TripLens:MissingECMSModel','Missing ECMS model: %s',mainPath);
assert(isfile(corePath),'TripLens:MissingLogicCore','Missing logic core: %s',corePath);

addpath(fullfile(projectDir,'models'),'-begin');
cleanupPath = onCleanup(@() rmpath(fullfile(projectDir,'models'))); %#ok<NASGU>
if bdIsLoaded(mainName), close_system(mainName,0); end
load_system(mainPath);
cleanupModel = onCleanup(@() close_system(mainName,0)); %#ok<NASGU>
target = [mainName '/Protection_Control'];
assert(getSimulinkBlockHandle(target) ~= -1,'TripLens:MissingProtectionTarget', ...
    'Protection_Control subsystem does not exist.');

children = find_system(target,'SearchDepth',1,'Type','Block');
children = children(~strcmp(children,target));
childNames = cellfun(@(p)get_param(p,'Name'),children,'UniformOutput',false);
allowed = [{'In1','Out1','A_Logic_Core'}, inputs(:)', outputs(:)'];
unknown = setdiff(childNames,allowed);
assert(isempty(unknown),'TripLens:ProtectionControlNotEmpty', ...
    'Refusing to overwrite unknown blocks in Protection_Control: %s',strjoin(unknown,', '));

lines = find_system(target,'FindAll','on','SearchDepth',1,'Type','line');
if ~isempty(lines), delete_line(lines); end
for k=1:numel(children)
    if getSimulinkBlockHandle(children{k}) ~= -1, delete_block(children{k}); end
end

ref = [target '/A_Logic_Core'];
refHeight = max(735,80+max(numel(inputs),numel(outputs))*48);
add_block('built-in/ModelReference',ref,'ModelName',coreName, ...
    'Position',[500 80 720 refHeight]);
for k=1:numel(inputs)
    y=35+(k-1)*42;
    p=[target '/' inputs{k}];
    add_block('simulink/Sources/In1',p,'Port',num2str(k), ...
        'Position',[25 y 230 y+22]);
    add_line(target,[inputs{k} '/1'],['A_Logic_Core/' num2str(k)],'autorouting','on');
end
for k=1:numel(outputs)
    y=70+(k-1)*72;
    p=[target '/' outputs{k}];
    add_block('simulink/Sinks/Out1',p,'Port',num2str(k), ...
        'Position',[980 y 1220 y+22]);
    add_line(target,['A_Logic_Core/' num2str(k)],[outputs{k} '/1'],'autorouting','on');
end

set_param(target,'Description', ...
    ['Validated A-program logic core v3. Common trip matrix: GT Trip -> ST Trip; ' ...
     'drum HH -> ST only; drum LL -> GT + ST. Layer1 alarms remain separate inputs.']);
set_param(mainName,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','0.001');
save_system(mainName,mainPath);

fmuName = 'TripLens_CombinedCycle_TripTAC_CoSim.fmu';
fmuMatches = dir(fullfile(mdrive,'**',fmuName));
compilePass = false;
compileStatus = 'PENDING_MISSING_COSIM_FMU';
compileMessage = ['Logic installed and saved. Full ECMS compile waits for ' fmuName '.'];
if ~isempty(fmuMatches)
    fmuDir = fmuMatches(1).folder;
    addpath(fmuDir,'-begin');
    cleanupFmuPath = onCleanup(@() rmpath(fmuDir)); %#ok<NASGU>
    try
        set_param(mainName,'SimulationCommand','update');
        compilePass = true;
        compileStatus = 'PASS';
        compileMessage = ['ECMS compile update passed with FMU from ' fmuDir];
    catch compileErr
        compileStatus = 'PENDING_ECMS_DEPENDENCY';
        compileMessage = compileErr.message;
    end
end

report=struct();
report.model=mainName; report.model_path=mainPath;
report.target_subsystem='Protection_Control';
report.referenced_model=coreName; report.referenced_model_path=corePath;
report.interface_file=interfacePath;
report.input_count=numel(inputs); report.output_count=numel(outputs);
report.inputs=inputs; report.outputs=outputs;
report.solver='FixedStepDiscrete'; report.fixed_step_s=0.001;
report.compile_update_pass=compilePass; report.compile_status=compileStatus;
report.compile_message=compileMessage; report.installed=true;
report.fmu_search_name=fmuName; report.fmu_match_count=numel(fmuMatches);
report.install_mode='SAFE_IDEMPOTENT_MODEL_REFERENCE_DYNAMIC_INTERFACE';
report.protection_policy=struct('gt_trip_intertrips_st',true, ...
    'drum_hh_action','ST_ONLY','drum_ll_action','GT_AND_ST');
report.note=['A logic core installed into the ECMS shell. External Layer1 alarm and ' ...
    'Electrical/Thermo source lines remain to be wired during co-simulation integration.'];
reportPath=fullfile(outDir,'ecms_a_logic_install_report.json');
fid=fopen(reportPath,'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write install report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('TRIPLENS A LOGIC INSTALLED INTO ECMS\nMODEL=%s\nTARGET=%s\n',mainPath,target);
end
