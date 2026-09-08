function export_ecms_traceability()
%EXPORT_ECMS_TRACEABILITY Inspect and label the installed ECMS logic boundary.
% Internal Simulink wiring and external physical/tag binding are reported separately.

repoRoot=getenv('GITHUB_WORKSPACE');
if isempty(repoRoot), repoRoot=fileparts(fileparts(mfilename('fullpath'))); end
outDir=fullfile(repoRoot,'outputs');
if ~isfolder(outDir), mkdir(outDir); end
interfacePath=fullfile(repoRoot,'ecms_logic','a_logic_interface_v1.csv');
T=readtable(interfacePath,'TextType','string','VariableNamingRule','preserve');

mdrive='';
try
    if exist('matlabdrive','file')==2, mdrive=matlabdrive; end
catch
end
if isempty(mdrive)
    candidate=fullfile(getenv('USERPROFILE'),'MATLAB Drive');
    if isfolder(candidate), mdrive=candidate; end
end
assert(~isempty(mdrive) && isfolder(mdrive),'TripLens:MATLABDriveUnavailable', ...
    'MATLAB Drive local folder is unavailable.');

modelName='TripLens_ECMS_DigitalTwin';
modelPath=fullfile(mdrive,'TripLens_ECMS_DigitalTwin',[modelName '.slx']);
modelsDir=fullfile(mdrive,'TripLens_ECMS_DigitalTwin','models');
assert(isfolder(modelsDir),'TripLens:MissingModelsDirectory', ...
    'ECMS referenced-model folder does not exist: %s',modelsDir);
addpath(modelsDir,'-begin');
cleanupPath=onCleanup(@() rmpath(modelsDir)); %#ok<NASGU>
target=[modelName '/Protection_Control'];
if bdIsLoaded(modelName), close_system(modelName,0); end
load_system(modelPath);
cleanupModel=onCleanup(@() close_system(modelName,0)); %#ok<NASGU>
assert(getSimulinkBlockHandle(target)~=-1,'TripLens:MissingProtectionTarget', ...
    'Protection_Control subsystem does not exist.');

n=height(T);
blockExists=false(n,1); internalConnected=false(n,1); externalConnected=false(n,1);
externalTagDeclared=false(n,1); internalStatus=strings(n,1); externalStatus=strings(n,1);
blockPath=strings(n,1); tagDisplay=strings(n,1);
targetPorts=get_param(target,'PortHandles');

for k=1:n
    signal=char(T.signal_name(k));
    direction=upper(char(T.direction(k)));
    blockPath(k)=string([target '/' signal]);
    blockExists(k)=getSimulinkBlockHandle(char(blockPath(k)))~=-1;
    bound=string(T.bound_tag(k));
    if ismissing(bound), bound=""; end
    bound=strtrim(bound);
    externalTagDeclared(k)=strlength(bound)>0;
    if externalTagDeclared(k), tagDisplay(k)=bound; else, tagDisplay(k)="실제 외부 태그 연결 대기"; end
    if blockExists(k)
        portNumber=str2double(get_param(char(blockPath(k)),'Port'));
        handles=get_param(char(blockPath(k)),'LineHandles');
        if strcmp(direction,'IN')
            internalConnected(k)=any(handles.Outport~=-1);
            if portNumber<=numel(targetPorts.Inport)
                externalConnected(k)=get_param(targetPorts.Inport(portNumber),'Line')~=-1;
            end
        else
            internalConnected(k)=any(handles.Inport~=-1);
            if portNumber<=numel(targetPorts.Outport)
                externalConnected(k)=get_param(targetPorts.Outport(portNumber),'Line')~=-1;
            end
        end
        [background,foreground]=signalColor(char(T.source_layer(k)),direction,char(T.status(k)));
        label=sprintf('SOURCE: %s\nTAG: %s\nSTATE: %s', ...
            char(T.source_layer(k)),char(tagDisplay(k)),char(T.status(k)));
        set_param(char(blockPath(k)),'BackgroundColor',background, ...
            'ForegroundColor',foreground,'FontWeight','bold', ...
            'AttributesFormatString',label,'Description',sprintf('%s\n%s',char(T.role(k)),label));
    end
    if blockExists(k) && internalConnected(k)
        internalStatus(k)="CONNECTED_TO_A_LOGIC_CORE";
    else
        internalStatus(k)="INTERNAL_WIRE_MISSING";
    end
    if externalConnected(k) && externalTagDeclared(k)
        externalStatus(k)="EXTERNAL_LINE_AND_TAG_DECLARED";
    elseif externalConnected(k)
        externalStatus(k)="EXTERNAL_LINE_TAG_PENDING";
    elseif externalTagDeclared(k)
        externalStatus(k)="TAG_DECLARED_LINE_PENDING";
    else
        externalStatus(k)="EXTERNAL_LINE_AND_TAG_PENDING";
    end
end

set_param(target,'Description',sprintf([ ...
    'TripLens ECMS visual traceability boundary. %d internal ports verified. ' ...
    'External physical wiring remains separately reported; empty binding is not treated as complete.'], ...
    sum(internalConnected)));
save_system(modelName,modelPath);

R=table(T.signal_name,T.direction,T.data_type,T.source_layer,T.role,T.status, ...
    T.bound_tag,blockPath,blockExists,internalConnected,externalConnected, ...
    externalTagDeclared,internalStatus,externalStatus, ...
    'VariableNames',{'signal_name','direction','data_type','source_layer','role', ...
    'declared_status','bound_tag','block_path','block_exists','internal_connected', ...
    'external_line_connected','external_tag_declared','internal_wire_status', ...
    'external_binding_status'});
writetable(R,fullfile(outDir,'ecms_port_traceability.csv'),'Encoding','UTF-8');

pngPath=fullfile(outDir,'ecms_protection_control.png');
pngGenerated=false; pngMessage='';
try
    open_system(target);
    set_param(target,'ZoomFactor','FitSystem');
    print(['-s' target],'-dpng','-r150',pngPath);
    pngGenerated=isfile(pngPath);
catch imageErr
    pngMessage=imageErr.message;
end

report=struct();
report.model=modelName; report.model_path=modelPath; report.target=target;
report.port_count=n; report.input_count=sum(T.direction=="IN");
report.output_count=sum(T.direction=="OUT");
report.block_exists_count=sum(blockExists);
report.internal_connected_count=sum(internalConnected);
report.external_line_connected_count=sum(externalConnected);
report.external_tag_declared_count=sum(externalTagDeclared);
report.end_to_end_complete_count=sum(externalConnected & externalTagDeclared & internalConnected);
report.logic_hierarchy={'GT_Trip_Protection','Bus_Protection_Transfer','ST_State_Monitor'};
report.png_generated=pngGenerated; report.png_message=pngMessage;
report.ports=table2struct(R);
report.note=['Internal connection means the ECMS boundary port is wired to A Logic Core. ' ...
    'It does not mean the external Electrical/Thermo physical source is already wired.'];
fid=fopen(fullfile(outDir,'ecms_traceability_report.json'),'w','n','UTF-8');
assert(fid>=0,'TripLens:ReportWrite','Could not write ECMS traceability report.');
fprintf(fid,'%s',jsonencode(report,'PrettyPrint',true)); fclose(fid);
writeHtml(fullfile(outDir,'ecms_traceability_report.html'),R,report);

assert(sum(blockExists)==n,'TripLens:MissingECMSPort','One or more ECMS interface blocks are missing.');
assert(sum(internalConnected)==n,'TripLens:MissingInternalWire','One or more ECMS ports are not connected to A Logic Core.');
fprintf(['TRIPLENS ECMS TRACEABILITY EXPORTED\nPORTS=%d\nINTERNAL_CONNECTED=%d\n' ...
    'EXTERNAL_LINES=%d\nEXTERNAL_TAGS=%d\nEND_TO_END=%d\n'], ...
    n,sum(internalConnected),sum(externalConnected),sum(externalTagDeclared), ...
    report.end_to_end_complete_count);
end

function [background,foreground]=signalColor(layer,direction,status)
foreground='black';
if contains(status,'DISABLED')
    background='gray'; foreground='white'; return
end
if strcmp(direction,'OUT')
    background='orange'; return
end
if contains(layer,'ELECTRICAL')
    background='cyan';
elseif contains(layer,'THERMO')
    background='green'; foreground='white';
elseif contains(layer,'COMMAND') || contains(layer,'SETTING')
    background='lightBlue';
else
    background='yellow';
end
end

function writeHtml(path,R,report)
fid=fopen(path,'w','n','UTF-8');
assert(fid>=0,'TripLens:HtmlWrite','Could not write ECMS HTML report.');
cleanup=onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,['<!doctype html><html lang="ko"><head><meta charset="utf-8">' ...
    '<meta name="viewport" content="width=device-width,initial-scale=1">' ...
    '<title>TripLens ECMS 배선 확인</title><style>' ...
    'body{margin:0;background:#eef1f5;color:#172033;font-family:"Malgun Gothic",Arial,sans-serif}' ...
    'header{background:#101d33;color:white;padding:20px;border-bottom:5px solid #263f67}' ...
    'main{padding:18px}.cards{display:grid;grid-template-columns:repeat(5,1fr);gap:10px}' ...
    '.card{background:white;border:1px solid #c9d1dc;border-left:5px solid #1261a0;padding:12px}' ...
    '.card b{font-size:24px;display:block}table{width:100%%;border-collapse:collapse;background:white;margin-top:16px}' ...
    'th{background:#dce2ea;text-align:left;padding:8px}td{border-bottom:1px solid #e2e6ec;padding:8px;vertical-align:top}' ...
    '.ok{color:#147a4d;font-weight:bold}.wait{color:#c55300;font-weight:bold}code{font-size:11px}' ...
    '@media(max-width:900px){.cards{grid-template-columns:1fr 1fr}table{font-size:11px}}</style></head><body>' ...
    '<header><h1>ECMS 실제 배선 확인</h1><p>내부 A Logic 연결과 외부 물리 태그 연결을 분리해 표시합니다.</p></header><main>']);
cards={ ...
    '전체 포트',report.port_count; '내부 연결',report.internal_connected_count; ...
    '외부 신호선',report.external_line_connected_count; '외부 태그 지정',report.external_tag_declared_count; ...
    'End-to-End',report.end_to_end_complete_count};
fprintf(fid,'<section class="cards">');
for k=1:size(cards,1), fprintf(fid,'<div class="card"><b>%d</b>%s</div>',cards{k,2},cards{k,1}); end
fprintf(fid,'</section><table><thead><tr><th>방향</th><th>포트</th><th>출처</th><th>역할</th><th>내부</th><th>외부 태그/선</th></tr></thead><tbody>');
for k=1:height(R)
    if R.internal_connected(k), cls='ok'; else, cls='wait'; end
    fprintf(fid,['<tr><td>%s</td><td><code>%s</code></td><td>%s</td><td>%s</td>' ...
        '<td class="%s">%s</td><td class="wait"><code>%s</code><br>%s</td></tr>'], ...
        htmlEscape(R.direction(k)),htmlEscape(R.signal_name(k)),htmlEscape(R.source_layer(k)), ...
        htmlEscape(R.role(k)),cls,htmlEscape(R.internal_wire_status(k)), ...
        htmlEscape(displayBinding(R.bound_tag(k))),htmlEscape(R.external_binding_status(k)));
end
fprintf(fid,'</tbody></table></main></body></html>');
end

function value=displayBinding(bound)
bound=string(bound);
if ismissing(bound) || strlength(strtrim(bound))==0
    value="실제 외부 태그 연결 대기";
else
    value=bound;
end
end

function out=htmlEscape(value)
value=string(value);
if ismissing(value), value=""; end
out=char(value);
out=strrep(out,'&','&amp;'); out=strrep(out,'<','&lt;');
out=strrep(out,'>','&gt;'); out=strrep(out,'"','&quot;');
end
