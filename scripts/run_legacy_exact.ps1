param(
    [double]$TripTime = 600,
    [double]$TripRampDuration = 5,
    [double]$StopTime = 1000,
    [int]$Intervals = 1000
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$legacyDir = Join-Path $repoRoot 'legacy_action'
$outputDir = Join-Path $repoRoot 'outputs\legacy_exact'
$legacyRepo = 'https://github.com/khaku25/triplens-thermosyspro-cloud-runner.git'
$legacyCommit = '6fd1824880f97c957ba5a04013f3d789fb1dbd5d'
$thermoRepo = 'https://github.com/Dwarf-Planet-Project/ThermoSysPro.git'
$thermoCommit = 'db81ae1b5a6a85f6c6c7693244cafa6087e18ff5'
$omImage = 'openmodelica/openmodelica:v1.27.0-minimal'

function Require-Exe([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Required executable not found: $name" }
    return $cmd.Source
}

$git = Require-Exe 'git.exe'
$docker = Require-Exe 'docker.exe'

if (Test-Path $legacyDir) {
    cmd /c "rmdir /s /q `"$legacyDir`"" | Out-Null
}
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Host "Cloning exact legacy Action repository..."
& $git clone --no-checkout $legacyRepo $legacyDir
& $git -C $legacyDir checkout --detach $legacyCommit
$actualLegacy = (& $git -C $legacyDir rev-parse HEAD).Trim()
if ($actualLegacy -ne $legacyCommit) { throw "Legacy Action SHA mismatch: $actualLegacy" }
Write-Host "Legacy Action SHA verified: $actualLegacy"

$thermoDir = Join-Path $legacyDir 'vendor\ThermoSysPro'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $thermoDir) | Out-Null
Write-Host "Cloning exact ThermoSysPro revision used by legacy Action..."
& $git clone --no-checkout $thermoRepo $thermoDir
& $git -C $thermoDir checkout --detach $thermoCommit
$actualThermo = (& $git -C $thermoDir rev-parse HEAD).Trim()
if ($actualThermo -ne $thermoCommit) { throw "ThermoSysPro SHA mismatch: $actualThermo" }
Write-Host "ThermoSysPro SHA verified: $actualThermo"

$python = Get-Command py.exe -ErrorAction SilentlyContinue
if ($python) {
    $pythonExe = $python.Source
    $pythonArgs = @('-3')
} else {
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $pythonCmd) { throw 'Python not found (py.exe or python.exe required).' }
    $pythonExe = $pythonCmd.Source
    $pythonArgs = @()
}

$render = Join-Path $legacyDir 'scripts\render_modelica.py'
$modelicaDir = Join-Path $legacyDir 'modelica'
$buildDir = Join-Path $legacyDir 'build'
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $buildDir 'omhome') | Out-Null

Write-Host "Rendering the exact legacy TripLens_CombinedCycle_TripTAC wrapper..."
& $pythonExe @pythonArgs $render `
    --trip-time $TripTime `
    --trip-ramp-duration $TripRampDuration `
    --stop-time $StopTime `
    --intervals $Intervals `
    --template-dir $modelicaDir `
    --output-dir $buildDir
if ($LASTEXITCODE -ne 0) { throw "render_modelica.py failed: $LASTEXITCODE" }

$generatedModel = Join-Path $buildDir 'TripLens_CombinedCycle_TripTAC.mo'
$runMos = Join-Path $buildDir 'run.mos'
if (-not (Test-Path $generatedModel)) { throw 'Legacy generated Modelica wrapper missing.' }
if (-not (Test-Path $runMos)) { throw 'Legacy run.mos missing.' }

Write-Host "Checking Docker engine..."
& $docker version | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'Docker engine is not available.' }

Write-Host "Installing the exact legacy MSL dependency in OpenModelica 1.27 container..."
& $docker run --rm `
    -v "${buildDir}\omhome:/root" `
    -v "${legacyDir}:/workspace" `
    -w /workspace `
    $omImage `
    omc /workspace/modelica/install_dependencies.mos
if ($LASTEXITCODE -ne 0) { throw "Legacy dependency install failed: $LASTEXITCODE" }

Write-Host "Running exact legacy ThermoSysPro Action physics..."
& $docker run --rm `
    -v "${buildDir}\omhome:/root" `
    -v "${legacyDir}:/workspace" `
    -w /workspace `
    $omImage `
    omc /workspace/build/run.mos
if ($LASTEXITCODE -ne 0) { throw "Legacy OpenModelica run failed: $LASTEXITCODE" }

$resultCsv = Join-Path $buildDir 'thermosyspro_trip_tac_res.csv'
if (-not (Test-Path $resultCsv)) { throw 'Legacy Action did not create thermosyspro_trip_tac_res.csv.' }
$lineCount = (Get-Content $resultCsv | Measure-Object -Line).Lines
if ($lineCount -lt 2) { throw "Legacy result CSV has no data rows (lines=$lineCount)." }

Copy-Item $resultCsv (Join-Path $outputDir 'thermosyspro-raw.csv') -Force
Copy-Item $generatedModel (Join-Path $outputDir 'TripLens_CombinedCycle_TripTAC.mo') -Force
Copy-Item $runMos (Join-Path $outputDir 'run.mos') -Force

$manifest = [ordered]@{
    status = 'PASS'
    legacy_action_repo = $legacyRepo
    legacy_action_commit = $actualLegacy
    thermosyspro_repo = $thermoRepo
    thermosyspro_commit = $actualThermo
    openmodelica_image = $omImage
    trip_time_s = $TripTime
    trip_ramp_duration_s = $TripRampDuration
    stop_time_s = $StopTime
    intervals = $Intervals
    csv_lines = $lineCount
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $outputDir 'legacy-exact-manifest.json')

Write-Host "LEGACY EXACT PASS: CSV lines=$lineCount"
