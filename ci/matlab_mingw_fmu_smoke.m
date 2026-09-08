function matlab_mingw_fmu_smoke()
% Compile the validated cloud-built TripTAC FMI 2.0 Co-Simulation FMU
% sources into a Windows-ready FMU using MATLAB's MinGW toolchain.

repo = getenv('GITHUB_WORKSPACE');
if isempty(repo), repo = pwd; end

hits = dir(fullfile(repo,'fmu_artifact','**','TripLens_CombinedCycle_TripTAC_CoSim.fmu'));
assert(~isempty(hits),'TripLens:FMUMissing','Validated cloud FMU artifact not found.');
src = fullfile(hits(1).folder,hits(1).name);

outDir = fullfile(repo,'outputs');
if ~isfolder(outDir), mkdir(outDir); end
fmu = fullfile(outDir,'TripLens_CombinedCycle_TripTAC_CoSim_win64.fmu');
copyfile(src,fmu,'f');

compilers = mex.getCompilerConfigurations('C','Installed');
assert(~isempty(compilers),'TripLens:NoCCompiler','No MATLAB C compiler configuration is installed.');
for k = 1:numel(compilers)
    disp("C_COMPILER_" + string(k) + "=" + string(compilers(k).Name));
end

isMinGW = arrayfun(@(x) contains(lower(string(x.Name)),'mingw') || ...
    contains(lower(string(x.Manufacturer)),'gnu'), compilers);
idx = find(isMinGW,1);
assert(~isempty(idx),'TripLens:NoMinGW','MATLAB MinGW C compiler configuration not found.');

mex(['-setup:' compilers(idx).MexOpt],'C');
selected = mex.getCompilerConfigurations('C','Selected');
disp("SELECTED_C_COMPILER=" + string(selected.Name));
assert(contains(lower(string(selected.Name)),'mingw') || ...
    contains(lower(string(selected.Manufacturer)),'gnu'), ...
    'TripLens:MinGWNotSelected','MinGW was not selected as MATLAB C compiler.');

% Inspect before compilation so failures distinguish payload from toolchain.
preDir = fullfile(outDir,'fmu_preinspect');
if isfolder(preDir), rmdir(preDir,'s'); end
mkdir(preDir);
unzip(fmu,preDir);
hasSources = isfolder(fullfile(preDir,'sources')) && ...
    ~isempty(dir(fullfile(preDir,'sources','*.c')));
hasWinBefore = isfolder(fullfile(preDir,'binaries','win64')) && ...
    ~isempty(dir(fullfile(preDir,'binaries','win64','*')));
headerPresent = isfile(fullfile(preDir,'sources','omc_simulation_settings.h'));
disp("FMU_HAS_C_SOURCES=" + string(hasSources));
disp("FMU_HAS_WIN64_BEFORE=" + string(hasWinBefore));
disp("FMU_HAS_OMC_SETTINGS_HEADER=" + string(headerPresent));
assert(hasSources || hasWinBefore,'TripLens:NoSources','FMU contains neither win64 binary nor C sources.');
assert(headerPresent || hasWinBefore,'TripLens:OMCHeaderMissing','OpenModelica runtime header is missing from source FMU.');
rmdir(preDir,'s');

if ~hasWinBefore
    try
        fmudialog.compileFMUSources(fmu, ...
            'FMUMode','Co-Simulation', ...
            'CustomBuild','triplens_fmu_custom_build');
    catch ME
        disp('FMU_COMPILE_FAILED');
        disp(getReport(ME,'extended','hyperlinks','off'));
        rethrow(ME);
    end
end

postDir = fullfile(outDir,'fmu_postinspect');
if isfolder(postDir), rmdir(postDir,'s'); end
mkdir(postDir);
unzip(fmu,postDir);
winFiles = dir(fullfile(postDir,'binaries','win64','*'));
assert(~isempty(winFiles),'TripLens:NoWin64','Windows-ready FMU has no binaries/win64 payload.');
disp("WIN64_FMU_PASS_FILES=" + string(numel(winFiles)));
rmdir(postDir,'s');

disp("WINDOWS_READY_FMU=" + string(fmu));
end
