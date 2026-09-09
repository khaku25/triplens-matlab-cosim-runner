param(
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [string]$Dest = 'C:\TripLensWarm'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$required = @('native_full_res.mat','reference.mo','capture_summary.json','native_snapshot_300.json')
foreach ($name in $required) {
  $src = Get-ChildItem -Path $SourceRoot -Filter $name -File -Recurse | Select-Object -First 1
  if (-not $src) { throw "Missing required artifact file: $name" }
  Copy-Item $src.FullName (Join-Path $Dest $name) -Force
}

$runner = @'
param(
  [Parameter(Mandatory=$true)]
  [string]$ExePath,
  [ValidateSet('cvode','dassl')]
  [string]$Solver = 'cvode',
  [double]$StartTime = 300,
  [double]$StopTime = 1000
)

$ErrorActionPreference = 'Stop'
$root = 'C:\TripLensWarm'
$state = Join-Path $root 'native_full_res.mat'
if (-not (Test-Path $state)) { throw "Warm state missing: $state" }
if (-not (Test-Path $ExePath)) { throw "Simulation executable missing: $ExePath" }

$exe = (Resolve-Path $ExePath).Path
$result = Join-Path $root ("warm_result_{0}.mat" -f $Solver)
$log = Join-Path $root ("warm_run_{0}.log" -f $Solver)
$args = @(
  "-s=$Solver",
  "-iif=$state",
  "-iit=$StartTime",
  '-iim=none',
  '-noEventEmit',
  "-override=startTime=$StartTime,stopTime=$StopTime",
  "-r=$result",
  '-lv=LOG_INIT,LOG_STATS,LOG_NLS'
)

Write-Host "EXE    : $exe"
Write-Host "STATE  : $state"
Write-Host "SOLVER : $Solver"
Write-Host "TIME   : $StartTime -> $StopTime"
Write-Host "RESULT : $result"
Write-Host "ARGS   : $($args -join ' ')"

Push-Location (Split-Path $exe -Parent)
try {
  & $exe @args 2>&1 | Tee-Object -FilePath $log
  $code = $LASTEXITCODE
}
finally {
  Pop-Location
}
Write-Host "Exit code: $code"
Write-Host "Log: $log"
exit $code
'@
Set-Content -Path (Join-Path $Dest 'run_warm_start.ps1') -Value $runner -Encoding UTF8

$readme = @'
TripLens Windows OMEdit warm-start workspace

Files:
- native_full_res.mat     : verified full internal state at t=300 s
- reference.mo            : exact Modelica source used for the snapshot
- capture_summary.json    : snapshot provenance
- native_snapshot_300.json: selected values at the restart point
- run_warm_start.ps1      : helper for a compiled OpenModelica executable

IMPORTANT
The warm state is valid only for the exact matching TripLens_CombinedCycle_TripTAC structure.
Do not use it with CombinedCycle_Load_100_50 or a structurally different model.

OMEdit test
1. Open the exact matching TripLens_CombinedCycle_TripTAC/reference model.
2. Simulation Setup: Start Time = 300, Stop Time = 1000.
3. Solver = cvode (or dassl for comparison).
4. Additional Simulation Flags:
   -iif=C:/TripLensWarm/native_full_res.mat -iit=300 -iim=none -noEventEmit

Executable test from Windows PowerShell
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\TripLensWarm\run_warm_start.ps1 -ExePath "C:\path\to\model.exe" -Solver cvode
'@
Set-Content -Path (Join-Path $Dest 'README_WARM_START.txt') -Value $readme -Encoding UTF8

$summary = Get-Content (Join-Path $Dest 'capture_summary.json') -Raw | ConvertFrom-Json
if ($summary.run_id -ne '34220970632') { throw "Unexpected snapshot run_id: $($summary.run_id)" }
if (-not (Test-Path (Join-Path $Dest 'native_full_res.mat'))) { throw 'native_full_res.mat missing' }

Get-ChildItem $Dest | Format-Table Name,Length,LastWriteTime -AutoSize
Write-Host 'WINDOWS_OMEDIT_WARM_START_WORKSPACE_READY'
Write-Host (Join-Path $Dest 'README_WARM_START.txt')
