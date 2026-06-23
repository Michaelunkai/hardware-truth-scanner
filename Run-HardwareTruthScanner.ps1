param(
  [int]$Port = 4999,
  [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

function Test-HttpOk {
  param([string]$Url)
  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
    return $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
  } catch {
    return $false
  }
}

function Get-ScannerHealth {
  param([string]$Url)
  try {
    return Invoke-RestMethod -Uri $Url -TimeoutSec 3
  } catch {
    return $null
  }
}

function Stop-MismatchedScannerServers {
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
    Where-Object { $_.CommandLine -match 'server/index\.js' } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force
    }
}

function Quote-PowerShellSingle {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Start-ScannerServer {
  param(
    [string]$Root
  )

  $nodePath = (Get-Command node -ErrorAction Stop).Source
  $serverScript = Join-Path $Root "server\index.js"
  $stdout = Join-Path $Root "server.log"
  $stderr = Join-Path $Root "server.err.log"
  $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

  $innerCommand = @(
    "Set-Location -LiteralPath $(Quote-PowerShellSingle $Root)",
    "& $(Quote-PowerShellSingle $nodePath) $(Quote-PowerShellSingle $serverScript) 1>> $(Quote-PowerShellSingle $stdout) 2>> $(Quote-PowerShellSingle $stderr)"
  ) -join "; "

  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($innerCommand))
  $commandLine = '"' + $powershellPath + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand ' + $encoded
  $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine = $commandLine
    CurrentDirectory = $Root
  }

  if ($result.ReturnValue -ne 0) {
    throw "Failed to start Hardware Truth Scanner server. Win32_Process.Create returned $($result.ReturnValue)."
  }
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  throw "Node.js is required. Install Node.js, then run this launcher again."
}

if (-not (Test-Path (Join-Path $root "node_modules"))) {
  npm install
}

if (-not (Test-Path (Join-Path $root "dist\index.html"))) {
  npm run build
}

$healthUrl = "http://127.0.0.1:$Port/api/health"
$appUrl = "http://127.0.0.1:$Port"
$health = Get-ScannerHealth $healthUrl
$isThisScanner = $health -and $health.scanner -eq "hardware-truth-scanner" -and $health.root -eq $root

if ($health -and -not $isThisScanner) {
  Stop-MismatchedScannerServers
  Start-Sleep -Seconds 1
}

if (-not $isThisScanner) {
  $stderr = Join-Path $root "server.err.log"
  Start-ScannerServer -Root $root

  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    $health = Get-ScannerHealth $healthUrl
    if ($health -and $health.scanner -eq "hardware-truth-scanner" -and $health.root -eq $root) {
      $ready = $true
      break
    }
  }

  if (-not $ready) {
    throw "Hardware Truth Scanner did not become ready. Check $stderr"
  }
}

if (-not $NoOpen) {
  Start-Process $appUrl
}

Write-Host "Hardware Truth Scanner is running at $appUrl"
