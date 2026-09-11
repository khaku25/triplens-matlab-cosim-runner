function build_trip_breaker_semantics_core()
%BUILD_TRIP_BREAKER_SEMANTICS_CORE Canonical Trip semantics for TripLens.
%
% Definition:
%   TRIP request = logical request signal (active high)
%   TRIP success = associated breaker CLOSED feedback becomes 0 and latches open.
%   DERATING is explicitly not TRIP and must not open a breaker.
%
% This core is an electrical-state actuator contract. It does not synthesize
% process physics and it does not treat reduced MW/flow/temperature as a Trip.
% A separate feedback path exposes an unexpected 52GT-open-while-running
% condition. That observed condition, rather than the OPEN command itself,
% becomes the downstream GT Trip request used by the physical co-simulation.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs'); if ~isfolder(outDir), mkdir(outDir); end
Ts=0.001;
modelName='TripLens_ECMS_Trip_Breaker_Semantics_Core';
modelPath=fullfile(outDir,[modelName '.slx']);
if bdIsLoaded(modelName), close_system(modelName,0); end
if isfile(modelPath), delete(modelPath); end
new_system(modelName);
set_param(modelName,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
    'FixedStep','0.001','StopTime','1.0','SaveOutput','on','OutputSaveName','yout', ...
    'SaveFormat','Dataset','Description',[ ...
    'Canonical TripLens Trip semantics: a Trip is only successful when the associated breaker CLOSED state is 0. ' ...
    'Derating never opens a breaker.']);

inputs={'gt_trip_request','st_trip_request','fwp_hp_trip_request','fwp_ip_trip_request', ...
    'fwp_lp_trip_request','cb_in_a_trip_request','cb_in_b_trip_request','cb_tie_ab_trip_request', ...
    'cb_52gt_direct_trip','cb_52st_direct_trip','gt_derating_active','gt_in_service'};
for k=1:numel(inputs)
    y=30+(k-1)*45;
    add_block('simulink/Sources/In1',[modelName '/' inputs{k}], ...
        'Port',num2str(k),'OutDataTypeStr','boolean','Position',[20 y 190 y+22]);
end

sub=[modelName '/Breaker_State_Actuator'];
add_block('simulink/Ports & Subsystems/Subsystem',sub,'Position',[350 80 720 560]);
buildActuator(sub,Ts);
for k=1:11
    add_line(modelName,[inputs{k} '/1'],['Breaker_State_Actuator/' num2str(k)],'autorouting','on');
end

outputs={'cb_52gt_closed','cb_52st_closed','vcb_a01_closed','vcb_b01_closed','vcb_a02_closed', ...
    'cb_in_a_closed','cb_in_b_closed','cb_tie_ab_closed','gt_trip_from_52gt_open'};
for k=1:numel(outputs)
    y=80+(k-1)*55;
    add_block('simulink/Sinks/Out1',[modelName '/' outputs{k}], ...
        'Port',num2str(k),'OutDataTypeStr','boolean','Position',[850 y 1040 y+22]);
    if k<=8
        add_line(modelName,['Breaker_State_Actuator/' num2str(k)],[outputs{k} '/1'],'autorouting','on');
    end
end

% Detect the actual breaker feedback after the stateful actuator has opened.
% gt_in_service is an explicit scenario/precondition input, so a breaker that
% is open while the unit is already out of service cannot create a false Trip.
notClosed=[modelName '/Not_52GT_Closed'];
openWhileRunning=[modelName '/52GT_Open_While_Running'];
add_block('simulink/Logic and Bit Operations/Logical Operator',notClosed, ...
    'Operator','NOT','Position',[750 525 795 555]);
add_block('simulink/Logic and Bit Operations/Logical Operator',openWhileRunning, ...
    'Operator','AND','Inputs','2','Position',[805 520 840 565]);
add_line(modelName,'Breaker_State_Actuator/1','Not_52GT_Closed/1','autorouting','on');
add_line(modelName,'Not_52GT_Closed/1','52GT_Open_While_Running/1','autorouting','on');
add_line(modelName,'gt_in_service/1','52GT_Open_While_Running/2','autorouting','on');
add_line(modelName,'52GT_Open_While_Running/1','gt_trip_from_52gt_open/1','autorouting','on');

set_param(modelName,'SimulationCommand','update');
save_system(modelName,modelPath);

% Regression matrix. All simulations begin with breakers CLOSED=1.
checks=struct();
checks.baseline = runCase(modelName,inputs,[],outputs,[1 1 1 1 1 1 1 1 0]);
checks.gt_trip = runCase(modelName,inputs,{'gt_trip_request'},outputs,[0 1 1 1 1 1 1 1 0]);
checks.st_trip = runCase(modelName,inputs,{'st_trip_request'},outputs,[1 0 1 1 1 1 1 1 0]);
checks.fwp_hp_trip = runCase(modelName,inputs,{'fwp_hp_trip_request'},outputs,[1 1 0 1 1 1 1 1 0]);
checks.fwp_ip_trip = runCase(modelName,inputs,{'fwp_ip_trip_request'},outputs,[1 1 1 0 1 1 1 1 0]);
checks.fwp_lp_trip = runCase(modelName,inputs,{'fwp_lp_trip_request'},outputs,[1 1 1 1 0 1 1 1 0]);
checks.in_a_trip = runCase(modelName,inputs,{'cb_in_a_trip_request'},outputs,[1 1 1 1 1 0 1 1 0]);
checks.in_b_trip = runCase(modelName,inputs,{'cb_in_b_trip_request'},outputs,[1 1 1 1 1 1 0 1 0]);
checks.tie_trip = runCase(modelName,inputs,{'cb_tie_ab_trip_request'},outputs,[1 1 1 1 1 1 1 0 0]);
checks.direct_52gt_trip_out_of_service = runCase(modelName,inputs,{'cb_52gt_direct_trip'},outputs,[0 1 1 1 1 1 1 1 0]);
checks.running_52gt_open_causes_gt_trip = runCase(modelName,inputs, ...
    {'cb_52gt_direct_trip','gt_in_service'},outputs,[0 1 1 1 1 1 1 1 1]);
checks.direct_52st_trip = runCase(modelName,inputs,{'cb_52st_direct_trip'},outputs,[1 0 1 1 1 1 1 1 0]);
checks.derating_keeps_breakers_closed = runCase(modelName,inputs,{'gt_derating_active'},outputs,[1 1 1 1 1 1 1 1 0]);

% Common-protection resolved requests are tested together: GT request already
% causes ST request in Common_Trip_Matrix. This case proves both breakers open.
checks.gt_with_st_intertrip = runCase(modelName,inputs,{'gt_trip_request','st_trip_request'},outputs,[0 0 1 1 1 1 1 1 0]);

pass=all(structfun(@(x)logical(x),checks));
report=struct();
report.model=modelName;
report.model_path=modelPath;
report.pass=pass;
report.definition='TRIP_SUCCESS_IFF_ASSOCIATED_BREAKER_CLOSED_FEEDBACK_EQUALS_0';
report.trip_request_active_value=1;
report.required_breaker_closed_value_after_trip=0;
report.derating_definition='PROCESS_VALUE_REDUCTION_WITH_BREAKER_REMAINING_CLOSED';
report.derating_opens_breaker=false;
report.gt_trip_intertrip_policy='GT request is resolved upstream to GT+ST requests; therefore 52GT.CLOSED=0 and 52ST.CLOSED=0';
report.breaker_open_trip_policy='GT_IN_SERVICE AND NOT 52GT.CLOSED -> GT_TRIP_FROM_52GT_OPEN';
report.breaker_open_trip_status='VPP_PROVISIONAL_NOT_PLANT_LOGIC';
report.st_trip_policy='52ST.CLOSED=0 only';
report.drum_hh_policy='resolved upstream as ST request only -> 52ST.CLOSED=0';
report.drum_ll_policy='resolved upstream as GT+ST requests -> both generator breakers CLOSED=0';
report.checks=checks;
report.scope_note=['This model validates breaker-state semantics only. FWP-IP/LP and incoming/tie physical process/electrical ' ...
    'network actuation remain separate implementation tasks even though their breaker-open contract is now explicit.'];
reportPath=fullfile(outDir,'trip_breaker_semantics_report.json');
fid=fopen(reportPath,'w','n','UTF-8'); assert(fid>=0);
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);

fprintf('TRIPLENS TRIP BREAKER SEMANTICS PASS=%d\n',pass);
fprintf('TRIP_SUCCESS_REQUIRED_BREAKER_CLOSED=0\n');
fprintf('DERATING_BREAKER_CLOSED=1\n');
if ~pass, error('TripLens:TripBreakerSemanticsFailed','Trip breaker semantics regression failed.'); end
close_system(modelName,0);
end

function buildActuator(sub,Ts)
Simulink.SubSystem.deleteContents(sub);
inputs={'GT_Trip','ST_Trip','FWP_HP_Trip','FWP_IP_Trip','FWP_LP_Trip', ...
    'IN_A_Trip','IN_B_Trip','TIE_Trip','Direct_52GT_Trip','Direct_52ST_Trip','GT_Derating'};
for k=1:numel(inputs)
    y=25+(k-1)*32;
    add_block('simulink/Sources/In1',[sub '/' inputs{k}],'Port',num2str(k),'Position',[20 y 145 y+20]);
end
outs={'52GT_CLOSED','52ST_CLOSED','VCB_A01_CLOSED','VCB_B01_CLOSED','VCB_A02_CLOSED', ...
    'IN_A_CLOSED','IN_B_CLOSED','TIE_AB_CLOSED'};
for k=1:numel(outs)
    y=35+(k-1)*48;
    add_block('simulink/Sinks/Out1',[sub '/' outs{k}],'Port',num2str(k),'Position',[650 y 790 y+20]);
end

% Stateful breaker positions: trip can only drive 1->0. There is deliberately
% no reset=reclose shortcut. A future CLOSE command must be a separate permissive path.
for k=1:8
    d=[sub '/State_' num2str(k)];
    add_block('simulink/Discrete/Unit Delay',d,'SampleTime',num2str(Ts), ...
        'InitialCondition','1','Position',[420 25+(k-1)*48 485 50+(k-1)*48]);
    add_line(sub,['State_' num2str(k) '/1'],[outs{k} '/1'],'autorouting','on');
end

logic=[sub '/Next_State_Logic'];
add_block('simulink/User-Defined Functions/MATLAB Function',logic,'Position',[190 45 355 435]);
rt=sfroot; chart=rt.find('-isa','Stateflow.EMChart','Path',logic);
chart.Script=strjoin({ ...
'function [nGT,nST,nA01,nB01,nA02,nINA,nINB,nTIE] = Logic(gt,st,hp,ip,lp,ina,inb,tie,d52gt,d52st,derate,cGT,cST,cA01,cB01,cA02,cINA,cINB,cTIE)', ...
'% Derating is intentionally ignored by breaker logic.', ...
'gt=gt>0.5; st=st>0.5; hp=hp>0.5; ip=ip>0.5; lp=lp>0.5;', ...
'ina=ina>0.5; inb=inb>0.5; tie=tie>0.5; d52gt=d52gt>0.5; d52st=d52st>0.5;', ...
'nGT = (cGT>0.5) && ~(gt || d52gt);', ...
'nST = (cST>0.5) && ~(st || d52st);', ...
'nA01 = (cA01>0.5) && ~hp;', ...
'nB01 = (cB01>0.5) && ~ip;', ...
'nA02 = (cA02>0.5) && ~lp;', ...
'nINA = (cINA>0.5) && ~ina;', ...
'nINB = (cINB>0.5) && ~inb;', ...
'nTIE = (cTIE>0.5) && ~tie;', ...
'end'},newline);

for k=1:11, add_line(sub,[inputs{k} '/1'],['Next_State_Logic/' num2str(k)],'autorouting','on'); end
for k=1:8
    add_line(sub,['State_' num2str(k) '/1'],['Next_State_Logic/' num2str(11+k)],'autorouting','on');
    add_line(sub,['Next_State_Logic/' num2str(k)],['State_' num2str(k) '/1'],'autorouting','on');
end
set_param(sub,'Description','Trip actuator: active Trip request latches associated breaker CLOSED state to 0; no reset-based reclose.');
end

function ok=runCase(modelName,inputNames,activeNames,outputNames,expected)
Ts=0.001; t=(0:Ts:0.05)'; N=numel(t);
ds=Simulink.SimulationData.Dataset;
for k=1:numel(inputNames)
    v=false(N,1);
    if any(strcmp(inputNames{k},activeNames)), v(t>=0.010)=true; end
    ts=timeseries(v,t); ts.Name=inputNames{k}; ts=setinterpmethod(ts,'zoh');
    ds=ds.addElement(ts,inputNames{k});
end
simIn=Simulink.SimulationInput(modelName); simIn=simIn.setExternalInput(ds); simIn=simIn.setModelParameter('StopTime','0.05');
out=sim(simIn); y=out.yout;
actual=zeros(1,numel(outputNames));
for k=1:numel(outputNames)
    s=y.getElement(k).Values.Data; actual(k)=double(s(end));
end
ok=isequal(actual,double(expected));
if ~ok
    error('TripLens:TripBreakerCaseFailed','Expected [%s], got [%s].',num2str(expected),num2str(actual));
end
end
