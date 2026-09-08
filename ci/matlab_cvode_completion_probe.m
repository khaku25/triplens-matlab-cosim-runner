function matlab_cvode_completion_probe()
% Execute a real FMU on installed MATLAB. No CSV replay or hidden plant model.
% Save a checkpoint before sim(), so a native crash cannot look like a PASS.
repo = getenv('GITHUB_WORKSPACE'); if isempty(repo), repo=pwd; end
outDir=fullfile(repo,'outputs'); if ~isfolder(outDir), mkdir(outDir); end
fmu=fullfile(outDir,'TripLens_CombinedCycle_TripTAC_CoSim_win64.fmu');
assert(isfile(fmu),'CVODE FMU missing.');
inspect=fullfile(outDir,'cvode_inspect'); mkdir(inspect); unzip(fmu,inspect);
manifest=jsondecode(fileread(fullfile(inspect,'resources','cvode_build_manifest.json')));
assert(strcmp(manifest.integrator,'CVODE') && manifest.allocator_fix.experimental_runtime_fix);
flags=jsondecode(fileread(fullfile(inspect,'resources','TripLens_CombinedCycle_TripTAC_CoSim_flags.json')));
assert(strcmp(flags.s,'cvode'));
doc=xmlread(fullfile(inspect,'modelDescription.xml'));
vars=doc.getElementsByTagName('ScalarVariable'); inputs={}; starts=[]; outputs={}; units={};
for k=0:vars.getLength-1
    v=vars.item(k);
    if strcmp(char(v.getAttribute('causality')),'input')
        inputs{end+1}=char(v.getAttribute('name')); %#ok<AGROW>
        starts(end+1)=str2double(char(v.getElementsByTagName('Real').item(0).getAttribute('start'))); %#ok<AGROW>
    end
end
outs=doc.getElementsByTagName('Outputs').item(0).getElementsByTagName('Unknown');
for k=0:outs.getLength-1
    index=str2double(char(outs.item(k).getAttribute('index')));
    v=vars.item(index-1); outputs{end+1}=char(v.getAttribute('name')); %#ok<AGROW>
    units{end+1}=char(v.getElementsByTagName('Real').item(0).getAttribute('unit')); %#ok<AGROW>
end
assert(numel(inputs)==2 && numel(outputs)==7 && all(starts>0));
copyfile(fullfile(inspect,'modelDescription.xml'),fullfile(outDir,'tested_modelDescription.xml'));
rmdir(inspect,'s');
addpath(outDir); pathCleanup=onCleanup(@() rmpath(outDir)); %#ok<NASGU>
h=0.01; stopTime=2; changeTime=1;
names={'baseline','flow_step','temperature_step'};
report=struct('integrator','CVODE','communication_step_s',h,'requested_stop_s',stopTime, ...
    'command_time_s',changeTime,'applied_change_time_s',changeTime+h, ...
    'csv_replay',false,'full_ecms_closed_loop_verified',false, ...
    'input_names',{inputs},'output_names',{outputs},'output_units',{units},'cases',struct());
writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
for c=1:numel(names)
    name=names{c}; mdl=['TripLens_CVODE_' name];
    if bdIsLoaded(mdl), bdclose(mdl); end
    new_system(mdl); closeCleanup=onCleanup(@() closeModel(mdl));
    report.cases.(name)=struct('status','building');
    writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
    wall=tic;
    try
        blk=[mdl '/Thermo_FMU']; [~,stem,ext]=fileparts(fmu);
        add_block('simulink_extras/FMU Import/FMU',blk,'FMUName',[stem ext], ...
            'Position',[380 70 650 440]);
        set_param(blk,'FMUInputMapping','Flat','FMUOutputMapping','Flat', ...
            'FMUSampleTime',num2str(h,17),'FMUDebugLogging','off');
        handles=get_param(blk,'PortHandles');
        assert(numel(handles.Inport)==2 && numel(handles.Outport)==7);
        for k=1:2
            n=inputs{k}; initial=starts(k); final=initial;
            if strcmp(name,'flow_step') && strcmp(n,'gtExhaustFlowCmd'), final=initial*0.99; end
            if strcmp(name,'temperature_step') && strcmp(n,'gtExhaustTemperatureCmd'), final=initial*0.995; end
            if strcmp(name,'baseline')
                add_block('simulink/Sources/Constant',[mdl '/' n], ...
                    'Value',num2str(initial,17),'Position',[35 90*k 165 30+90*k]);
                source=n;
            else
                add_block('simulink/Sources/Step',[mdl '/' n],'Time',num2str(changeTime), ...
                    'Before',num2str(initial,17),'After',num2str(final,17), ...
                    'SampleTime',num2str(h,17),'Position',[35 90*k 165 30+90*k]);
                source=['Initialized_' n];
                add_block('simulink/Discrete/Unit Delay',[mdl '/' source], ...
                    'InitialCondition',num2str(initial,17),'SampleTime',num2str(h,17), ...
                    'Position',[230 90*k 280 30+90*k]);
                add_line(mdl,[n '/1'],[source '/1'],'autorouting','on');
            end
            add_line(mdl,[source '/1'],['Thermo_FMU/' num2str(k)],'autorouting','on');
            logName=['applied_' n];
            add_block('simulink/Sinks/To Workspace',[mdl '/' logName], ...
                'VariableName',logName,'SaveFormat','Timeseries','SampleTime',num2str(h,17), ...
                'Position',[50 450+60*k 240 480+60*k]);
            add_line(mdl,[source '/1'],[logName '/1'],'autorouting','on');
        end
        for k=1:7
            add_block('simulink/Sinks/To Workspace',[mdl '/' outputs{k}], ...
                'VariableName',outputs{k},'SaveFormat','Timeseries', ...
                'Position',[760 35+55*k 970 60+55*k]);
            add_line(mdl,['Thermo_FMU/' num2str(k)],[outputs{k} '/1'],'autorouting','on');
        end
        set_param(mdl,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
            'FixedStep',num2str(h,17),'StopTime',num2str(stopTime,17));
        save_system(mdl,fullfile(outDir,[mdl '.slx']));
        report.cases.(name)=struct('status','sim_running');
        writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
        fprintf('CVODE_SIM_START=%s\n',name);
        simOut=sim(mdl,'ReturnWorkspaceOutputs','on');
        fprintf('CVODE_SIM_RETURNED_AFTER_CLEANUP=%s\n',name);
        report.cases.(name)=struct('status','sim_returned_validating');
        writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
        save(fullfile(outDir,[name '_simOut.mat']),'simOut');
        ts=simOut.get(outputs{1}); times=ts.Time(:);
        assert(numel(times)>=2 && abs(times(end)-stopTime)<h/2,'Stop time not reached.');
        values=zeros(numel(times),7); applied=zeros(numel(times),2);
        for k=1:7
            ts=simOut.get(outputs{k}); assert(isequal(ts.Time(:),times)); values(:,k)=ts.Data(:);
        end
        for k=1:2
            ts=simOut.get(['applied_' inputs{k}]); assert(isequal(ts.Time(:),times)); applied(:,k)=ts.Data(:);
            assert(abs(applied(1,k)-starts(k))<1e-8,'Non-nominal initialization input.');
        end
        assert(all(isfinite(values(:))),'Nonfinite physical output.');
        for k=1:7
            if contains(outputs{k},'Level'), assert(all(values(:,k)>0 & values(:,k)<4.1));
            elseif contains(outputs{k},'Pressure'), assert(all(values(:,k)>1e3 & values(:,k)<1e8));
            elseif strcmp(outputs{k},'stElectricalPower'), assert(all(abs(values(:,k))>1e3 & abs(values(:,k))<1e10)); end
        end
        result=struct('status','pass','sim_returned',true,'stop_time_s',times(end), ...
            'samples',numel(times),'initial',values(1,:),'final',values(end,:),'wall_seconds',toc(wall));
        if c==1
            baseline=values; baselineTimes=times;
            assert(max(max(abs(applied-repmat(starts,numel(times),1))))<1e-8);
        else
            assert(isequal(times,baselineTimes));
            pre=times<changeTime+h/2; scale=max(1,max(abs(baseline),[],1));
            assert(max(max(abs(values(pre,:)-baseline(pre,:))./scale))<1e-7,'Pre-change histories differ.');
            delta=max(abs(values(~pre,:)-baseline(~pre,:)),[],1);
            assert(any(delta./scale>1e-10),'No physical input response.');
            changed=find(abs(applied(end,:)-starts)>1e-8);
            assert(numel(changed)==1,'Expected exactly one changed input.');
            if c==2, assert(strcmp(inputs{changed},'gtExhaustFlowCmd')); else, assert(strcmp(inputs{changed},'gtExhaustTemperatureCmd')); end
            result.max_absolute_response=delta;
            result.applied_input_final=applied(end,:);
        end
        T=array2table([times applied values],'VariableNames',[{'time_s'} inputs outputs]);
        writetable(T,fullfile(outDir,[name '.csv']));
        report.cases.(name)=result;
        writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
        fprintf('CVODE_SIM_COMPLETION_AND_FINITE_OUTPUT_PASS=%s\n',name);
        fprintf('ST_FINAL_W=%.17g\n',values(end,strcmp(outputs,'stElectricalPower')));
    catch ME
        report.cases.(name)=struct('status','failure','error',getReport(ME,'extended','hyperlinks','off'),'wall_seconds',toc(wall));
        writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
        disp(getReport(ME,'extended','hyperlinks','off')); rethrow(ME);
    end
    bdclose(mdl); clear closeCleanup;
end
report.overall='pass'; writeJson(fullfile(outDir,'cvode_completion_results.json'),report);
disp('INSTALLED_SIMULINK_CVODE_THREE_CASES_COMPLETE_PASS');
disp('NOT_A_FULL_ECMS_CLOSED_LOOP_OR_LONG_DURATION_ACCIDENT_VALIDATION');
end
function writeJson(p,value)
f=fopen(p,'w'); assert(f>=0); cleanup=onCleanup(@() fclose(f)); %#ok<NASGU>
fprintf(f,'%s\n',jsonencode(value,'PrettyPrint',true));
end
function closeModel(mdl)
if bdIsLoaded(mdl), bdclose(mdl); end
end
