function cosim_entrypoint(mode)
%COSIM_ENTRYPOINT Entry point for TripLens MATLAB/ThermoSysPro co-simulation.

if nargin < 1 || strlength(string(mode)) == 0
    mode = "smoke";
end
mode = lower(string(mode));

repoRoot = resolveRepoRoot();
outDir = fullfile(repoRoot,"outputs");
if ~isfolder(outDir), mkdir(outDir); end
addpath(fullfile(repoRoot,"matlab"),"-begin");

fprintf("TripLens MATLAB Co-Sim\n");
fprintf("Mode: %s\n",mode);
fprintf("MATLAB: %s\n",version);
fprintf("Computer: %s\n",computer);
fprintf("Repository: %s\n",repoRoot);

products = ver;
productNames = string({products.Name});
report = struct;
report.Timestamp = char(datetime('now','Format','yyyy-MM-dd''T''HH:mm:ssXXX'));
report.Mode = char(mode);
report.MATLABVersion = version;
report.Computer = computer;
report.Products = cellstr(productNames);
report.Status = "STARTED";

switch mode
    case "smoke"
        report.Status = "PASS";
        report.Message = "Installed MATLAB executed successfully on the self-hosted runner.";

    case "bfp-wrapper-check"
        report = check_bfp_wrapper_inputs(report);

    case "ecms-inventory"
        report.ECMS = run_ecms_simulink("InventoryOnly",true);
        report.Status = "PASS";
        report.Message = "Local ECMS Simulink model inventory completed without opening the GUI.";

    case "ecms-simulate"
        report.ECMS = run_ecms_simulink("InventoryOnly",false);
        report.Status = "PASS";
        report.Message = "Local ECMS Simulink model executed non-interactively on the self-hosted runner.";

    case "bfp-cosim"
        report = check_bfp_wrapper_inputs(report);
        baseline = run_thermosyspro_baseline();
        report.Baseline = baseline;
        commandFile = string(getenv("TRIPLENS_COMMAND_FILE"));
        if strlength(commandFile)==0
            commandFile = fullfile(repoRoot,"examples","bfp_trip_commands.csv");
        elseif ~isfile(commandFile)
            commandFile = fullfile(repoRoot,commandFile);
        end
        cmd = read_bfp_trip_command(commandFile);
        requestedTripTime = envNumber("TRIPLENS_BFP_TRIP_TIME",cmd.Time_s);
        if abs(requestedTripTime-cmd.Time_s)>1e-9
            fprintf("Workflow trip-time override %.6g s replaces command-file time %.6g s.\n",requestedTripTime,cmd.Time_s);
        end
        rampDuration = envNumber("TRIPLENS_BFP_RAMP_DURATION",2);
        stopTime = envNumber("TRIPLENS_STOP_TIME",1000);
        intervals = envNumber("TRIPLENS_INTERVALS",1000);
        physics = run_bfp_physical_cosim("TripTime",requestedTripTime,"RampDuration",rampDuration, ...
            "StopTime",stopTime,"Intervals",intervals);
        report.Status = "PASS";
        report.Message = "ECMS FWP-HP TRIP command was adapted into a real ThermoSysPro HP BFP physical trip.";
        report.ECMSCommand = cmd;
        report.Physics = physics;

    otherwise
        error("TripLens:UnknownMode","Unknown mode: %s",mode);
end

writeReport(outDir,report);
fprintf("PASS: %s\n",mode);
end

function report = check_bfp_wrapper_inputs(report)
repoRoot = resolveRepoRoot();
root = string(getenv("TRIPLENS_THERMOSYSPRO_ROOT"));
if strlength(root)==0
    root = fullfile(repoRoot,"vendor","ThermoSysPro");
end

packageFile = fullfile(root,"ThermoSysPro","package.mo");
if ~isfile(packageFile)
    altPackage = fullfile(root,"package.mo");
    if isfile(altPackage)
        libraryRoot = root;
    else
        report.Status = "FAIL";
        report.Message = sprintf("ThermoSysPro package.mo not found under %s",root);
        write_and_fail(report);
    end
else
    libraryRoot = fullfile(root,"ThermoSysPro");
end

candidateA = fullfile(libraryRoot,"Fluid","Examples","CombinedCyclePowerPlant","CombinedCycle_TripTAC.mo");
candidateB = fullfile(libraryRoot,"Examples","CombinedCyclePowerPlant","CombinedCycle_TripTAC.mo");
if isfile(candidateA)
    modelFile = candidateA;
elseif isfile(candidateB)
    modelFile = candidateB;
else
    report.Status = "FAIL";
    report.Message = "CombinedCycle_TripTAC.mo was not found in the expected ThermoSysPro locations.";
    write_and_fail(report);
end

text = fileread(modelFile);
required = ["PompeAlimHP";"rpm_or_mpower";"arretPomesHP";"SourceFumees";"IMassFlow";"CapteurDebitEauHP";"BallonHP"];
missing = strings(0,1);
for k=1:numel(required)
    if ~contains(text,required(k)), missing(end+1,1) = required(k); end %#ok<AGROW>
end
report.ThermoSysProRoot = char(libraryRoot);
report.ModelFile = char(modelFile);
report.RequiredTokens = cellstr(required);
report.MissingTokens = cellstr(missing);
if isempty(missing)
    report.Status = "PASS";
    report.Message = "ThermoSysPro physical BFP control and measurement points were found.";
else
    report.Status = "FAIL";
    report.Message = "Expected BFP physical control/measurement points are missing from the local model.";
    write_and_fail(report);
end
end

function value = envNumber(name,defaultValue)
raw = string(getenv(name));
if strlength(raw)==0
    value = defaultValue;
else
    value = str2double(raw);
    assert(isfinite(value),"TripLens:BadEnvironmentValue","%s is not numeric: %s",name,raw);
end
end

function root = resolveRepoRoot()
raw = getenv('TRIPLENS_COSIM_REPO_ROOT');
if ~isempty(raw) && isfolder(raw)
    root = raw;
else
    root = fileparts(fileparts(mfilename("fullpath")));
end
end

function writeReport(outDir,report)
json = jsonencode(report,PrettyPrint=true);
fid = fopen(fullfile(outDir,"environment_report.json"),"w");
assert(fid>=0,"TripLens:OutputOpenFailed","Cannot open environment report for writing.");
c = onCleanup(@() fclose(fid));
fwrite(fid,json,"char");
fprintf("%s\n",json);
end

function write_and_fail(report)
repoRoot = resolveRepoRoot();
outDir = fullfile(repoRoot,"outputs");
if ~isfolder(outDir), mkdir(outDir); end
json = jsonencode(report,PrettyPrint=true);
fid = fopen(fullfile(outDir,"environment_report.json"),"w");
if fid>=0, fwrite(fid,json,"char"); fclose(fid); end
error("TripLens:PrerequisiteFailed","%s",report.Message);
end
