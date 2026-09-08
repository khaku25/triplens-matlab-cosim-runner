function install_a_logic_into_ecms()
%INSTALL_A_LOGIC_INTO_ECMS Install the validated A logic core into ECMS shell.
% Refuses to overwrite an unknown Protection_Control implementation.

repoRoot = getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot = fileparts(fileparts(mfilename('fullpath'))); end
outDir = fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

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
allowed = {'In1','Out1','A_Logic_Core', ...
    'gt_trip_cmd','relay_86gt_healthy','cb_52gt_reset_cmd','cb_52gt_closed_fb', ...
    'bus_a_voltage_kv','bus_b_voltage_kv','bus_a_native_live','bus_b_native_live', ...
    'bus_a_fault_active','bus_b_fault_active','stg_power_mw','auto_bus_tie_enable', ...
    'allow_source_parallel','relay_86gt_trip_received','relay_86gt_operated', ...
    'cb_52gt_trip_cmd','bus_a_27uv_operate','bus_b_27uv_operate', ...
    'cb_tie_ab_auto_close_permissive','stg_low_state'};
unknown = setdiff(childNames,allowed);
assert(isempty(unknown),'TripLens:ProtectionControlNotEmpty', ...
    'Refusing to overwrite unknown blocks in Protection_Control: %s',strjoin(unknown,', '));

lines = find_system(target,'FindAll','on','SearchDepth',1,'Type','line');
if ~isempty(lines), delete_line(lines); end
for k=1:numel(children)
    if getSimulinkBlockHandle(children{k}) ~= -1, delete_block(children{k}); end
end

inputs = {'gt_trip_cmd','relay_86gt_healthy','cb_52gt_reset_cmd', ...
    'cb_52gt_closed_fb','bus_a_voltage_kv','bus_b_voltage_kv', ...
    'bus_a_native_live','bus_b_native_live','bus_a_fault_active', ...
    'bus_b_fault_active','stg_power_mw','auto_bus_tie_enable', ...
    'allow_source_parallel'};
outputs = {'relay_86gt_trip_received','relay_86gt_operated', ...
    'cb_52gt_trip_cmd','bus_a_27uv_operate','bus_b_27uv_operate', ...
    'cb_tie_ab_auto_close_permissive','stg_low_state'};

ref = [target '/A_Logic_Core'];
add_block('built-in/ModelReference',ref,'ModelName',coreName, ...
    'Position',[470 80 680 735]);
for k=1:numel(inputs)
    y=35+(k-1)*55;
    p=[target '/' inputs{k}];
    add_block('simulink/Sources/In1',p,'Port',num2str(k), ...
        'Position',[25 y 205 y+22]);
    add_line(target,[inputs{k} '/1'],['A_Logic_Core/' num2str(k)],'autorouting','on');
end
for k=1:numel(outputs)
    y=70+(k-1)*105;
    p=[target '/' outputs{k}];
    add_block('simulink/Sinks/Out1',p,'Port',num2str(k), ...
        'Position',[940 y 1170 y+22]);
    add_line(target,['A_Logic_Core/' num2str(k)],[outputs{k} '/1'],'autorouting','on');
end

set_param(target,'Description', ...
    'Validated A-program logic core v2. Absolute kV/MW inputs; model-calibrated, not plant-approved.');
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
report.input_count=numel(inputs); report.output_count=numel(outputs);
report.inputs=inputs; report.outputs=outputs;
report.solver='FixedStepDiscrete'; report.fixed_step_s=0.001;
report.compile_update_pass=compilePass; report.compile_status=compileStatus;
report.compile_message=compileMessage; report.installed=true;
report.fmu_search_name=fmuName; report.fmu_match_count=numel(fmuMatches);
report.install_mode='SAFE_IDEMPOTENT_MODEL_REFERENCE';
report.note=['A logic core installed into the ECMS shell. External Electrical/Thermo ' ...
    'signals remain to be wired during co-simulation integration.'];
reportPath=fullfile(outDir,'ecms_a_logic_install_report.json');
fid=fopen(reportPath,'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write install report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('TRIPLENS A LOGIC INSTALLED INTO ECMS\nMODEL=%s\nTARGET=%s\n',mainPath,target);
end
