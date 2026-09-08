function matlab_cvode_long_baseline
repo=getenv('GITHUB_WORKSPACE'); if isempty(repo), repo=pwd; end
outDir=fullfile(repo,'outputs'); if ~exist(outDir,'dir'), mkdir(outDir); end
f=dir(fullfile(outDir,'*win64*.fmu')); assert(numel(f)==1,'Expected exactly one Windows CVODE FMU.');
fmu=fullfile(f.folder,f.name); addpath(outDir);
setenv('TRIPLENS_USE_NATIVE_SEED','1');
setenv('TRIPLENS_RETAIN_VALIDATED_NLS_GUESS','1');
mdl='TripLens_CVODE_420s_baseline';
if bdIsLoaded(mdl), bdclose(mdl); end
new_system(mdl); cleanup=onCleanup(@() closeModel(mdl));
blk=[mdl '/Thermo_FMU'];
add_block('simulink_extras/FMU Import/FMU',blk,'FMUName',f.name,'Position',[400 40 680 440]);
set_param(blk,'FMUInputMapping','Flat','FMUOutputMapping','Flat','FMUSampleTime','0.1', ...
    'FMUDebugLogging','on','FMUDebugLoggingRedirect','File');
ph=get_param(blk,'PortHandles'); assert(numel(ph.Inport)==2 && numel(ph.Outport)==7,'Unexpected FMU port count.');
inputs={'gtExhaustFlowCmd','gtExhaustTemperatureCmd'}; vals=[606.94 893.75];
for k=1:2
    src=[mdl '/' inputs{k}];
    add_block('simulink/Sources/Constant',src,'Value',num2str(vals(k),17),'Position',[40 90+100*k 170 120+100*k]);
    add_line(mdl,[inputs{k} '/1'],['Thermo_FMU/' num2str(k)],'autorouting','on');
end
outputs={'hpDrumLevel','hpDrumPressure','ipDrumLevel','ipDrumPressure','lpDrumLevel','lpDrumPressure','stElectricalPower'};
for k=1:numel(outputs)
    sink=[mdl '/' outputs{k}];
    add_block('simulink/Sinks/To Workspace',sink,'VariableName',outputs{k},'SaveFormat','Timeseries','Position',[760 25+55*k 970 50+55*k]);
    add_line(mdl,['Thermo_FMU/' num2str(k)],[outputs{k} '/1'],'autorouting','on');
end
set_param(mdl,'SolverType','Fixed-step','Solver','FixedStepDiscrete','FixedStep','0.1','StopTime','420');
save_system(mdl,fullfile(outDir,[mdl '.slx']));
t0=tic; simOut=sim(mdl,'ReturnWorkspaceOutputs','on'); wall=toc(t0);
first=simOut.get(outputs{1}); t=first.Time(:);
assert(~isempty(t) && t(end)>=419.95,'Did not reach 420 seconds.');
values=zeros(numel(t),numel(outputs));
for k=1:numel(outputs)
    ts=simOut.get(outputs{k}); assert(isequal(ts.Time(:),t),'Output time mismatch'); values(:,k)=ts.Data(:);
end
assert(all(isfinite(values(:))),'Non-finite Simulink physical output');
assert(all(values(:,[1 3 5])>0 & values(:,[1 3 5])<4.1,'all'),'Invalid drum level');
assert(all(values(:,[2 4 6])>1e3 & values(:,[2 4 6])<1e8,'all'),'Invalid drum pressure');
assert(all(abs(values(:,7))>1e3 & abs(values(:,7))<1e10),'Invalid ST power');
T=array2table([t values],'VariableNames',[{'time_s'} outputs]); writetable(T,fullfile(outDir,'simulink_420s_key_physics.csv'));
report=struct('status','pass','stop_time_s',t(end),'samples',numel(t),'wall_seconds',wall, ...
    'step_s',0.1,'initial',values(1,:),'final',values(end,:), ...
    'note','FMU solves full ThermoSysPro equations; seven exposed outputs are observed here. Full FMI Real inventory is audited by the companion Linux probe.');
fid=fopen(fullfile(outDir,'simulink_420s_result.json'),'w'); fprintf(fid,'%s\n',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('SIMULINK_420S_BASELINE_PASS stop=%.3f samples=%d wall=%.3f\n',t(end),numel(t),wall);
end
function closeModel(mdl)
if bdIsLoaded(mdl), bdclose(mdl); end
end
