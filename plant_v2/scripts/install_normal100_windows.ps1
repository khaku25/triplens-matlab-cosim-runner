param(
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [string]$StateRoot = 'C:\TripLensStates'
)

$ErrorActionPreference = 'Stop'
$dest = Join-Path $StateRoot 'NORMAL_100'
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Find-One([string]$name) {
  $hit = Get-ChildItem -Path $SourceRoot -Filter $name -File -Recurse | Select-Object -First 1
  if (-not $hit) { throw "Missing NORMAL_100 artifact file: $name" }
  return $hit.FullName
}

$state = Find-One 'plant_v2_normal100_res.mat'
$model = Find-One 'TripLens_Plant_V2_Normal100.mo'
$report = Find-One 'normal100_report.json'

Copy-Item $state (Join-Path $dest 'state.mat') -Force
Copy-Item $model (Join-Path $dest 'TripLens_Plant_V2_Normal100.mo') -Force
Copy-Item $report (Join-Path $dest 'normal100_report.json') -Force

$reportObj = Get-Content (Join-Path $dest 'normal100_report.json') -Raw | ConvertFrom-Json
if ($reportObj.status -ne 'pass') { throw "NORMAL_100 report status is not pass" }
if ($reportObj.state -ne 'NORMAL_100') { throw "Unexpected state in report: $($reportObj.state)" }

$selector = @'
param(
  [ValidateSet('NORMAL_100','NORMAL_75','NORMAL_50','COLD_START')]
  [string]$State = 'NORMAL_100'
)
$ErrorActionPreference = 'Stop'
$root = 'C:\TripLensStates'
$src = Join-Path (Join-Path $root $State) 'state.mat'
if (-not (Test-Path $src)) {
  throw "State $State is not captured/installed yet: $src"
}
$active = Join-Path $root 'ACTIVE'
New-Item -ItemType Directory -Force -Path $active | Out-Null
Copy-Item $src (Join-Path $active 'state.mat') -Force
Set-Content -Path (Join-Path $active 'state.txt') -Value $State -Encoding ASCII
Write-Host "TRIPLENS_ACTIVE_STATE=$State"
Write-Host (Join-Path $active 'state.mat')
'@
Set-Content -Path (Join-Path $StateRoot 'select_state.ps1') -Value $selector -Encoding UTF8

# NORMAL_100 becomes the active state on first install.
& (Join-Path $StateRoot 'select_state.ps1') -State NORMAL_100

Write-Host 'PLANT_V2_NORMAL100_WINDOWS_INSTALL_PASS'
Get-ChildItem -Path $dest | Format-Table Name,Length,LastWriteTime -AutoSize
