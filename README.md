# Hardware Truth Scanner

Local full-stack Windows hardware triage app.

## What it does

- Runs a read-only PowerShell scan from the backend.
- Checks Device Manager problem codes, storage health, SMART failure prediction, storage reliability counters, recent WHEA/disk/NTFS/display/power events, GPU telemetry through `nvidia-smi` when present, RAM inventory, battery status, network adapters, audio devices, and volumes.
- Renders every detected hardware class in the React frontend with status, evidence, confidence, and repair recommendations.

## Accuracy boundary

This app can find software-visible evidence of physical problems. It cannot prove issues that require physical inspection, sensor hardware, reboot-based RAM tests, PSU load testing, cable inspection, or vendor diagnostics.

## Run

```powershell
npm install
npm run build
npm start
```

Open `http://127.0.0.1:4999`.

Or use the Windows launcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-HardwareTruthScanner.ps1
```

For a terminal-only report:

```powershell
npm run scan
```

The JSON report is written to `hardware-report-latest.json`.
