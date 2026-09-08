function report = run_thermosyspro_baseline()
%RUN_THERMOSYSPRO_BASELINE Check whether the untouched CombinedCycle_TripTAC initializes.
repoRoot = resolveRepoRoot();
outDir = fullfile(repoRoot,'outputs');
buildDir = fullfile(repoRoot,'build','baseline');
omHome = fullfile(repoRoot,'omhome');
if ~isfolder(outDir), mkdir(outDir); end
if isfolder(buildDir), rmdir(buildDir,'s'); end
mkdir(buildDir);

libRoot = fullfile(repoRoot,'vendor','ThermoSysPro','ThermoSysPro');
packageFile = fullfile(libRoot,'package.mo');
assert(isfile(packageFile),'TripLens:BaselineMissingLibrary','Missing ThermoSysPro package.mo');
omc = resolveOmc();

mosFile = fullfile(buildDir,'run_baseline.mos');
mos = sprintf([ ...
    'loadModel(Modelica,{"3.2.3"});\n' ...
    'getErrorString();\n' ...
    'loadFile("%s");\n' ...
    'getErrorString();\n' ...
    'checkModel(ThermoSysPro.Fluid.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC);\n' ...
    'getErrorString();\n' ...
    'simulate(ThermoSysPro.Fluid.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC,startTime=0,stopTime=10,numberOfIntervals=10,tolerance=1e-3,outputFormat="csv",fileNamePrefix="TripLens_Baseline");\n' ...
    'getErrorString();\n'], slash(packageFile));
writeText(mosFile,mos);

omAppData = fullfile(omHome,'AppData','Roaming');
omLocalAppData = fullfile(omHome,'AppData','Local');
if ~isfolder(omAppData), mkdir(omAppData); end
if ~isfolder(omLocalAppData), mkdir(omLocalAppData); end
oldHome=getenv('HOME'); oldUser=getenv('USERPROFILE'); oldApp=getenv('APPDATA'); oldLocal=getenv('LOCALAPPDATA');
c=onCleanup(@() restoreEnv(oldHome,oldUser,oldApp,oldLocal)); %#ok<NASGU>
setenv('HOME',omHome); setenv('USERPROFILE',omHome); setenv('APPDATA',omAppData); setenv('LOCALAPPDATA',omLocalAppData);
old=pwd; d=onCleanup(@() cd(old)); %#ok<NASGU>
cd(buildDir);
cmd=sprintf('"%s" "%s"',omc,mosFile);
fprintf('Running untouched CombinedCycle_TripTAC baseline...\n%s\n',cmd);
[status,logText]=system(cmd);
writeText(fullfile(outDir,'openmodelica_baseline.log'),logText);

report=struct;
report.Status='FAIL';
report.Model='ThermoSysPro.Fluid.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC';
report.StopTime_s=10;
report.OmcExitCode=status;
report.InitializationAssertion=contains(logText,'simulation terminated by an assertion at initialization') || contains(logText,'Simulation execution failed');
res=fullfile(buildDir,'TripLens_Baseline_res.csv');
report.ResultFileExists=isfile(res);
report.ResultRows=0;
if isfile(res)
    T=readtable(res,'VariableNamingRule','preserve');
    report.ResultRows=height(T);
end
report.Passed=(status==0) && ~report.InitializationAssertion && report.ResultRows>=2;
if report.Passed, report.Status='PASS'; end
writeText(fullfile(outDir,'baseline_summary.json'),jsonencode(report,PrettyPrint=true));
fprintf('BASELINE PASS=%d, rows=%d, initializationAssertion=%d\n',report.Passed,report.ResultRows,report.InitializationAssertion);
if ~report.Passed
    error('TripLens:BaselineFailed','Untouched CombinedCycle_TripTAC baseline failed. See outputs/openmodelica_baseline.log');
end
end

function root=resolveRepoRoot()
raw=getenv('TRIPLENS_COSIM_REPO_ROOT');
if ~isempty(raw)&&isfolder(raw), root=raw; else, root=fileparts(fileparts(mfilename('fullpath'))); end
end
function exe=resolveOmc()
[status,pathText]=system('where omc 2>NUL');
if status==0
    lines=splitlines(strtrim(string(pathText)));
    if ~isempty(lines)&&strlength(lines(1))>0, exe=char(lines(1)); return; end
end
roots=["C:\OpenModelica*\bin\omc.exe";"C:\Program Files\OpenModelica*\bin\omc.exe"];
for pat=roots'
    x=dir(pat); if ~isempty(x), exe=fullfile(x(1).folder,x(1).name); return; end
end
error('TripLens:OmcNotFound','OpenModelica not found');
end
function restoreEnv(h,u,a,l), setenv('HOME',h);setenv('USERPROFILE',u);setenv('APPDATA',a);setenv('LOCALAPPDATA',l); end
function s=slash(path), s=replace(string(path),'\','/'); end
function writeText(file,text)
fid=fopen(file,'w');assert(fid>=0,'TripLens:WriteFailed','Cannot write %s',file);x=onCleanup(@() fclose(fid)); %#ok<NASGU>
fwrite(fid,char(text),'char');
end
