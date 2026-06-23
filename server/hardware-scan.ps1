param(
  [int]$RecentDays = 14
)

$ErrorActionPreference = "SilentlyContinue"

function Invoke-Probe {
  param(
    [string]$Name,
    [scriptblock]$Script
  )

  try {
    & $Script
  } catch {
    $script:probeErrors += [pscustomobject]@{
      Name = $Name
      Error = $_.Exception.Message
    }
    @()
  }
}

function Invoke-OptionalProbe {
  param(
    [string]$Name,
    [scriptblock]$Script
  )

  try {
    & $Script
  } catch {
    $script:optionalProbeErrors += [pscustomobject]@{
      Name = $Name
      Error = $_.Exception.Message
    }
    @()
  }
}

function New-Component {
  param(
    [string]$Category,
    [string]$Name,
    [string]$Status,
    [string]$Confidence,
    [hashtable]$Evidence,
    [string[]]$Signals,
    [string[]]$Recommendations
  )

  $script:components += [pscustomobject]@{
    id = (($Category + "-" + $Name).ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
    category = $Category
    name = $Name
    status = $Status
    confidence = $Confidence
    evidence = $Evidence
    signals = @($Signals)
    recommendations = @($Recommendations)
  }
}

function New-Finding {
  param(
    [string]$Severity,
    [string]$Component,
    [string]$Title,
    [string]$Detail,
    [string]$Evidence,
    [string]$Recommendation,
    [string]$Confidence = "medium"
  )

  $script:findings += [pscustomobject]@{
    severity = $Severity
    component = $Component
    title = $Title
    detail = $Detail
    evidence = $Evidence
    recommendation = $Recommendation
    confidence = $Confidence
  }
}

function As-Text {
  param($Value)
  if ($null -eq $Value) { return "" }
  if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ", ") }
  return [string]$Value
}

$probeErrors = @()
$optionalProbeErrors = @()
$components = @()
$findings = @()
$startTime = (Get-Date).AddDays(-1 * $RecentDays)
$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { (Invoke-Probe "hostname" { hostname.exe }) -join "" }

$computer = Invoke-Probe "computer" { Get-CimInstance Win32_ComputerSystem }
$os = Invoke-Probe "os" { Get-CimInstance Win32_OperatingSystem }
$bios = Invoke-Probe "bios" { Get-CimInstance Win32_BIOS }
$baseBoard = Invoke-Probe "baseboard" { Get-CimInstance Win32_BaseBoard }
$processors = @(Invoke-Probe "cpu" { Get-CimInstance Win32_Processor })
$memoryModules = @(Invoke-Probe "memory" { Get-CimInstance Win32_PhysicalMemory })
$diskDrives = @(Invoke-Probe "diskdrives" { Get-CimInstance Win32_DiskDrive })
$physicalDisks = @(Invoke-OptionalProbe "physicaldisks" { Get-PhysicalDisk })
$storageCounters = @(Invoke-OptionalProbe "storage counters" { Get-PhysicalDisk | Get-StorageReliabilityCounter })
$smartStatus = @(Invoke-OptionalProbe "smart predict" { Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus })
$volumes = @(Invoke-Probe "volumes" { Get-Volume })
$videoControllers = @(Invoke-Probe "video" { Get-CimInstance Win32_VideoController })
$soundDevices = @(Invoke-Probe "audio" { Get-CimInstance Win32_SoundDevice })
$networkAdapters = @(Invoke-Probe "network" { Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } })
$batteries = @(Invoke-Probe "battery" { Get-CimInstance Win32_Battery })
$pnpProblems = @(Invoke-Probe "pnp problems" { Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } })

$eventProviders = @(
  "Microsoft-Windows-WHEA-Logger",
  "disk",
  "Disk",
  "Ntfs",
  "stornvme",
  "storahci",
  "Display",
  "nvlddmkm",
  "Microsoft-Windows-Kernel-Power",
  "volmgr",
  "Microsoft-Windows-MemoryDiagnostics-Results"
)

$events = @()
foreach ($provider in $eventProviders) {
  $events += @(Invoke-Probe "event $provider" {
    Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = $provider; StartTime = $startTime } -MaxEvents 30 |
      Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
  })
}

$nvidiaRows = @()
$nvidiaDetails = @()
$nvidiaCommand = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($nvidiaCommand) {
  $query = "name,driver_version,vbios_version,temperature.gpu,fan.speed,pstate,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,pcie.link.gen.current,pcie.link.width.current,utilization.gpu"
  $csv = @(Invoke-Probe "nvidia query" { & $nvidiaCommand.Source "--query-gpu=$query" "--format=csv,noheader,nounits" })
  foreach ($line in $csv) {
    $parts = $line -split "\s*,\s*"
    if ($parts.Count -ge 13) {
      $nvidiaRows += [pscustomobject]@{
        Name = $parts[0]
        DriverVersion = $parts[1]
        VbiosVersion = $parts[2]
        TemperatureC = $parts[3]
        FanPercent = $parts[4]
        PState = $parts[5]
        PowerDrawW = $parts[6]
        PowerLimitW = $parts[7]
        GraphicsClockMhz = $parts[8]
        MemoryClockMhz = $parts[9]
        PcieGen = $parts[10]
        PcieWidth = $parts[11]
        UtilizationPercent = $parts[12]
      }
    }
  }
  $nvidiaDetails = @(Invoke-Probe "nvidia health detail" { & $nvidiaCommand.Source "-q" "-d" "TEMPERATURE,PERFORMANCE,POWER" })
}

New-Component -Category "System" -Name ($computer.Model) -Status "ok" -Confidence "medium" -Evidence @{
  Manufacturer = $computer.Manufacturer
  Model = $computer.Model
  TotalMemoryGB = [math]::Round(($computer.TotalPhysicalMemory / 1GB), 2)
  OS = $os.Caption
  LastBoot = $os.LastBootUpTime
} -Signals @() -Recommendations @("No chassis-level fault was visible to Windows telemetry.")

New-Component -Category "Motherboard and BIOS" -Name ($baseBoard.Product) -Status "ok" -Confidence "medium" -Evidence @{
  Manufacturer = $baseBoard.Manufacturer
  Product = $baseBoard.Product
  SerialNumber = $baseBoard.SerialNumber
  BiosVersion = (As-Text $bios.SMBIOSBIOSVersion)
  BiosDate = $bios.ReleaseDate
} -Signals @() -Recommendations @("No motherboard-specific Windows hardware fault signal was found. Inspect physically only if symptoms persist.")

foreach ($cpu in $processors) {
  $cpuEvents = @($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-WHEA-Logger" -and $_.Message -match "processor|cache|bus|interconnect|APIC" })
  $status = if ($cpu.Status -and $cpu.Status -ne "OK") { "warning" } elseif ($cpuEvents.Count -gt 0) { "warning" } else { "ok" }
  $signals = @()
  if ($cpu.Status -and $cpu.Status -ne "OK") { $signals += "Win32_Processor status is $($cpu.Status)." }
  if ($cpuEvents.Count -gt 0) { $signals += "$($cpuEvents.Count) recent WHEA CPU-related event(s)." }
  New-Component -Category "CPU" -Name ($cpu.Name) -Status $status -Confidence "medium" -Evidence @{
    Cores = $cpu.NumberOfCores
    LogicalProcessors = $cpu.NumberOfLogicalProcessors
    MaxClockMHz = $cpu.MaxClockSpeed
    Status = $cpu.Status
    RecentWheaCpuEvents = $cpuEvents.Count
  } -Signals $signals -Recommendations $(if ($status -eq "ok") { @("No CPU fault signal was found. A real thermal/load test is still required to rule out intermittent physical CPU cooling or power issues.") } else { @("Check cooling, CPU power stability, BIOS settings, and run a vendor CPU stress diagnostic.") })
}

foreach ($module in $memoryModules) {
  $name = "DIMM $($module.BankLabel) $([math]::Round(($module.Capacity / 1GB), 2)) GB"
  New-Component -Category "Memory" -Name $name -Status "unknown" -Confidence "low" -Evidence @{
    Manufacturer = $module.Manufacturer
    PartNumber = ($module.PartNumber -as [string]).Trim()
    SpeedMHz = $module.Speed
    ConfiguredClockMHz = $module.ConfiguredClockSpeed
    SerialNumber = $module.SerialNumber
    CapacityGB = [math]::Round(($module.Capacity / 1GB), 2)
  } -Signals @("Windows inventory cannot prove RAM cells are healthy without a memory test.") -Recommendations @("Run Windows Memory Diagnostic or MemTest86 from boot to rule out physical RAM faults.")
}

$memoryEvents = @($events | Where-Object { $_.ProviderName -match "MemoryDiagnostics|WHEA" -and $_.Message -match "memory|RAM|cache hierarchy" })
if ($memoryEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Memory" -Title "Recent memory-related event evidence exists" -Detail "Windows logged memory or cache related reliability events in the scan window." -Evidence "$($memoryEvents.Count) event(s) since $startTime" -Recommendation "Run an offline memory diagnostic and reseat/test DIMMs if errors are reproduced." -Confidence "medium"
}

foreach ($pd in $physicalDisks) {
  $operational = As-Text $pd.OperationalStatus
  $status = if ($pd.HealthStatus -ne "Healthy" -or $operational -match "Lost|Degraded|Stressed|Predictive Failure") { "critical" } else { "ok" }
  $signals = @()
  if ($pd.HealthStatus -ne "Healthy") { $signals += "PhysicalDisk HealthStatus is $($pd.HealthStatus)." }
  if ($operational -match "Lost|Degraded|Stressed|Predictive Failure") { $signals += "OperationalStatus is $operational." }
  New-Component -Category "Storage" -Name ($pd.FriendlyName) -Status $status -Confidence "high" -Evidence @{
    MediaType = $pd.MediaType
    HealthStatus = $pd.HealthStatus
    OperationalStatus = $operational
    SizeGB = [math]::Round(($pd.Size / 1GB), 2)
    Usage = $pd.Usage
    BusType = $pd.BusType
  } -Signals $signals -Recommendations $(if ($status -eq "ok") { @("No Windows storage health fault was reported for this physical disk.") } else { @("Back up immediately, check cables/slot/power, and replace the drive if vendor diagnostics confirm the fault.") })

  if ($status -eq "critical") {
    New-Finding -Severity "critical" -Component $pd.FriendlyName -Title "Physical disk health is not healthy" -Detail "Windows Storage reports a non-healthy physical disk." -Evidence "HealthStatus=$($pd.HealthStatus); OperationalStatus=$operational" -Recommendation "Back up this disk now and replace or reseat it after vendor diagnostics." -Confidence "high"
  }
}

foreach ($disk in $diskDrives) {
  $status = if ($disk.Status -and $disk.Status -ne "OK") { "warning" } else { "ok" }
  $signals = @()
  if ($disk.Status -and $disk.Status -ne "OK") { $signals += "Win32_DiskDrive status is $($disk.Status)." }
  New-Component -Category "Disk Device" -Name ($disk.Model) -Status $status -Confidence "medium" -Evidence @{
    InterfaceType = $disk.InterfaceType
    MediaType = $disk.MediaType
    Status = $disk.Status
    SizeGB = [math]::Round(($disk.Size / 1GB), 2)
    SerialNumber = (($disk.SerialNumber -as [string]).Trim())
  } -Signals $signals -Recommendations $(if ($status -eq "ok") { @("No generic disk device fault was reported.") } else { @("Run vendor diagnostics and inspect cabling or the drive slot.") })
}

foreach ($counter in $storageCounters) {
  $counterName = if ($counter.DeviceId) { "Storage reliability counter $($counter.DeviceId)" } else { "Storage reliability counter" }
  $readErrors = [int64]($counter.ReadErrorsTotal)
  $writeErrors = [int64]($counter.WriteErrorsTotal)
  $status = if ($readErrors -gt 0 -or $writeErrors -gt 0) { "warning" } else { "ok" }
  if ($status -eq "warning") {
    New-Finding -Severity "warning" -Component $counterName -Title "Storage reliability counters contain errors" -Detail "The Windows reliability counter reported non-zero read or write errors." -Evidence "ReadErrorsTotal=$readErrors; WriteErrorsTotal=$writeErrors" -Recommendation "Back up, run vendor SMART diagnostics, and inspect data/power paths if errors increase." -Confidence "high"
  }
}

foreach ($smart in $smartStatus) {
  if ($smart.PredictFailure -eq $true) {
    New-Finding -Severity "critical" -Component "SMART disk" -Title "SMART predicts drive failure" -Detail "The disk firmware reports predicted failure through Windows SMART." -Evidence "Instance=$($smart.InstanceName)" -Recommendation "Back up immediately and replace this drive." -Confidence "high"
  }
}

if ($optionalProbeErrors.Count -gt 0) {
  New-Component -Category "Storage Advanced Health" -Name "SMART and Storage module telemetry" -Status "unknown" -Confidence "medium" -Evidence @{
    Errors = $optionalProbeErrors
    FallbackUsed = "Win32_DiskDrive status and recent disk/NTFS/storage event scan"
  } -Signals @("Advanced storage health providers were unavailable on this Windows installation.") -Recommendations @("Install or run vendor storage diagnostics such as Samsung Magician, the SSD vendor tool, or smartctl to prove SMART attribute health beyond Windows generic disk status.")
}

$diskEvents = @($events | Where-Object { $_.ProviderName -match "disk|Disk|Ntfs|stor|volmgr" })
if ($diskEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Storage subsystem" -Title "Recent disk or filesystem reliability events" -Detail "Windows logged storage-related errors or warnings in the recent scan window." -Evidence "$($diskEvents.Count) event(s) since $startTime" -Recommendation "Review the listed disk, cable, controller, and filesystem evidence; run vendor diagnostics for affected drives." -Confidence "medium"
}

foreach ($volume in $volumes) {
  $sizeRemaining = if ($volume.SizeRemaining) { [math]::Round(($volume.SizeRemaining / 1GB), 2) } else { $null }
  $size = if ($volume.Size) { [math]::Round(($volume.Size / 1GB), 2) } else { $null }
  $status = if ($volume.HealthStatus -and $volume.HealthStatus -ne "Healthy") { "warning" } else { "ok" }
  $signals = @()
  if ($volume.HealthStatus -and $volume.HealthStatus -ne "Healthy") { $signals += "Volume HealthStatus is $($volume.HealthStatus)." }
  New-Component -Category "Volume" -Name (($volume.DriveLetter, $volume.FileSystemLabel | Where-Object { $_ }) -join ": ") -Status $status -Confidence "medium" -Evidence @{
    DriveLetter = $volume.DriveLetter
    FileSystem = $volume.FileSystem
    HealthStatus = $volume.HealthStatus
    SizeGB = $size
    FreeGB = $sizeRemaining
  } -Signals $signals -Recommendations $(if ($status -eq "ok") { @("No volume health fault was reported.") } else { @("Back up data and run filesystem repair only after confirming the target volume.") })
}

foreach ($gpu in $videoControllers) {
  $gpuEvents = @($events | Where-Object { $_.ProviderName -match "Display|nvlddmkm" })
  $nvidia = @($nvidiaRows | Where-Object { $gpu.Name -like "*$($_.Name)*" -or $_.Name -like "*$($gpu.Name)*" } | Select-Object -First 1)
  $temp = if ($nvidia.Count -gt 0) { [int]($nvidia[0].TemperatureC -replace "[^0-9]", "") } else { $null }
  $status = if ($gpu.Status -and $gpu.Status -ne "OK") { "warning" } elseif ($temp -and $temp -ge 85) { "warning" } elseif ($gpuEvents.Count -gt 0) { "warning" } else { "ok" }
  $signals = @()
  if ($gpu.Status -and $gpu.Status -ne "OK") { $signals += "VideoController status is $($gpu.Status)." }
  if ($temp -and $temp -ge 85) { $signals += "GPU temperature is $temp C at scan time." }
  if ($gpuEvents.Count -gt 0) { $signals += "$($gpuEvents.Count) recent display/GPU event(s)." }
  New-Component -Category "GPU" -Name ($gpu.Name) -Status $status -Confidence "medium" -Evidence @{
    AdapterRAMGB = if ($gpu.AdapterRAM) { [math]::Round(($gpu.AdapterRAM / 1GB), 2) } else { $null }
    DriverVersion = $gpu.DriverVersion
    Status = $gpu.Status
    NvidiaTelemetry = if ($nvidia.Count -gt 0) { $nvidia[0] } else { $null }
    RecentGpuEvents = $gpuEvents.Count
  } -Signals $signals -Recommendations $(if ($status -eq "ok") { @("No GPU fault signal was found at scan time. Use a load test if crashes occur only under gaming/rendering load.") } else { @("Check GPU temperature, power cabling, PCIe seating, and driver stability; run a vendor GPU diagnostic.") })
}

$powerEvents = @($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Power" -or $_.ProviderName -eq "volmgr" })
if ($powerEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Power stability" -Title "Recent power-loss or crash-path events" -Detail "Kernel-Power or volmgr events can indicate forced shutdowns, PSU instability, crashes, or power loss." -Evidence "$($powerEvents.Count) event(s) since $startTime" -Recommendation "If unexpected shutdowns are happening, inspect PSU, wall power, GPU power cables, and crash dumps." -Confidence "medium"
}

foreach ($battery in $batteries) {
  $status = if ($battery.BatteryStatus -in @(1, 4, 5, 10, 11)) { "warning" } else { "ok" }
  New-Component -Category "Battery" -Name ($battery.Name) -Status $status -Confidence "medium" -Evidence @{
    EstimatedChargeRemaining = $battery.EstimatedChargeRemaining
    BatteryStatus = $battery.BatteryStatus
    Chemistry = $battery.Chemistry
    DesignVoltage = $battery.DesignVoltage
  } -Signals $(if ($status -eq "warning") { @("BatteryStatus indicates non-normal state: $($battery.BatteryStatus).") } else { @() }) -Recommendations $(if ($status -eq "ok") { @("No battery warning was reported by Windows.") } else { @("Generate a full battery report and inspect physical swelling/charger behavior.") })
}

if ($batteries.Count -eq 0) {
  New-Component -Category "Battery" -Name "No battery detected" -Status "info" -Confidence "high" -Evidence @{ Present = $false } -Signals @() -Recommendations @("No battery hardware is exposed to Windows on this machine.")
}

foreach ($adapter in $networkAdapters) {
  $status = if ($adapter.ConfigManagerErrorCode -and $adapter.ConfigManagerErrorCode -ne 0) { "warning" } elseif ($adapter.NetEnabled -eq $false -and $adapter.PhysicalAdapter) { "info" } else { "ok" }
  New-Component -Category "Network" -Name ($adapter.Name) -Status $status -Confidence "medium" -Evidence @{
    AdapterType = $adapter.AdapterType
    NetConnectionStatus = $adapter.NetConnectionStatus
    NetEnabled = $adapter.NetEnabled
    MacAddress = $adapter.MACAddress
    Speed = $adapter.Speed
    ConfigManagerErrorCode = $adapter.ConfigManagerErrorCode
  } -Signals $(if ($adapter.ConfigManagerErrorCode -and $adapter.ConfigManagerErrorCode -ne 0) { @("Device Manager code $($adapter.ConfigManagerErrorCode).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check adapter seating/cable/antenna and reinstall or update the device driver.") } else { @("No adapter hardware fault was reported.") })
}

foreach ($sound in $soundDevices) {
  $status = if ($sound.Status -and $sound.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Audio" -Name ($sound.Name) -Status $status -Confidence "medium" -Evidence @{
    Manufacturer = $sound.Manufacturer
    Status = $sound.Status
    ProductName = $sound.ProductName
  } -Signals $(if ($status -eq "warning") { @("Audio device status is $($sound.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check the device path, cabling, and driver package.") } else { @("No audio hardware fault was reported.") })
}

if ($pnpProblems.Count -gt 0) {
  foreach ($problem in $pnpProblems) {
    New-Finding -Severity "warning" -Component ($problem.Name) -Title "Device Manager reports a problem device" -Detail "A detected hardware device has a non-zero ConfigManagerErrorCode." -Evidence "Code=$($problem.ConfigManagerErrorCode); Class=$($problem.PNPClass); DeviceID=$($problem.DeviceID)" -Recommendation "Inspect this specific device in Device Manager; reseat/replace hardware only if the code persists after driver and cable checks." -Confidence "high"
  }
  New-Component -Category "Device Manager" -Name "Problem devices" -Status "warning" -Confidence "high" -Evidence @{
    Count = $pnpProblems.Count
    Devices = @($pnpProblems | Select-Object Name, PNPClass, ConfigManagerErrorCode, Status)
  } -Signals @("$($pnpProblems.Count) problem device(s) found.") -Recommendations @("Fix each Device Manager problem code before treating the hardware inventory as clean.")
} else {
  New-Component -Category "Device Manager" -Name "Problem devices" -Status "ok" -Confidence "high" -Evidence @{ Count = 0 } -Signals @() -Recommendations @("No Device Manager problem devices were found.")
}

if ($probeErrors.Count -gt 0) {
  New-Component -Category "Scanner Coverage" -Name "Probe errors" -Status "unknown" -Confidence "medium" -Evidence @{ Errors = $probeErrors } -Signals @("$($probeErrors.Count) probe(s) returned errors or no access.") -Recommendations @("Review probe errors before treating missing telemetry as healthy.")
}

$report = [pscustomobject]@{
  scanner = "hardware-truth-scanner"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  host = $hostName
  os = "$($os.Caption) $($os.Version)"
  scanWindowDays = $RecentDays
  summary = [pscustomobject]@{
    overallStatus = "unknown"
    componentCount = 0
    findingCount = 0
    criticalCount = 0
    warningCount = 0
    unknownCount = 0
  }
  components = @($components)
  findings = @($findings)
  coverageLimits = @(
    "Software telemetry cannot guarantee detection of loose internal cables, dust buildup, bad ports that were not exercised, swollen capacitors, bent pins, cracked solder joints, fan bearing noise, weak PSU ripple, or intermittent faults that did not occur during the scan window.",
    "RAM health cannot be proven from inventory alone. A boot-level memory diagnostic or MemTest86 pass is required for physical RAM certainty.",
    "CPU, GPU, PSU, and cooling problems that appear only under sustained load need a controlled stress test with temperature and power monitoring.",
    "SMART and Windows storage health are strong signals, but vendor diagnostics are still required before trusting or discarding a drive.",
    "This scan is read-only and avoids rebooting, destructive filesystem repair, firmware flashing, and hardware stress testing."
  )
  raw = [pscustomobject]@{
    RecentEvents = @($events | Select-Object -First 200)
    NvidiaDetail = $nvidiaDetails
    ProbeErrors = $probeErrors
    OptionalProbeErrors = $optionalProbeErrors
  }
}

$report | ConvertTo-Json -Depth 12
