function cosim_entrypoint(mode)
%COSIM_ENTRYPOINT Entry point for TripLens MATLAB/ThermoSysPro co-simulation.

if nargin < 1 || strlength(string(mode)) == 0
    mode = "smoke";
end
mode = lower(string(mode));

repoRoot = fileparts(fileparts(mfilename("fullpath")));
outDir = fullfile(repoRoot,"outputs");
if ~isfolder(outDir), mkdir(outDir); end

fprintf("TripLens MATLAB Co-Sim\n");
fprintf("Mode: %s\n",mode);
fprintf("MATLAB: %s\n",version);
fprintf("Computer: %s\n",computer);
fprintf("Repository: %s\n",repoRoot);

products = ver;
productNames = string({products.Name});
fprintf("Installed MathWorks products:\n");
for k = 1:numel(products)
    fprintf("  - %s %s\n",products(k).Name,products(k).Version);
end

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

    case "bfp-cosim"
        report = check_bfp_wrapper_inputs(report);
        if report.Status ~= "PASS"
            error("TripLens:WrapperCheckFailed","BFP wrapper prerequisites failed before co-simulation.");
        end
        error("TripLens:CosimNotEnabled", ...
            ["BFP co-simulation has not been enabled yet. " + ...
             "The next commit will add the external-input Modelica wrapper and FMU/OpenModelica execution after local prerequisite validation."]);

    otherwise
        error("TripLens:UnknownMode","Unknown mode: %s",mode);
end

json = jsonencode(report,PrettyPrint=true);
fid = fopen(fullfile(outDir,"environment_report.json"),"w");
assert(fid>=0,"TripLens:OutputOpenFailed","Cannot open environment report for writing.");
cleaner = onCleanup(@() fclose(fid));
fwrite(fid,json,"char");
fprintf("%s\n",json);
fprintf("PASS: %s\n",mode);
end

function report = check_bfp_wrapper_inputs(report)
root = string(getenv("TRIPLENS_THERMOSYSPRO_ROOT"));
if strlength(root)==0
    report.Status = "FAIL";
    report.Message = "TRIPLENS_THERMOSYSPRO_ROOT is not set on the runner PC.";
    write_and_fail(report);
end

packageFile = fullfile(root,"ThermoSysPro","package.mo");
if ~isfile(packageFile)
    % Also accept the library root itself, where package.mo is directly below root.
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
required = [
    "PompeAlimHP"
    "rpm_or_mpower"
    "arretPomesHP"
    "SourceFumees"
    "IMassFlow"
];
missing = strings(0,1);
for k=1:numel(required)
    if ~contains(text,required(k))
        missing(end+1,1) = required(k); %#ok<AGROW>
    end
end

report.ThermoSysProRoot = char(libraryRoot);
report.ModelFile = char(modelFile);
report.RequiredTokens = cellstr(required);
report.MissingTokens = cellstr(missing);

if isempty(missing)
    report.Status = "PASS";
    report.Message = "ThermoSysPro BFP/GT external-control prerequisites were found in CombinedCycle_TripTAC.mo.";
else
    report.Status = "FAIL";
    report.Message = "Expected controllable components/connectors are missing from the local model.";
    write_and_fail(report);
end
end

function write_and_fail(report)
repoRoot = fileparts(fileparts(mfilename("fullpath")));
outDir = fullfile(repoRoot,"outputs");
if ~isfolder(outDir), mkdir(outDir); end
json = jsonencode(report,PrettyPrint=true);
fid = fopen(fullfile(outDir,"environment_report.json"),"w");
if fid>=0
    fwrite(fid,json,"char");
    fclose(fid);
end
error("TripLens:PrerequisiteFailed","%s",report.Message);
end
