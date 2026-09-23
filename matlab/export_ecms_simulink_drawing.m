function report = export_ecms_simulink_drawing()
%EXPORT_ECMS_SIMULINK_DRAWING Export the actual Simulink diagram without redrawing it.
% The source .slx/.mdl remains unchanged. The exported SVG/PNG are rendered
% by Simulink itself so block/line geometry matches the model editor.

repoRoot = resolveRepoRoot();
outDir = fullfile(repoRoot,'outputs','simulink_drawing');
if ~isfolder(outDir), mkdir(outDir); end

assert(license('test','Simulink'),'TripLens:SimulinkUnavailable', ...
    'Simulink license is not available on this runner.');

initPath = string(getenv('TRIPLENS_ECMS_INIT_SCRIPT'));
if strlength(initPath)>0
    initPath = resolvePath(initPath,repoRoot);
    assert(isfile(initPath),'TripLens:MissingInitScript','Missing init script: %s',initPath);
    run(char(initPath));
end

[modelName,modelFile,modelDir] = resolveModel(repoRoot);
if strlength(modelDir)>0, addpath(modelDir,'-begin'); end
cleanupPath = onCleanup(@() cleanupModel(modelName,modelDir)); %#ok<NASGU>
if ~bdIsLoaded(modelName), load_system(modelFile); end

% Open only for rendering. Do not arrange, move, save, or mutate blocks/lines.
open_system(modelName);
try, set_param(modelName,'ZoomFactor','FitSystem'); catch, end
drawnow;

svgPath = fullfile(outDir,'TripLens_ECMS_DigitalTwin.svg');
pngPath = fullfile(outDir,'TripLens_ECMS_DigitalTwin.png');

% Simulink's own print path preserves the editor's model geometry.
print(['-s' char(modelName)],'-dsvg',svgPath);
print(['-s' char(modelName)],'-dpng','-r200',pngPath);

assert(isfile(svgPath) && dir(svgPath).bytes>0,'TripLens:SvgExportFailed','SVG export failed.');
assert(isfile(pngPath) && dir(pngPath).bytes>0,'TripLens:PngExportFailed','PNG export failed.');

blocks = find_system(modelName,'SearchDepth',1,'Type','Block');
blockRows = cell(numel(blocks),5);
for k=1:numel(blocks)
    pos = get_param(blocks{k},'Position');
    blockRows{k,1}=get_param(blocks{k},'Name');
    blockRows{k,2}=pos(1); blockRows{k,3}=pos(2); blockRows{k,4}=pos(3); blockRows{k,5}=pos(4);
end
T=cell2table(blockRows,'VariableNames',{'Block','Left','Top','Right','Bottom'});
writetable(T,fullfile(outDir,'top_level_block_positions.csv'));

report=struct();
report.status='PASS';
report.model=char(modelName);
report.model_file=char(modelFile);
report.svg=svgPath;
report.png=pngPath;
report.top_level_blocks=height(T);
report.geometry_source='SIMULINK_NATIVE_RENDER';
report.model_modified=false;
fid=fopen(fullfile(outDir,'export_report.json'),'w');
assert(fid>=0); fwrite(fid,jsonencode(report,'PrettyPrint',true),'char'); fclose(fid);

fprintf('SIMULINK_DRAWING_EXPORT_PASS\n');
fprintf('MODEL=%s\n',modelName);
fprintf('SVG=%s\n',svgPath);
fprintf('PNG=%s\n',pngPath);
end

function [modelName,modelFile,modelDir] = resolveModel(repoRoot)
raw=string(getenv('TRIPLENS_ECMS_MODEL_PATH'));
if strlength(raw)>0
    modelFile=resolvePath(raw,repoRoot);
    assert(isfile(modelFile),'TripLens:MissingLocalFile','ECMS model not found: %s',modelFile);
    [modelDir,modelName,~]=fileparts(modelFile);
    modelName=string(modelName); modelDir=string(modelDir); return;
end

mdrive='';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
candidate=fullfile(mdrive,'TripLens_ECMS_DigitalTwin','TripLens_ECMS_DigitalTwin.slx');
if ~isempty(mdrive) && isfile(candidate)
    modelFile=string(candidate); modelName="TripLens_ECMS_DigitalTwin"; modelDir=string(fileparts(candidate)); return;
end

loaded=find_system('SearchDepth',0,'Type','BlockDiagram');
models=strings(0,1);
for k=1:numel(loaded)
    try
        if strcmp(get_param(loaded{k},'BlockDiagramType'),'model'), models(end+1,1)=string(loaded{k}); end %#ok<AGROW>
    catch
    end
end
models=unique(models);
assert(numel(models)==1,'TripLens:AmbiguousModel','No unique ECMS model could be resolved.');
modelName=models(1); modelFile="<loaded:"+modelName+">"; modelDir="";
end

function path=resolvePath(raw,repoRoot)
path=string(raw);
if ~isfile(path)
    candidate=string(fullfile(repoRoot,path));
    if isfile(candidate), path=candidate; end
end
end

function root=resolveRepoRoot()
raw=getenv('TRIPLENS_COSIM_REPO_ROOT');
if ~isempty(raw) && isfolder(raw), root=raw; else, root=fileparts(fileparts(mfilename('fullpath'))); end
end

function cleanupModel(modelName,modelDir)
try, close_system(modelName,0); catch, end
try, if strlength(modelDir)>0, rmpath(modelDir); end, catch, end
end
