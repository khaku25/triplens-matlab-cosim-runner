param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('smoke','bfp-wrapper-check','bfp-cosim','ecms-inventory','ecms-simulate')]
    [string]$Mode
)

$ErrorActionPreference = 'Stop'

function Find-MatlabExe {
    $cmd = Get-Command matlab.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($root in @('C:\Program Files\MATLAB','C:\Program Files (x86)\MATLAB')) {
        if (Test-Path $root) {
            $candidate = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object { Join-Path $_.FullName 'bin\matlab.exe' } |
                Where-Object { Test-Path $_ } |
                Select-Object -First 1
            if ($candidate) { return $candidate }
        }
    }
    throw 'MATLAB executable was not found on this self-hosted runner.'
}

$matlab = Find-MatlabExe
Write-Host "Using MATLAB: $matlab"
$escapedMode = $Mode.Replace("'","''")
$cmd = "addpath(fullfile(pwd,'matlab')); cosim_entrypoint('$escapedMode');"
& $matlab -batch $cmd
if ($LASTEXITCODE -ne 0) {
    throw "MATLAB exited with code $LASTEXITCODE"
}
