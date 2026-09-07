function report = run_bfp_physical_cosim(varargin)
%RUN_BFP_PHYSICAL_COSIM Run a real ThermoSysPro HP BFP trip under MATLAB control.
% MATLAB is the master launcher; OpenModelica performs the ThermoSysPro physics.

p = inputParser;
addParameter(p,"TripTime",300,@(x)isnumeric(x)&&isscalar(x)&&x>0);
addParameter(p,"RampDuration",2,@(x)isnumeric(x)&&isscalar(x)&&x>0);
addParameter(p,"StopTime",1000,@(x)isnumeric(x)&&isscalar(x)&&x>0);
addParameter(p,"Intervals",1000,@(x)isnumeric(x)&&isscalar(x)&&x>=10);
parse(p,varargin{:});
opt = p.Results;
assert(opt.TripTime < opt.StopTime,"TripLens:BadTripTime","TripTime must be before StopTime.");

repoRoot = fileparts(fileparts(mfilename("fullpath")));
outDir = fullfile(repoRoot,"outputs");
buildDir = fullfile(repoRoot,"build","bfp_physical");
if ~isfolder(outDir), mkdir(outDir); end
if isfolder(buildDir), rmdir(buildDir,"s"); end
mkdir(buildDir);

libraryRoot = resolveThermoSysProRoot();
packageFile = fullfile(libraryRoot,"package.mo");
wrapperFile = fullfile(repoRoot,"modelica","TripLens_BFP_PhysicalTrip.mo");
assert(isfile(wrapperFile),"TripLens:MissingWrapper","Missing Modelica wrapper: %s",wrapperFile);
omc = resolveOmc();

mosFile = fullfile(buildDir,"run_bfp_physical.mos");
resultBase = "TripLens_BFP_PhysicalTrip";
mos = compose([ ...
    'setCommandLineOptions("--matchingAlgorithm=PFPlusExt --indexReductionMethod=dynamicStateSelection");\n' ...
    'loadFile("%s");\n' ...
    'getErrorString();\n' ...
    'loadFile("%s");\n' ...
    'getErrorString();\n' ...
    'checkModel(TripLens_BFP_PhysicalTrip);\n' ...
    'getErrorString();\n' ...
    'simulate(TripLens_BFP_PhysicalTrip, startTime=0, stopTime=%.15g, numberOfIntervals=%d, tolerance=1e-3, outputFormat="csv", fileNamePrefix="%s", simflags="-override=bfpTripTime=%.15g,bfpRampDuration=%.15g");\n' ...
    'getErrorString();\n'], ...
    slash(packageFile), slash(wrapperFile), opt.StopTime, round(opt.Intervals), resultBase, opt.TripTime, opt.RampDuration);
writeText(mosFile,mos);

old = pwd;
cleanup = onCleanup(@() cd(old));
cd(buildDir);
cmd = sprintf('"%s" "%s"',omc,mosFile);
fprintf("Running real ThermoSysPro physics via OpenModelica...\n%s\n",cmd);
[status,logText] = system(cmd);
writeText(fullfile(outDir,"openmodelica_bfp.log"),logText);
if status ~= 0
    error("TripLens:OpenModelicaFailed","OpenModelica failed with exit code %d. See outputs/openmodelica_bfp.log",status);
end

csvFile = fullfile(buildDir,resultBase + "_res.csv");
if ~isfile(csvFile)
    files = dir(fullfile(buildDir,"*.csv"));
    assert(~isempty(files),"TripLens:MissingResult","OpenModelica completed but no CSV result was produced.");
    csvFile = fullfile(files(1).folder,files(1).name);
end
copyfile(csvFile,fullfile(outDir,"bfp_physical_result.csv"));

T = readtable(csvFile,"VariableNamingRule","preserve");
required = ["time","hpBfpRpm","hpFeedwaterFlow","hpDrumLevel","hpDrumPressure"];
for k=1:numel(required)
    assert(any(string(T.Properties.VariableNames)==required(k)),"TripLens:MissingSignal","Result missing %s",required(k));
end

t = T.("time");
preMask = t >= max(0,opt.TripTime-20) & t < opt.TripTime;
postMask = t >= min(opt.StopTime,opt.TripTime+opt.RampDuration+5) & t <= min(opt.StopTime,opt.TripTime+opt.RampDuration+30);
assert(any(preMask)&&any(postMask),"TripLens:InsufficientWindow","Simulation result does not cover pre/post trip windows.");

report = struct;
report.Status = "PASS";
report.Engine = "MATLAB master + OpenModelica ThermoSysPro 4.2";
report.PhysicsModel = "ThermoSysPro.Fluid.Examples.CombinedCyclePowerPlant.CombinedCycle_TripTAC";
report.TripMechanism = "HP BFP rpm ramp 1400 -> 0 using native StaticCentrifugalPump.rpm_or_mpower path";
report.TripTime_s = opt.TripTime;
report.RampDuration_s = opt.RampDuration;
report.StopTime_s = opt.StopTime;
report.PreBfpRpm = median(T.("hpBfpRpm")(preMask),"omitnan");
report.PostBfpRpm = median(T.("hpBfpRpm")(postMask),"omitnan");
report.PreFeedwaterFlow_kg_s = median(T.("hpFeedwaterFlow")(preMask),"omitnan");
report.PostFeedwaterFlow_kg_s = median(T.("hpFeedwaterFlow")(postMask),"omitnan");
report.PreDrumLevel_m = median(T.("hpDrumLevel")(preMask),"omitnan");
report.PostDrumLevel_m = median(T.("hpDrumLevel")(postMask),"omitnan");
report.PreDrumPressure_Pa = median(T.("hpDrumPressure")(preMask),"omitnan");
report.PostDrumPressure_Pa = median(T.("hpDrumPressure")(postMask),"omitnan");
report.RpmTripVerified = report.PreBfpRpm > 1000 && report.PostBfpRpm < 100;
report.FeedwaterResponded = abs(report.PostFeedwaterFlow_kg_s-report.PreFeedwaterFlow_kg_s) > 1e-6;
report.DrumResponded = abs(report.PostDrumLevel_m-report.PreDrumLevel_m) > 1e-8 || abs(report.PostDrumPressure_Pa-report.PreDrumPressure_Pa) > 1;
report.PhysicalLinkVerified = report.RpmTripVerified && report.FeedwaterResponded;

writeText(fullfile(outDir,"bfp_physical_summary.json"),jsonencode(report,PrettyPrint=true));
S = struct2table(report,"AsArray",true);
writetable(S,fullfile(outDir,"bfp_physical_summary.csv"));

fprintf("BFP RPM: %.3f -> %.3f rpm\n",report.PreBfpRpm,report.PostBfpRpm);
fprintf("HP feedwater: %.6g -> %.6g kg/s\n",report.PreFeedwaterFlow_kg_s,report.PostFeedwaterFlow_kg_s);
fprintf("HP drum level: %.6g -> %.6g m\n",report.PreDrumLevel_m,report.PostDrumLevel_m);
fprintf("Physical link verified: %d\n",report.PhysicalLinkVerified);
assert(report.RpmTripVerified,"TripLens:RpmTripNotVerified","ThermoSysPro HP BFP RPM did not reach the commanded trip state.");
assert(report.FeedwaterResponded,"TripLens:NoPhysicalResponse","BFP RPM changed, but feedwater flow did not respond.");
end

function root = resolveThermoSysProRoot()
raw = string(getenv("TRIPLENS_THERMOSYSPRO_ROOT"));
repoRoot = fileparts(fileparts(mfilename("fullpath")));
candidates = strings(0,1);
if strlength(raw)>0, candidates(end+1)=raw; end
candidates(end+1)=fullfile(repoRoot,"vendor","ThermoSysPro","ThermoSysPro");
candidates(end+1)=fullfile(repoRoot,"vendor","ThermoSysPro");
for c = candidates'
    if isfile(fullfile(c,"package.mo"))
        root = char(c); return;
    elseif isfile(fullfile(c,"ThermoSysPro","package.mo"))
        root = char(fullfile(c,"ThermoSysPro")); return;
    end
end
error("TripLens:ThermoSysProNotFound","Set TRIPLENS_THERMOSYSPRO_ROOT to the folder containing ThermoSysPro/package.mo, or vendor the library under vendor/ThermoSysPro.");
end

function exe = resolveOmc()
[status,pathText] = system('where omc 2>NUL');
if status==0
    lines = splitlines(strtrim(string(pathText)));
    if ~isempty(lines) && strlength(lines(1))>0, exe = char(lines(1)); return; end
end
roots = ["C:\OpenModelica*\bin\omc.exe"; "C:\Program Files\OpenModelica*\bin\omc.exe"];
for pat = roots'
    d = dir(pat);
    if ~isempty(d), exe = fullfile(d(1).folder,d(1).name); return; end
end
error("TripLens:OmcNotFound","OpenModelica omc.exe was not found on this PC. Install OpenModelica or add its bin folder to PATH.");
end

function s = slash(path)
s = replace(string(path),"\","/");
end

function writeText(file,text)
fid = fopen(file,"w");
assert(fid>=0,"TripLens:WriteFailed","Cannot write %s",file);
c = onCleanup(@() fclose(fid));
fwrite(fid,char(text),"char");
end
