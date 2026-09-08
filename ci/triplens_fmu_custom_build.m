function buildInformation = triplens_fmu_custom_build(buildInformation)
% Add OpenModelica FMU source include roots that MATLAB's generic FMU
% source compiler may not infer from nested source files.

srcFiles = buildInformation.getSourceFiles(true,true);
srcPaths = buildInformation.getSourcePaths(true);
incPaths = buildInformation.getIncludePaths(true);

fprintf('CUSTOM_BUILD_SOURCE_FILE_COUNT=%d\n',numel(srcFiles));
fprintf('CUSTOM_BUILD_SOURCE_PATH_COUNT=%d\n',numel(srcPaths));
fprintf('CUSTOM_BUILD_INCLUDE_PATH_COUNT_BEFORE=%d\n',numel(incPaths));

candidates = string(srcPaths(:));
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

% Existing include paths are useful anchors. Their parents often contain
% the root OpenModelica runtime headers such as omc_simulation_settings.h.
for k = 1:numel(incPaths)
    p = string(incPaths{k});
    if strlength(p) > 0
        candidates(end+1,1) = p; %#ok<AGROW>
        pp = string(fileparts(p));
        if strlength(pp) > 0
            candidates(end+1,1) = pp; %#ok<AGROW>
        end
    end
end

candidates = unique(candidates(strlength(candidates)>0),'stable');
existing = strings(0,1);
for k = 1:numel(candidates)
    p = candidates(k);
    if isfolder(p)
        existing(end+1,1) = p; %#ok<AGROW>
    end
end
existing = unique(existing,'stable');

if ~isempty(existing)
    buildInformation.addIncludePaths(cellstr(existing));
end

finalInc = buildInformation.getIncludePaths(true);
fprintf('CUSTOM_BUILD_INCLUDE_PATH_COUNT_AFTER=%d\n',numel(finalInc));
for k = 1:numel(finalInc)
    fprintf('CUSTOM_INCLUDE_%d=%s\n',k,finalInc{k});
end
end
