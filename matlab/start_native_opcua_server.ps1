$ErrorActionPreference = 'Stop'

$serverDir = $env:TRIPLENS_OPCUA_SERVER_DIR
if ([string]::IsNullOrWhiteSpace($serverDir) -or -not (Test-Path $serverDir)) {
    throw "TRIPLENS_OPCUA_SERVER_DIR is missing or invalid: $serverDir"
}

$pidFile = Join-Path $serverDir 'active-opcua-server.pid'
$candidatePids = @()
if (-not [string]::IsNullOrWhiteSpace($env:TRIPLENS_OPCUA_SERVER_PID)) {
    $candidatePids += [int]$env:TRIPLENS_OPCUA_SERVER_PID
}
if (Test-Path $pidFile) {
    $storedPid = (Get-Content $pidFile -Raw).Trim()
    if ($storedPid -match '^\d+$') { $candidatePids += [int]$storedPid }
}
foreach ($candidatePid in ($candidatePids | Select-Object -Unique)) {
    Stop-Process -Id $candidatePid -Force -ErrorAction SilentlyContinue
}

$exe = Get-ChildItem $serverDir -Recurse -Filter TripLens_Native_OPCUA.exe |
    Select-Object -First 1
if ($null -eq $exe) { throw 'Native OPC UA server executable is missing' }

$dllDirs = Get-ChildItem $serverDir -Directory -Recurse | Where-Object {
    (Get-ChildItem $_.FullName -Filter *.dll -File -ErrorAction SilentlyContinue).Count -gt 0
}
foreach ($dir in $dllDirs) { $env:PATH = "$($dir.FullName);$env:PATH" }

$stdout = Join-Path $serverDir 'openmodelica-native.stdout.log'
$stderr = Join-Path $serverDir 'openmodelica-native.stderr.log'
$result = Join-Path $serverDir 'TripLens_Native_OPCUA_matlab_res.csv'
$port = if ([string]::IsNullOrWhiteSpace($env:TRIPLENS_OPCUA_PORT)) {
    4841
} else {
    [int]$env:TRIPLENS_OPCUA_PORT
}
$process = Start-Process -FilePath $exe.FullName -WorkingDirectory $serverDir `
    -ArgumentList @('-embeddedServer=opc-ua',"-embeddedServerPort=$port", "-r=$result") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Set-Content -Path $pidFile -Value $process.Id -Encoding ascii

$deadline = [DateTime]::UtcNow.AddSeconds(90)
$listening = $false
while ([DateTime]::UtcNow -lt $deadline -and -not $listening) {
    if ($process.HasExited) {
        Get-Content $stdout,$stderr -ErrorAction SilentlyContinue
        throw "Native OPC UA server exited before listening: $($process.ExitCode)"
    }
    if (Test-Path $stdout) {
        $listening = [bool](Select-String -Path $stdout `
            -SimpleMatch 'TCP network layer listening' -Quiet)
    }
    if (-not $listening) { Start-Sleep -Milliseconds 250 }
}
if (-not $listening) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'Native OPC UA server did not reach listening state'
}

"WINDOWS_NATIVE_OPCUA_SERVER_READY pid=$($process.Id)"
