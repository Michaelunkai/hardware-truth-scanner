# Hardware Truth Scanner

Local full-stack Windows hardware triage app.

## What it does

- Runs a read-only PowerShell scan from the backend.
- Checks Device Manager problem codes, storage health, SMART failure prediction, storage reliability counters, disk-to-partition-to-volume mapping, storage controller/adapter PnP inventory, live disk queue/throughput/free-space counters, filesystem dirty-bit status, recent WHEA/disk/NTFS/display/power/PnP events, power-source and unexpected-shutdown stability evidence, Reliability Monitor and Windows Error Reporting hardware-crash records, Windows crash dump artifacts with bounded keyword hint extraction, CPU topology/cache/virtualization and live performance-counter evidence, GPU telemetry through `nvidia-smi` when present, GPU display-mode/VRAM/driver/link telemetry, safe DirectX-adjacent inventory with opt-in `dxdiag`, thermal/fan telemetry when Windows or OpenHardwareMonitor/LibreHardwareMonitor exposes it, Windows Memory Diagnostic history, DIMM slot topology and memory error-correction metadata, PCI/PCIe inventory, PCIe root/switch port and lane-sensitive device topology, firmware-class devices, driver-signing inventory, USB/input/monitor devices, USB/USBSTOR attached-device inventory, USB controller-to-device topology, EDID display identity and connection metadata, HID/Bluetooth/camera/sensor/printer peripheral inventory, network link speed and packet error/discard counters, audio endpoint/media device inventory, power capabilities, RAM inventory, battery status, network adapters, audio devices, and volumes.
- Renders every detected hardware class in the React frontend with status, evidence, confidence, and repair recommendations.
- Renders a proof-coverage matrix showing what was actually tested live and what still requires reboot, vendor diagnostics, load testing, or physical inspection.

## Accuracy boundary

This app can find software-visible evidence of physical problems. It cannot prove issues that require physical inspection, sensor hardware, reboot-based RAM tests, PSU load testing, cable inspection, or vendor diagnostics. Running the launcher as administrator gives better access to protected Windows dump, storage, event, and sensor locations.

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
