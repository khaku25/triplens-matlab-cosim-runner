function matlab_selector_fmu_probe()
% Isolated integration probe, not an ECMS scenario or a plant safety model.
% Never infer port order from Modelica declaration order: read the FMU XML.
repo = getenv('GITHUB_WORKSPACE');
if isempty(repo), repo = pwd; end
outDir = fullfile(repo,'outputs');
fmu = fullfile(outDir,'TripLens_CombinedCycle_TripTAC_CoSim_win64.fmu');
assert(isfile(fmu),'TripLens:FMUMissing','Compile the selector FMU first.');
inspectDir = fullfile(outDir,'selector_xml_inspect');
if ~isfolder(inspectDir), mkdir(inspectDir); end
unzip(fmu,inspectDir);
assert(~isempty(dir(fullfile(inspectDir,'binaries','win64','*.dll'))));
doc = xmlread(fullfile(inspectDir,'modelDescription.xml'));
vars = doc.getElementsByTagName('ScalarVariable');
inputs = {}; outputs = {}; starts = []; units = {};
for k = 0:vars.getLength-1
    v = vars.item(k);
    name = char(v.getAttribute('name'));
    causality = char(v.getAttribute('causality'));
    if strcmp(causality,'input')
        inputs{end+1} = name; %#ok<AGROW>
        realNode = v.getElementsByTagName('Real').item(0);
        starts(end+1) = str2double(char(realNode.getAttribute('start'))); %#ok<AGROW>
    end
end
% FMI ModelStructure determines the exported output sequence.
outs = doc.getElementsByTagName('Outputs').item(0).getElementsByTagName('Unknown');
for k = 0:outs.getLength-1
    idx = str2double(char(outs.item(k).getAttribute('index')));
    v = vars.item(idx-1);
    assert(strcmp(char(v.getAttribute('causality')),'output'));
    outputs{end+1} = char(v.getAttribute('name')); %#ok<AGROW>
    units{end+1} = char(v.getElementsByTagName('Real').item(0).getAttribute('unit')); %#ok<AGROW>
end
assert(numel(inputs)==2 && numel(outputs)==7,'Unexpected selector interface.');
assert(all(isfinite(starts)) && all(starts>0),'Input initialization defaults must be nonzero.');
expected = {'hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower'};
assert(isequal(sort(outputs),sort(expected)),'Output name mismatch.');
map = struct('inputs',{inputs},'input_start',starts,'outputs',{outputs},'units',{units}, ...
    'source','modelDescription.xml ModelStructure, not declaration order');
writeJson(fullfile(outDir,'selector_port_map.json'),map);
disp(jsonencode(map));
copyfile(fullfile(inspectDir,'modelDescription.xml'),fullfile(outDir,'selector_modelDescription.xml'));
rmdir(inspectDir,'s');
addpath(outDir);
pathCleanup = onCleanup(@() rmpath(outDir)); %#ok<NASGU>
[~,stem,ext] = fileparts(fmu);
fmuName = [stem ext];
step = 0.001; stopTime = 0.2;
caseNames = {'baseline','flow_step','temperature_step'};
results = struct();
for c = 1:numel(caseNames)
    caseName = caseNames{c};
    mdl = ['TripLens_Selector_' caseName];
    if bdIsLoaded(mdl), bdclose(mdl); end
    new_system(mdl);
    modelCleanup = onCleanup(@() closeProbe(mdl));
    blk = [mdl '/Thermo_FMU'];
    add_block('simulink_extras/FMU Import/FMU',blk,'FMUName',fmuName, ...
        'Position',[230 40 510 400]);
    set_param(blk,'FMUInputMapping','Flat','FMUOutputMapping','Flat', ...
        'FMUSampleTime',num2str(step,17),'FMUDebugLogging','on', ...
        'FMUDebugLoggingRedirect','File');
    ph = get_param(blk,'PortHandles');
    assert(numel(ph.Inport)==2 && numel(ph.Outport)==7,'Port count mismatch.');
    maskText = get_param(blk,'MaskDisplay');
    fid = fopen(fullfile(outDir,[caseName '_mask_display.txt']),'w');
    fprintf(fid,'%s',maskText); fclose(fid);
    for k = 1:numel(inputs)
        inputName = inputs{k};
        if strcmp(inputName,'gtExhaustFlowCmd')
            first = 606.94;
            last = first * (1 - 0.01*strcmp(caseName,'flow_step'));
        elseif strcmp(inputName,'gtExhaustTemperatureCmd')
            first = 893.75;
            last = first * (1 - 0.005*strcmp(caseName,'temperature_step'));
        else
            error('TripLens:UnknownInput','Unexpected FMU input.');
        end
        source = [mdl '/' inputName];
        add_block('simulink/Sources/Step',source,'Time','0.1', ...
            'Before',num2str(first,17),'After',num2str(last,17), ...
            'SampleTime',num2str(step,17),'Position',[30 60+90*k 170 90+90*k]);
        add_line(mdl,[inputName '/1'],['Thermo_FMU/' num2str(k)],'autorouting','on');
    end
    for k = 1:numel(outputs)
        outputName = outputs{k};
        sink = [mdl '/' outputName];
        add_block('simulink/Sinks/To Workspace',sink,'VariableName',outputName, ...
            'SaveFormat','Timeseries','Position',[610 25+55*k 820 50+55*k]);
        add_line(mdl,['Thermo_FMU/' num2str(k)],[outputName '/1'],'autorouting','on');
        fprintf('OUTPUT_PORT_%d=%s [%s]\n',k,outputName,units{k});
    end
    set_param(mdl,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
        'FixedStep',num2str(step,17),'StopTime',num2str(stopTime,17));
    save_system(mdl,fullfile(outDir,[mdl '.slx']));
    fprintf('SELECTOR_CASE_START=%s\n',caseName);
    try
        simOut = sim(mdl,'ReturnWorkspaceOutputs','on');
        firstSeries = simOut.get(outputs{1});
        times = firstSeries.Time(:);
        assert(numel(times)>=2 && times(end)>=stopTime-step/2,'Simulation did not reach stop time.');
        values = zeros(numel(times),numel(outputs));
        for k = 1:numel(outputs)
            ts = simOut.get(outputs{k});
            assert(isequal(ts.Time(:),times),'Output times are not aligned.');
            values(:,k) = ts.Data(:);
        end
        assert(all(isfinite(values(:))),'FMU output contains non-finite values.');
        st = values(:,strcmp(outputs,'stElectricalPower'));
        assert(all(abs(st)>1e3 & abs(st)<1e10),'ST power mapping or magnitude is invalid.');
        for k = 1:numel(outputs)
            if contains(outputs{k},'Level')
                assert(all(values(:,k)>0 & values(:,k)<4.1),'Drum level mapping or magnitude is invalid.');
            elseif contains(outputs{k},'Pressure')
                assert(all(values(:,k)>1e3 & values(:,k)<1e8),'Drum pressure mapping or magnitude is invalid.');
            end
            fprintf('%s FIRST=%.17g LAST=%.17g\n',outputs{k},values(1,k),values(end,k));
        end
        T = array2table([times values],'VariableNames',[{'time_s'} outputs]);
        writetable(T,fullfile(outDir,[caseName '.csv']));
        save(fullfile(outDir,[caseName '.mat']),'times','values','inputs','outputs','units');
        results.(caseName) = struct('status','pass','samples',numel(times), ...
            'stop_time_s',times(end),'first',values(1,:),'last',values(end,:));
        if strcmp(caseName,'baseline')
            baselineTimes = times; baselineValues = values;
        else
            assert(isequal(times,baselineTimes),'Probe and baseline timestamps differ.');
            pre = times<0.1;
            preDelta = max(abs(values(pre,:)-baselineValues(pre,:)),[],1);
            postDelta = max(abs(values(~pre,:)-baselineValues(~pre,:)),[],1);
            scale = max(1,max(abs(baselineValues),[],1));
            assert(all(preDelta./scale<1e-7),'Runs differ before the input change.');
            assert(any(postDelta./scale>1e-10),'No measurable response to changed input.');
            results.(caseName).max_absolute_response = postDelta;
            results.(caseName).max_relative_response = postDelta./scale;
        end
        collectLogs(repo,outDir,mdl,false);
        fprintf('SELECTOR_CASE_PASS=%s\n',caseName);
    catch ME
        results.(caseName) = struct('status','failure','error',getReport(ME,'extended','hyperlinks','off'));
        collectLogs(repo,outDir,mdl,true);
        writeJson(fullfile(outDir,'selector_probe_results.json'),results);
        rethrow(ME);
    end
    writeJson(fullfile(outDir,'selector_probe_results.json'),results);
    bdclose(mdl); clear modelCleanup;
end
writeJson(fullfile(outDir,'selector_probe_results.json'),results);
disp('SELECTOR_INITIALIZATION_AND_TWO_INPUT_RESPONSE_PROBES_PASS');
disp('THIS_IS_NOT_A_FULL_ECMS_CLOSED_LOOP_OR_VALIDATED_ACCIDENT_SCENARIO');
end

function collectLogs(repo,outDir,mdl,showTail)
p = fullfile(repo,'slprj','_fmu',['_logs_' mdl]);
hits = dir(fullfile(p,'*.txt'));
for k = 1:numel(hits)
    src = fullfile(hits(k).folder,hits(k).name);
    copyfile(src,fullfile(outDir,['debug_' hits(k).name]));
    if showTail
        text = fileread(src);
        lines = splitlines(string(text));
        disp(join(lines(max(1,numel(lines)-100):end),newline));
    end
end
end

function writeJson(p,value)
fid = fopen(p,'w'); assert(fid>=0);
fprintf(fid,'%s\n',jsonencode(value,'PrettyPrint',true)); fclose(fid);
end

function closeProbe(mdl)
if bdIsLoaded(mdl), bdclose(mdl); end
end
