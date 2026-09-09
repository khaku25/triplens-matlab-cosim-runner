param(
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$ModelSource,
  [string]$Dest = 'C:\TripLensWarm'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$state = Get-ChildItem -Path $SourceRoot -Filter 'normal_hold_full_res.mat' -File -Recurse | Select-Object -First 1
if (-not $state) { throw 'normal_hold_full_res.mat not found in artifact' }
Copy-Item $state.FullName (Join-Path $Dest 'normal_hold_res.mat') -Force

foreach ($name in @('normal_hold_capture_summary.json','normal_hold_snapshot_300.json')) {
  $src = Get-ChildItem -Path $SourceRoot -Filter $name -File -Recurse | Select-Object -First 1
  if ($src) { Copy-Item $src.FullName (Join-Path $Dest $name) -Force }
}

if (-not (Test-Path $ModelSource)) { throw "Model source not found: $ModelSource" }
Copy-Item $ModelSource (Join-Path $Dest 'TripLens_CombinedCycle_NormalHold.mo') -Force

$readme = @'
TripLens NORMAL HOLD model

Open in OMEdit:
  C:\TripLensWarm\TripLens_CombinedCycle_NormalHold.mo

Default behavior:
- Warm start from the verified t=300 s normal operating state.
- CVODE.
- 300 s -> 1000 s.
- GT exhaust flow held at 606.94 kg/s.
- GT exhaust temperature held at 893.75 K.
- No scheduled GT trip.

The model already stores these OpenModelica flags:
  iif=C:/TripLensWarm/normal_hold_res.mat
  iit=300
  iim=none

So after loading the matching pinned ThermoSysPro library, the intended test is simply Simulate.

IMPORTANT:
If the physical model structure changes (for example a new dynamic pump adds states), regenerate the normal-hold full-state snapshot before using this warm start again.
'@
Set-Content -Path (Join-Path $Dest 'README_NORMAL_HOLD.txt') -Value $readme -Encoding UTF8

Get-ChildItem $Dest | Format-Table Name,Length,LastWriteTime -AutoSize
Write-Host 'WINDOWS_NORMAL_HOLD_WORKSPACE_READY'
