function buildInformation = triplens_fmu_custom_build(buildInformation)
% Repair MATLAB's generic source-FMU build information for OpenModelica.
% OpenModelica FMUs can contain generated split C files that are not all
% surfaced by the generic importer. Missing those files compiles cleanly
% but fails at the final link with residualFunc*/initial-equation symbols.

srcFiles = buildInformation.getSourceFiles(true,true);
srcPaths = buildInformation.getSourcePaths(true);
incPaths = buildInformation.getIncludePaths(true);

fprintf('CUSTOM_BUILD_SOURCE_FILE_COUNT_BEFORE=%d\n',numel(srcFiles));
fprintf('CUSTOM_BUILD_SOURCE_PATH_COUNT=%d\n',numel(srcPaths));
fprintf('CUSTOM_BUILD_INCLUDE_PATH_COUNT_BEFORE=%d\n',numel(incPaths));

% Find one or more extracted FMU "sources" roots from the source files that
% MATLAB already discovered.
sourceRoots = strings(0,1);
for k = 1:numel(srcFiles)
    f = string(srcFiles{k});
    p = string(fileparts(f));
    while strlength(p) > 0
        [parent,leaf] = fileparts(p);
        if strcmpi(string(leaf),'sources')
            sourceRoots(end+1,1) = p; %#ok<AGROW>
            break;
        end
        parent = string(parent);
        if parent == p
            break;
        end
        p = parent;
    end
end
sourceRoots = unique(sourceRoots(strlength(sourceRoots)>0),'stable');
assert(~isempty(sourceRoots),'TripLens:NoOMCSourcesRoot', ...
    'Could not infer the extracted OpenModelica FMU sources root.');

% CMINPACK is built into the source FMU here, not consumed as a Windows DLL.
% Without this define MinGW can emit __imp_dpmpar_/__imp_enorm_ references.
buildInformation.addDefines('CMINPACK_NO_DLL');

existingFiles = string(srcFiles(:));
allCFiles = strings(0,1);
allCFolders = strings(0,1);
addedCount = 0;

for r = 1:numel(sourceRoots)
    root = sourceRoots(r);
    fprintf('CUSTOM_SOURCE_ROOT_%d=%s\n',r,root);
    hits = dir(fullfile(root,'**','*.c'));
    fprintf('CUSTOM_RECURSIVE_C_COUNT_ROOT_%d=%d\n',r,numel(hits));
    for k = 1:numel(hits)
        fullName = string(fullfile(hits(k).folder,hits(k).name));
        allCFiles(end+1,1) = fullName; %#ok<AGROW>
        allCFolders(end+1,1) = string(hits(k).folder); %#ok<AGROW>
        if ~any(strcmpi(existingFiles,fullName))
            buildInformation.addSourceFiles(hits(k).name,hits(k).folder, ...
                'TripLensOpenModelicaRecursive');
            existingFiles(end+1,1) = fullName; %#ok<AGROW>
            addedCount = addedCount + 1;
        end
    end
end

fprintf('CUSTOM_RECURSIVE_C_FILE_COUNT=%d\n',numel(unique(allCFiles,'stable')));
fprintf('CUSTOM_ADDED_SOURCE_FILE_COUNT=%d\n',addedCount);

% Add include roots and every directory that contains a C source. This
% covers OpenModelica runtime headers and generated split-source headers.
candidates = [string(srcPaths(:)); string(incPaths(:)); sourceRoots; allCFolders];
for k = 1:numel(srcFiles)
    f = string(srcFiles{k});
    p = string(fileparts(f));
    if strlength(p) > 0
        candidates(end+1,1) = p; %#ok<AGROW>
        pp = string(fileparts(p));
        if strlength(pp) > 0
            candidates(end+1,1) = pp; %#ok<AGROW>
        end
    end
end
for k = 1:numel(incPaths)
    p = string(incPaths{k});
    if strlength(p) > 0
        pp = string(fileparts(p));
        if strlength(pp) > 0
            candidates(end+1,1) = pp; %#ok<AGROW>
        end
    end
end

candidates = unique(candidates(strlength(candidates)>0),'stable');
existingDirs = strings(0,1);
for k = 1:numel(candidates)
    p = candidates(k);
    if isfolder(p)
        existingDirs(end+1,1) = p; %#ok<AGROW>
    end
end
existingDirs = unique(existingDirs,'stable');
if ~isempty(existingDirs)
    buildInformation.addIncludePaths(cellstr(existingDirs));
end

finalSrc = buildInformation.getSourceFiles(true,true);
finalInc = buildInformation.getIncludePaths(true);
fprintf('CUSTOM_BUILD_SOURCE_FILE_COUNT_AFTER=%d\n',numel(finalSrc));
fprintf('CUSTOM_BUILD_INCLUDE_PATH_COUNT_AFTER=%d\n',numel(finalInc));
end
