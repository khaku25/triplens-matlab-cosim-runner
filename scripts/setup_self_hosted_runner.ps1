param(
    [Parameter(Mandatory=$true)]
    [string]$RegistrationToken,

    [string]$RunnerName = "$env:COMPUTERNAME-triplens-cosim",
    [string]$RunnerDir = "C:\actions-runner-triplens-cosim"
)

$ErrorActionPreference = 'Stop'
$repoUrl = 'https://github.com/khaku25/triplens-matlab-cosim-runner'

Write-Host "TripLens MATLAB Co-Sim self-hosted runner setup"
Write-Host "Repository: $repoUrl"
Write-Host "Runner name: $RunnerName"
Write-Host "Runner directory: $RunnerDir"

if (-not (Test-Path $RunnerDir)) {
    New-Item -ItemType Directory -Path $RunnerDir | Out-Null
}
Set-Location $RunnerDir

$latest = Invoke-RestMethod -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Headers @{ 'User-Agent'='TripLens-Runner-Setup' }
$asset = $latest.assets | Where-Object { $_.name -match '^actions-runner-win-x64-.*\.zip$' } | Select-Object -First 1
if (-not $asset) { throw 'Could not locate the latest Windows x64 GitHub Actions runner package.' }

$zip = Join-Path $RunnerDir $asset.name
if (-not (Test-Path (Join-Path $RunnerDir 'config.cmd'))) {
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $RunnerDir -Force
}

if (Test-Path (Join-Path $RunnerDir '.runner')) {
    Write-Host 'Runner is already configured in this directory. Skipping config.cmd.'
} else {
    & .\config.cmd --unattended --url $repoUrl --token $RegistrationToken --name $RunnerName --labels triplens-cosim,matlab --work _work --replace
    if ($LASTEXITCODE -ne 0) { throw "config.cmd failed with exit code $LASTEXITCODE" }
}

Write-Host ''
Write-Host 'Runner configured.'
Write-Host 'Starting runner interactively now. Leave this PowerShell window open while testing.'
Write-Host 'After validation, you can optionally install it as a Windows service using svc.cmd from an elevated shell.'
& .\run.cmd
