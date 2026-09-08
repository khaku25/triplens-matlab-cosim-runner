function report = run_ecms_simulink(varargin)
%RUN_ECMS_SIMULINK Inspect or execute the local ECMS/VVP Simulink model.
%
% The model stays on the self-hosted runner. Set TRIPLENS_ECMS_MODEL_PATH
% to an absolute .slx/.mdl path, or place exactly one model under ecms/.
% TRIPLENS_ECMS_INIT_SCRIPT may point to an optional initialization script.
% TRIPLENS_ECMS_STOP_TIME optionally overrides the model stop time.

p = inputParser;
addParameter(p,"InventoryOnly",true,@(x)islogical(x)&&isscalar(x));
parse(p,varargin{:});
inventoryOnly = p.Results.InventoryOnly;

repoRoot = resolveRepoRoot();
outDir = fullfile(repoRoot,"outputs");
if ~isfolder(outDir), mkdir(outDir); end

report = struct;
report.Timestamp = char(datetime("now","Format","yyyy-MM-dd'T'HH:mm:ssXXX"));
report.Status = "STARTED";
report.Mode = ternary(inventoryOnly,"INVENTORY","SIMULATE");

try
    assert(license("test","Simulink"), ...
        "TripLens:SimulinkUnavailable","A Simulink license is not available on this runner.");

    modelPath = resolveLocalFile("TRIPLENS_ECMS_MODEL_PATH",repoRoot,["*.slx","*.mdl"],"ECMS model");
    [modelDir,modelName,modelExt] = fileparts(modelPath);
    addpath(modelDir,"-begin");
    pathCleanup = onCleanup(@() rmpath(modelDir)); %#ok<NASGU>

    initPath = string(getenv("TRIPLENS_ECMS_INIT_SCRIPT"));
    if strlength(initPath)>0
        initPath = resolvePath(initPath,repoRoot);
        assert(isfile(initPath),"TripLens:MissingInitScript", ...
            "ECMS initialization script not found: %s",initPath);
        escapedInit = replace(initPath,"'","''");
        evalin("base","run('" + escapedInit + "')");
        [~,initName,initExt] = fileparts(initPath);
        report.InitScript = char(initName + initExt);
    else
        report.InitScript = "";
    end

    load_system(modelName);
    modelCleanup = onCleanup(@() close_system(modelName,0)); %#ok<NASGU>

    blocks = find_system(modelName,"LookUnderMasks","all","FollowLinks","on","Type","Block");
    inports = find_system(modelName,"SearchDepth",1,"BlockType","Inport");
    outports = find_system(modelName,"SearchDepth",1,"BlockType","Outport");

    report.ModelFile = char(modelName + modelExt);
    report.ModelName = char(modelName);
    report.SolverType = get_param(modelName,"SolverType");
    report.Solver = get_param(modelName,"Solver");
    report.ConfiguredStopTime = get_param(modelName,"StopTime");
    report.BlockCount = numel(blocks);
    report.RootInports = blockNames(inports);
    report.RootOutports = blockNames(outports);
    report.InventoryOnly = inventoryOnly;

    if inventoryOnly
        report.Status = "PASS";
        report.Message = "ECMS model loaded and inventoried without simulation.";
        writeJson(fullfile(outDir,"ecms_inventory.json"),report);
        fprintf("ECMS INVENTORY PASS: %s, blocks=%d\n",modelName,report.BlockCount);
        return;
    end

    simIn = Simulink.SimulationInput(modelName);
    stopTime = string(getenv("TRIPLENS_ECMS_STOP_TIME"));
    if strlength(stopTime)>0
        stopValue = str2double(stopTime);
        assert(isfinite(stopValue)&&stopValue>0,"TripLens:BadStopTime", ...
            "TRIPLENS_ECMS_STOP_TIME must be a positive number.");
        simIn = simIn.setModelParameter("StopTime",char(stopTime));
        report.RequestedStopTime = stopValue;
    else
        report.RequestedStopTime = [];
    end

    started = tic;
    simOut = sim(simIn);
    report.ElapsedSeconds = toc(started);
    report.OutputVariables = simulationOutputNames(simOut);
    save(fullfile(outDir,"ecms_simulation_output.mat"),"simOut","-v7.3");

    report.Status = "PASS";
    report.Message = "ECMS Simulink model completed non-interactively.";
    writeJson(fullfile(outDir,"ecms_simulation_report.json"),report);
    fprintf("ECMS SIMULATION PASS: %s, elapsed=%.3f s\n",modelName,report.ElapsedSeconds);
catch ME
    report.Status = "FAIL";
    report.ErrorIdentifier = ME.identifier;
    report.ErrorMessage = ME.message;
    writeJson(fullfile(outDir,"ecms_failure_report.json"),report);
    rethrow(ME);
end
end

function modelPath = resolveLocalFile(envName,repoRoot,patterns,label)
raw = string(getenv(envName));
if strlength(raw)>0
    modelPath = resolvePath(raw,repoRoot);
    assert(isfile(modelPath),"TripLens:MissingLocalFile","%s not found: %s",label,modelPath);
    return;
end

folder = fullfile(repoRoot,"ecms");
matches = struct([]);
for pattern = patterns
    found = dir(fullfile(folder,pattern));
    if isempty(matches), matches = found; else, matches = [matches; found]; end %#ok<AGROW>
end
assert(numel(matches)==1,"TripLens:AmbiguousModel", ...
    "Set %s, or place exactly one .slx/.mdl file under %s. Found %d.", ...
    envName,folder,numel(matches));
modelPath = string(fullfile(matches(1).folder,matches(1).name));
end

function path = resolvePath(raw,repoRoot)
path = string(raw);
if ~isfile(path)
    candidate = string(fullfile(repoRoot,path));
    if isfile(candidate), path = candidate; end
end
end

function names = blockNames(blocks)
names = cell(size(blocks));
for k=1:numel(blocks), names{k}=get_param(blocks{k},"Name"); end
end

function names = simulationOutputNames(simOut)
try
    names = who(simOut);
catch
    names = {};
end
end

function root = resolveRepoRoot()
raw = getenv("TRIPLENS_COSIM_REPO_ROOT");
if ~isempty(raw)&&isfolder(raw)
    root = raw;
else
    root = fileparts(fileparts(mfilename("fullpath")));
end
end

function writeJson(file,value)
fid = fopen(file,"w");
assert(fid>=0,"TripLens:WriteFailed","Cannot write %s",file);
cleanup = onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,jsonencode(value,PrettyPrint=true),"char");
end

function out = ternary(condition,a,b)
if condition, out = a; else, out = b; end
end
