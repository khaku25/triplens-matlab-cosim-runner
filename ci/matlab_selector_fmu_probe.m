function matlab_selector_fmu_probe()
% Isolated integration probe, not an ECMS scenario or a plant safety model.
% Read XML port order; initialize master signals before FMU initialization.
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
    if strcmp(char(v.getAttribute('causality')),'input')
        inputs{end+1} = char(v.getAttribute('name')); %#ok<AGROW>
        starts(end+1) = str2double(char(v.getElementsByTagName('Real').item(0).getAttribute('start'))); %#ok<AGROW>
    end
end
outs = doc.getElementsByTagName('Outputs').item(0).getElementsByTagName('Unknown');
for k = 0:outs.getLength-1
    idx = str2double(char(outs.item(k).getAttribute('index')));
    v = vars.item(idx-1);
    assert(strcmp(char(v.getAttribute('causality')),'output'));
    outputs{end+1} = char(v.getAttribute('name')); %#ok<AGROW>
    units{end+1} = char(v.getElementsByTagName('Real').item(0).getAttribute('unit')); %#ok<AGROW>
end
assert(numel(inputs)==2 && numel(outputs)==7,'Unexpected selector interface.');
assert(all(isfinite(starts)) && all(starts>0),'Input defaults must be nonzero.');
expected = {'hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower'};
assert(isequal(sort(outputs),sort(expected)),'Output name mismatch.');
step = 0.001; stopTime = 0.2;
map = struct('inputs',{inputs},'input_start',starts,'outputs',{outputs},'units',{units}, ...
    'source','modelDescription.xml ModelStructure, not declaration order', ...
    'baseline_source','Constant', 'step_case_source','Step plus Unit Delay with nominal initial condition', ...
    'step_case_transport_delay_s',step,'command_change_s',0.1,'nominal_applied_change_s',0.1+step);
writeJson(fullfile(outDir,'selector_port_map.json'),map);
disp(jsonencode(map));
copyfile(fullfile(inspectDir,'modelDescription.xml'),fullfile(outDir,'selector_modelDescription.xml'));
rmdir(inspectDir,'s');
addpath(outDir);
pathCleanup = onCleanup(@() rmpath(outDir)); %#ok<NASGU>
[~,stem,ext] = fileparts(fmu); fmuName = [stem ext];
caseNames = {'baseline','flow_step','temperature_step'};
results = struct();
for c = 1:numel(caseNames)
    caseName = caseNames{c};
    mdl = ['TripLens_Selector_' caseName];
    if bdIsLoaded(mdl), bdclose(mdl); end
    new_system(mdl);
    modelCleanup = onCleanup(@() closeProbe(mdl));
    blk = [mdl '/Thermo_FMU'];
    add_block('simulink_extras/FMU Import/FMU',blk,'FMUName',fmuName,'Position',[400 40 680 440]);
    set_param(blk,'FMUInputMapping','Flat','FMUOutputMapping','Flat', ...
        'FMUSampleTime',num2str(step,17),'FMUDebugLogging','on','FMUDebugLoggingRedirect','File');
    ph = get_param(blk,'PortHandles');
    assert(numel(ph.Inport)==2 && numel(ph.Outport)==7,'Port count mismatch.');
    fid = fopen(fullfile(outDir,[caseName '_mask_display.txt']),'w');
    fprintf(fid,'%s',get_param(blk,'MaskDisplay')); fclose(fid);
    for k = 1:numel(inputs)
        inputName = inputs{k};
        if strcmp(inputName,'gtExhaustFlowCmd')
            first = 606.94; last = first*(1-0.01*strcmp(caseName,'flow_step'));
        elseif strcmp(inputName,'gtExhaustTemperatureCmd')
            first = 893.75; last = first*(1-0.005*strcmp(caseName,'temperature_step'));
        else
            error('TripLens:UnknownInput','Unexpected FMU input.');
        end
        source = [mdl '/' inputName];
        if strcmp(caseName,'baseline')
            add_block('simulink/Sources/Constant',source,'Value',num2str(first,17), ...
                'Position',[30 60+100*k 170 90+100*k]);
            appliedSource = inputName;
        else
            add_block('simulink/Sources/Step',source,'Time','0.1','Before',num2str(first,17), ...
                'After',num2str(last,17),'SampleTime',num2str(step,17), ...
                'Position',[30 60+100*k 170 90+100*k]);
            appliedSource = ['Initialized_' inputName];
            add_block('simulink/Discrete/Unit Delay',[mdl '/' appliedSource], ...
                'InitialCondition',num2str(first,17),'SampleTime',num2str(step,17), ...
                'Position',[230 60+100*k 300 90+100*k]);
            add_line(mdl,[inputName '/1'],[appliedSource '/1'],'autorouting','on');
        end
        add_line(mdl,[appliedSource '/1'],['Thermo_FMU/' num2str(k)],'autorouting','on');
        logName = ['applied_' inputName];
        add_block('simulink/Sinks/To Workspace',[mdl '/' logName],'VariableName',logName, ...
            'SaveFormat','Timeseries','SampleTime',num2str(step,17), ...
            'Position',[230 410+60*k 390 440+60*k]);
        add_line(mdl,[appliedSource '/1'],[logName '/1'],'autorouting','on');
    end
    for k = 1:numel(outputs)
        outputName = outputs{k};
        add_block('simulink/Sinks/To Workspace',[mdl '/' outputName],'VariableName',outputName, ...
            'SaveFormat','Timeseries','Position',[760 25+55*k 970 50+55*k]);
        add_line(mdl,['Thermo_FMU/' num2str(k)],[outputName '/1'],'autorouting','on');
        fprintf('OUTPUT_PORT_%d=%s [%s]\n',k,outputName,units{k});
    end
    set_param(mdl,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
        'FixedStep',num2str(step,17),'StopTime',num2str(stopTime,17));
    save_system(mdl,fullfile(outDir,[mdl '.slx']));
    fprintf('SELECTOR_CASE_START=%s\n',caseName);
    try
        simOut = sim(mdl,'ReturnWorkspaceOutputs','on');
        firstSeries = simOut.get(outputs{1}); times = firstSeries.Time(:);
        assert(numel(times)>=2 && times(end)>=stopTime-step/2,'Simulation did not reach stop time.');
        values = zeros(numel(times),numel(outputs));
        applied = zeros(numel(times),numel(inputs));
        for k = 1:numel(outputs)
            ts = simOut.get(outputs{k});
            assert(isequal(ts.Time(:),times),'Output times are not aligned.');
            values(:,k) = ts.Data(:);
        end
        for k = 1:numel(inputs)
            ts = simOut.get(['applied_' inputs{k}]);
            assert(isequal(ts.Time(:),times),'Input times are not aligned.');
            applied(:,k) = ts.Data(:);
            assert(abs(applied(1,k)-starts(k))<1e-8,'Actual initial input is not nominal.');
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
        T = array2table([times applied values],'VariableNames',[{'time_s'} inputs outputs]);
        writetable(T,fullfile(outDir,[caseName '.csv']));
        save(fullfile(outDir,[caseName '.mat']),'times','applied','values','inputs','outputs','units');
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
hits = dir(fullfile(repo,'slprj','_fmu',['_logs_' mdl],'*.txt'));
for k = 1:numel(hits)
    src = fullfile(hits(k).folder,hits(k).name);
    copyfile(src,fullfile(outDir,['debug_' hits(k).name]));
    if showTail
        lines = splitlines(string(fileread(src)));
        disp(join(lines(max(1,numel(lines)-35):end),newline));
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
