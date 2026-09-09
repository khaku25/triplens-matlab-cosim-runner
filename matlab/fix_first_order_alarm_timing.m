function fix_first_order_alarm_timing()
%FIX_FIRST_ORDER_ALARM_TIMING Use simulation time, not sample counts, for
% Layer1 drum H/HH/L/LL delays. This keeps a 0.5 s delay equal to 0.5 s when
% Thermo updates at 0.1 s and ECMS protection executes at 0.001 s.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
settingsPath=fullfile(repoRoot,'ecms_logic','drum_level_first_order_settings.csv');
T=readtable(settingsPath,'TextType','string','VariableNamingRule','preserve');

mdrive='';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable');
modelName='TripLens_ECMS_DigitalTwin';
modelPath=fullfile(mdrive,'TripLens_ECMS_DigitalTwin',[modelName '.slx']);
assert(isfile(modelPath),'TripLens:MissingECMSModel');

if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath);
cleanup=onCleanup(@() close_system(modelName,0)); %#ok<NASGU>
sub=[modelName '/First_Order_Drum_Alarms'];
logic=[sub '/Logic'];
assert(getSimulinkBlockHandle(sub)~=-1 && getSimulinkBlockHandle(logic)~=-1, ...
    'TripLens:MissingLayer1Logic','First_Order_Drum_Alarms/Logic is missing.');

clock=[sub '/Simulation_Time'];
if getSimulinkBlockHandle(clock)==-1
    add_block('simulink/Sources/Clock',clock,'Position',[25 260 95 280]);
end
rt=sfroot; chart=rt.find('-isa','Stateflow.EMChart','Path',logic);
assert(~isempty(chart),'TripLens:AlarmFunction','Could not resolve Layer1 MATLAB Function.');
chart.Script=clockBasedCode(T);
set_param(modelName,'SimulationCommand','update');

% Recreate only the internal Clock -> fourth function-input line.
try
    ph=get_param(logic,'PortHandles');
    if numel(ph.Inport)>=4
        old=get_param(ph.Inport(4),'Line');
        if old~=-1, delete_line(old); end
    end
catch
end
add_line(sub,'Simulation_Time/1','Logic/4','autorouting','on');
set_param(modelName,'SimulationCommand','update');
set_param(sub,'Description',['Layer1 model-backed drum H/HH/L/LL. Delay uses simulation absolute time, ' ...
    'so 0.5 s remains 0.5 s across the 0.1 s Thermo / 1 ms ECMS rate boundary.']);
save_system(modelName,modelPath);

outDir=fullfile(repoRoot,'outputs'); if ~isfolder(outDir), mkdir(outDir); end
report=struct();
report.model=modelName;
report.layer1_timing='SIMULATION_CLOCK_DURATION';
report.thermo_nominal_sample_s=0.1;
report.ecms_logic_sample_s=0.001;
report.settings_file=settingsPath;
report.alarm_count=height(T);
report.status='INSTALLED';
report.note='Thresholds are model absolute values, not approved plant settings.';
fid=fopen(fullfile(outDir,'first_order_alarm_timing_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
fprintf('TRIPLENS LAYER1 CLOCK-TIMING INSTALLED\nALARMS=%d\n',height(T));
end

function code=clockBasedCode(T)
order={ ...
    'hp_drum_level','H','hp','hpH'; 'hp_drum_level','HH','hp','hpHH'; ...
    'hp_drum_level','L','hp','hpL'; 'hp_drum_level','LL','hp','hpLL'; ...
    'ip_drum_level','H','ip','ipH'; 'ip_drum_level','HH','ip','ipHH'; ...
    'ip_drum_level','L','ip','ipL'; 'ip_drum_level','LL','ip','ipLL'; ...
    'lp_drum_level','H','lp','lpH'; 'lp_drum_level','HH','lp','lpHH'; ...
    'lp_drum_level','L','lp','lpL'; 'lp_drum_level','LL','lp','lpLL'};
lines={'function [hpH,hpHH,hpL,hpLL,ipH,ipHH,ipL,ipLL,lpH,lpHH,lpL,lpLL] = Logic(hp,ip,lp,t)'};
lines{end+1}='persistent t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12';
lines{end+1}='persistent s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12';
lines{end+1}='if isempty(t1)';
lines{end+1}='  t1=-1;t2=-1;t3=-1;t4=-1;t5=-1;t6=-1;t7=-1;t8=-1;t9=-1;t10=-1;t11=-1;t12=-1;';
lines{end+1}='  s1=false;s2=false;s3=false;s4=false;s5=false;s6=false;s7=false;s8=false;s9=false;s10=false;s11=false;s12=false;';
lines{end+1}='end';
for k=1:12
    row=T(T.signal==string(order{k,1}) & T.alarm_type==string(order{k,2}),:);
    assert(height(row)==1,'TripLens:Layer1Setting','Expected one %s %s row.',order{k,1},order{k,2});
    th=row.threshold_m(1); hy=row.hysteresis_m(1); delay=row.delay_s(1);
    if isstring(th), th=str2double(th); end
    if isstring(hy), hy=str2double(hy); end
    if isstring(delay), delay=str2double(delay); end
    x=order{k,3}; s=['s' num2str(k)]; timer=['t' num2str(k)];
    high=strcmpi(char(row.direction(1)),'HIGH');
    lines{end+1}=sprintf('TH%d=%.17g; HY%d=%.17g; DEL%d=%.17g;',k,th,k,hy,k,delay); %#ok<AGROW>
    lines{end+1}=sprintf('if %s',s); %#ok<AGROW>
    if high
        lines{end+1}=sprintf('  if %s <= TH%d-HY%d; %s=false; %s=-1; end',x,k,k,s,timer); %#ok<AGROW>
    else
        lines{end+1}=sprintf('  if %s >= TH%d+HY%d; %s=false; %s=-1; end',x,k,k,s,timer); %#ok<AGROW>
    end
    lines{end+1}='else'; %#ok<AGROW>
    if high
        cond=sprintf('%s >= TH%d',x,k);
    else
        cond=sprintf('%s <= TH%d',x,k);
    end
    lines{end+1}=sprintf('  if %s',cond); %#ok<AGROW>
    lines{end+1}=sprintf('    if %s < 0; %s=t; end',timer,timer); %#ok<AGROW>
    lines{end+1}=sprintf('    if (t-%s) >= DEL%d; %s=true; end',timer,k,s); %#ok<AGROW>
    lines{end+1}=sprintf('  else; %s=-1; end',timer); %#ok<AGROW>
    lines{end+1}='end'; %#ok<AGROW>
end
for k=1:12, lines{end+1}=sprintf('%s=s%d;',order{k,4},k); end %#ok<AGROW>
lines{end+1}='end';
code=strjoin(lines,newline);
end
