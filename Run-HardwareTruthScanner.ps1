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

if (-not (Test-HttpOk $healthUrl)) {
  $stdout = Join-Path $root "server.log"
  $stderr = Join-Path $root "server.err.log"
  Start-Process -FilePath "node" -ArgumentList "server/index.js" -WorkingDirectory $root -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden

  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-HttpOk $healthUrl) {
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
