function buildInformation = triplens_fmu_custom_build(buildInformation)
% Repair MATLAB's generic source-FMU build information for OpenModelica.
% 1) include all split OpenModelica C sources,
% 2) compile bundled cminpack as static code on Windows, and
% 3) convert source-FMU prefixed FMI entry points to DLL/shared-object entry
%    points. FMI 2.0 requires the actual fmi2* names for a DLL.

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

% The OpenModelica package is a source-code FMU, so its generated code can
% define FMI2_FUNCTION_PREFIX. That is correct for source/static linkage but
% not for the DLL we are creating for Simulink. Remove only that preprocessor
% definition from the extracted build copy. With no prefix, fmi2Functions.h
% also applies the normal Windows dllexport decoration.
prefixPat = '(?m)^[ \t]*#define[ \t]+FMI2_FUNCTION_PREFIX[^\r\n]*';
patchedPrefixFiles = 0;
for r = 1:numel(sourceRoots)
    root = sourceRoots(r);
    textHits = [dir(fullfile(root,'**','*.c')); dir(fullfile(root,'**','*.h'))];
    for k = 1:numel(textHits)
        p = fullfile(textHits(k).folder,textHits(k).name);
        txt = fileread(p);
        patched = regexprep(txt,prefixPat, ...
            '/* TripLens DLL build: FMI2_FUNCTION_PREFIX intentionally removed */');
        if ~strcmp(txt,patched)
            fid = fopen(p,'w');
            assert(fid>=0,'TripLens:PrefixPatchWrite','Could not patch FMI source file.');
            fwrite(fid,patched,'char');
            fclose(fid);
            patchedPrefixFiles = patchedPrefixFiles + 1;
            fprintf('CUSTOM_STRIPPED_FMI2_PREFIX=%s\n',p);
        end
    end
end
fprintf('CUSTOM_STRIPPED_FMI2_PREFIX_FILE_COUNT=%d\n',patchedPrefixFiles);
assert(patchedPrefixFiles>=1,'TripLens:NoFMI2PrefixFound', ...
    'No FMI2_FUNCTION_PREFIX definition was found in the extracted source FMU.');

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
