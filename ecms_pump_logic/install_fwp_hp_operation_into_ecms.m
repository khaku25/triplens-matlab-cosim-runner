function install_fwp_hp_operation_into_ecms()
%INSTALL_FWP_HP_OPERATION_INTO_ECMS Add the verified FWP model visibly to ECMS.
% External electrical and Thermo wiring remains explicitly pending.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end

mdrive=resolveMatlabDrive();
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable', ...
    'MATLAB Drive local folder is unavailable.');
projectDir=fullfile(mdrive,'TripLens_ECMS_DigitalTwin');
mainName='TripLens_ECMS_DigitalTwin';
mainPath=fullfile(projectDir,[mainName '.slx']);
modelsDir=fullfile(projectDir,'models');
coreName='TripLens_ECMS_FWP_HP_Operation_Core';
corePath=fullfile(modelsDir,[coreName '.slx']);
assert(isfile(mainPath),'TripLens:MissingECMSModel','Missing ECMS model: %s',mainPath);
assert(isfile(corePath),'TripLens:MissingFwpCore','Missing FWP operation core: %s',corePath);

addpath(modelsDir,'-begin');
cleanupPath=onCleanup(@()rmpath(modelsDir)); %#ok<NASGU>
if bdIsLoaded(mainName), close_system(mainName,0); end
load_system(mainPath);
cleanupModel=onCleanup(@()close_system(mainName,0)); %#ok<NASGU>

blockPath=[mainName '/FWP_HP_Operation'];
if getSimulinkBlockHandle(blockPath)~=-1
    assert(strcmp(get_param(blockPath,'BlockType'),'ModelReference'), ...
        'TripLens:UnknownFwpBlock','Refusing to replace non-model-reference block %s.',blockPath);
    assert(strcmp(get_param(blockPath,'ModelName'),coreName), ...
        'TripLens:UnknownFwpReference','Refusing to replace unknown referenced model at %s.',blockPath);
else
    add_block('built-in/ModelReference',blockPath,'ModelName',coreName, ...
        'Position',[60 400 330 735]);
end
set_param(blockPath,'ModelName',coreName,'BackgroundColor','lightBlue', ...
    'ForegroundColor','black','FontWeight','bold', ...
    'AttributesFormatString',['FWP-HP START / STOP / TRIP\n' ...
    'VCB-A01 + motor coast-down\nEXT: PENDING COSIM WIRING']);
save_system(mainName,mainPath);

handles=get_param(blockPath,'LineHandles');
externalInputLines=sum(handles.Inport~=-1);
externalOutputLines=sum(handles.Outport~=-1);
pngPath=fullfile(outDir,'ecms_fwp_hp_installed.png');
pngGenerated=false; pngMessage='';
try
    open_system(mainName); set_param(mainName,'ZoomFactor','FitSystem');
    print(['-s' mainName],'-dpng','-r150',pngPath); pngGenerated=isfile(pngPath);
catch imageErr
    pngMessage=imageErr.message;
end

report=struct(); report.installed=true; report.model=mainName;
report.model_path=mainPath; report.block_path=blockPath;
report.referenced_model=coreName; report.referenced_model_path=corePath;
report.external_input_line_count=externalInputLines;
report.external_output_line_count=externalOutputLines;
report.external_physics_bound=(externalInputLines>0 && externalOutputLines>0);
report.integration_status='LOGIC_AND_MECHANISM_INSTALLED_EXTERNAL_COSIM_WIRING_PENDING';
report.normal_stop_policy='KEEP_VCB_A01_CLOSED';
report.trip_policy='OPEN_VCB_A01_AFTER_DELAY_AND_COAST_RPM';
report.reset_policy='CAUSE_CLEAR_RUN_OFF_ZERO_SPEED_BREAKER_OPEN_THEN_MANUAL_RECLOSE';
report.start_policy='START_DOES_NOT_CLOSE_BREAKER';
report.png_generated=pngGenerated; report.png_message=pngMessage;
report.note=['The block is visible and executable as a referenced ECMS model. ' ...
    'External lines remain pending and are not reported as end-to-end co-simulation.'];
fid=fopen(fullfile(outDir,'ecms_fwp_hp_install_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write FWP install report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf(['TRIPLENS FWP-HP OPERATION INSTALLED\nBLOCK=%s\n' ...
    'EXTERNAL_INPUT_LINES=%d\nEXTERNAL_OUTPUT_LINES=%d\nEND_TO_END=%d\n'], ...
    blockPath,externalInputLines,externalOutputLines,report.external_physics_bound);
end

function mdrive=resolveMatlabDrive()
mdrive='';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
end
