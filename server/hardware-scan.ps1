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

function Convert-ToSafeEvidenceValue {
  param($Value)

  if ($null -eq $Value) { return $null }
  $baseObject = $Value.PSObject.BaseObject
  if ($null -ne $baseObject -and -not [object]::ReferenceEquals($baseObject, $Value)) {
    if ($baseObject -is [string]) { return [string]$baseObject }
    if ($baseObject -is [bool]) { return [bool]$baseObject }
    if ($baseObject -is [int] -or $baseObject -is [long]) { return [long]$baseObject }
    if ($baseObject -is [double] -or $baseObject -is [decimal]) { return [double]$baseObject }
    if ($baseObject -is [datetime]) { return $baseObject.ToString("o") }
  }
  if ($Value -is [string]) { return [string]$Value }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
  if ($Value -is [double] -or $Value -is [decimal]) { return [double]$Value }
  if ($Value -is [datetime]) { return $Value.ToString("o") }
  if ($Value -is [array]) {
    $items = @($Value | Select-Object -First 20 | ForEach-Object { Convert-ToSafeEvidenceValue $_ })
    if ($Value.Count -gt 20) { $items += "... truncated $($Value.Count - 20) more item(s)" }
    return ,$items
  }
  if ($Value -is [hashtable]) {
    $safeHash = [ordered]@{}
    foreach ($key in @($Value.Keys | Select-Object -First 30)) {
      $safeHash[[string]$key] = Convert-ToSafeEvidenceValue $Value[$key]
    }
    return [pscustomobject]$safeHash
  }

  $safeObject = [ordered]@{}
  $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match "Property" } | Select-Object -First 20)
  foreach ($property in $properties) {
    $propertyValue = $property.Value
    if ($null -eq $propertyValue) {
      $safeObject[$property.Name] = $null
    } elseif ($propertyValue -is [string] -or $propertyValue -is [bool] -or $propertyValue -is [int] -or $propertyValue -is [long] -or $propertyValue -is [double] -or $propertyValue -is [decimal]) {
      $safeObject[$property.Name] = $propertyValue
    } elseif ($propertyValue -is [datetime]) {
      $safeObject[$property.Name] = $propertyValue.ToString("o")
    } else {
      $safeObject[$property.Name] = [string]$propertyValue
    }
  }
  if ($safeObject.Count -gt 0) { return [pscustomobject]$safeObject }

  $text = [string]$Value
  if ($text.Length -gt 1000) { return ($text.Substring(0, 1000) + "... truncated") }
  return $text
}

function Convert-ToBoundedText {
  param(
    $Value,
    [int]$MaxLength = 1000
  )

  if ($null -eq $Value) { return "" }
  $text = ([string]$Value) -replace "\s+", " "
  if ($text.Length -gt $MaxLength) { return ($text.Substring(0, $MaxLength) + "... truncated") }
  return $text
}

function Convert-ToJsonSafe {
  param(
    $Value,
    [int]$Depth = 4,
    [int]$MaxItems = 50
  )

  if ($null -eq $Value) { return $null }
  $baseObject = $Value.PSObject.BaseObject
  if ($null -ne $baseObject -and -not [object]::ReferenceEquals($baseObject, $Value)) {
    if ($baseObject -is [string]) { return [string]$baseObject }
    if ($baseObject -is [bool]) { return [bool]$baseObject }
    if ($baseObject -is [int] -or $baseObject -is [long]) { return [long]$baseObject }
    if ($baseObject -is [double] -or $baseObject -is [decimal]) { return [double]$baseObject }
    if ($baseObject -is [datetime]) { return $baseObject.ToString("o") }
  }
  if ($Value -is [string]) { return [string]$Value }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [int] -or $Value -is [long]) { return [long]$Value }
  if ($Value -is [double] -or $Value -is [decimal]) { return [double]$Value }
  if ($Value -is [datetime]) { return $Value.ToString("o") }
  if ($Depth -le 0) { return Convert-ToBoundedText $Value 300 }

  if ($Value -is [hashtable]) {
    $safeHash = [ordered]@{}
    foreach ($key in @($Value.Keys | Select-Object -First $MaxItems)) {
      $safeHash[[string]$key] = Convert-ToJsonSafe -Value $Value[$key] -Depth ($Depth - 1) -MaxItems 20
    }
    if ($Value.Keys.Count -gt $MaxItems) { $safeHash["_truncated"] = "$($Value.Keys.Count - $MaxItems) more field(s)" }
    return [pscustomobject]$safeHash
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    $count = 0
    foreach ($item in $Value) {
      if ($count -ge $MaxItems) { break }
      $items += Convert-ToJsonSafe -Value $item -Depth ($Depth - 1) -MaxItems 20
      $count += 1
    }
    $totalCount = @($Value).Count
    if ($totalCount -gt $MaxItems) { $items += "... truncated $($totalCount - $MaxItems) more item(s)" }
    return ,$items
  }

  $safeObject = [ordered]@{}
  $properties = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match "Property" } | Select-Object -First $MaxItems)
  foreach ($property in $properties) {
    $propertyValue = $property.Value
    $converted = Convert-ToJsonSafe -Value $propertyValue -Depth ($Depth - 1) -MaxItems 20
    if ($null -eq $converted -and $null -ne $propertyValue -and $propertyValue -is [System.Collections.IEnumerable] -and -not ($propertyValue -is [string])) {
      $safeObject[$property.Name] = @()
    } else {
      $safeObject[$property.Name] = $converted
    }
  }
  if ($safeObject.Count -gt 0) { return [pscustomobject]$safeObject }

  return Convert-ToBoundedText $Value 500
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

  $safeEvidence = @{}
  foreach ($key in $Evidence.Keys) {
    $safeEvidence[$key] = Convert-ToSafeEvidenceValue $Evidence[$key]
  }
  $safeSignals = @()
  if ($null -ne $Signals) {
    $safeSignals = @($Signals | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  }
  $safeRecommendations = @()
  if ($null -ne $Recommendations) {
    $safeRecommendations = @($Recommendations | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  }

  $script:components += [pscustomobject]@{
    id = (($Category + "-" + $Name).ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-")
    category = $Category
    name = $Name
    status = $Status
    confidence = $Confidence
    evidence = $safeEvidence
    signals = $safeSignals
    recommendations = $safeRecommendations
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

function New-Diagnostic {
  param(
    [string]$Name,
    [string]$Status,
    [string]$Evidence,
    [string]$NextStep
  )

  $script:diagnostics += [pscustomobject]@{
    name = $Name
    status = $Status
    evidence = $Evidence
    nextStep = $NextStep
  }
}

function As-Text {
  param($Value)
  if ($null -eq $Value) { return "" }
  if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ", ") }
  return [string]$Value
}

function Invoke-TextCommand {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$Arguments
  )

  try {
    $output = & $FilePath @Arguments 2>&1
    return @($output | ForEach-Object { [string]$_ })
  } catch {
    $script:optionalProbeErrors += [pscustomobject]@{
      Name = $Name
      Error = $_.Exception.Message
    }
    return @()
  }
}

$probeErrors = @()
$optionalProbeErrors = @()
$components = @()
$findings = @()
$diagnostics = @()
$startTime = (Get-Date).AddDays(-1 * $RecentDays)
$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { (Invoke-Probe "hostname" { hostname.exe }) -join "" }

$computer = Invoke-Probe "computer" { Get-CimInstance Win32_ComputerSystem }
$os = Invoke-Probe "os" { Get-CimInstance Win32_OperatingSystem }
$bios = Invoke-Probe "bios" { Get-CimInstance Win32_BIOS }
$baseBoard = Invoke-Probe "baseboard" { Get-CimInstance Win32_BaseBoard }
$processors = @(Invoke-Probe "cpu" { Get-CimInstance Win32_Processor })
$memoryModules = @(Invoke-Probe "memory" { Get-CimInstance Win32_PhysicalMemory })
$diskDrives = @(Invoke-Probe "diskdrives" { Get-CimInstance Win32_DiskDrive })
$physicalDisks = @()
$storageCounters = @()
$optionalProbeErrors += [pscustomobject]@{ Name = "physicaldisks"; Error = "Skipped Get-PhysicalDisk because this host's Windows Storage provider returns invalid-property errors/hangs; using Win32_DiskDrive and event evidence instead." }
$optionalProbeErrors += [pscustomobject]@{ Name = "storage counters"; Error = "Skipped Get-StorageReliabilityCounter because it depends on the same unstable Windows Storage provider on this host." }
$smartStatus = @(Invoke-OptionalProbe "smart predict" { Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus })
$volumes = @(Invoke-Probe "logical volumes" { Get-CimInstance Win32_LogicalDisk })
$videoControllers = @(Invoke-Probe "video" { Get-CimInstance Win32_VideoController })
$soundDevices = @(Invoke-Probe "audio" { Get-CimInstance Win32_SoundDevice })
$networkAdapters = @(Invoke-Probe "network" { Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } })
$batteries = @(Invoke-Probe "battery" { Get-CimInstance Win32_Battery })
$pnpProblems = @(Invoke-Probe "pnp problems" { Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } })
$pnpAll = @(Invoke-Probe "pnp all" { Get-CimInstance Win32_PnPEntity })
$pciDevices = @($pnpAll | Where-Object { $_.PNPDeviceID -like "PCI\*" })
$firmwareDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "Firmware" -or $_.Name -match "firmware|BIOS|UEFI" })
$signedDrivers = @(Invoke-Probe "signed drivers" { Get-CimInstance Win32_PnPSignedDriver })
$monitors = @(Invoke-Probe "monitors" { Get-CimInstance Win32_DesktopMonitor })
$keyboards = @(Invoke-Probe "keyboards" { Get-CimInstance Win32_Keyboard })
$pointingDevices = @(Invoke-Probe "pointing devices" { Get-CimInstance Win32_PointingDevice })
$usbControllers = @(Invoke-Probe "usb controllers" { Get-CimInstance Win32_USBController })
$usbHubs = @(Invoke-Probe "usb hubs" { Get-CimInstance Win32_USBHub })
$fans = @(Invoke-Probe "fans" { Get-CimInstance Win32_Fan })
$thermalZones = @(Invoke-OptionalProbe "thermal zones" { Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature })
$openHardwareSensors = @(Invoke-OptionalProbe "openhardwaremonitor sensors" { Get-CimInstance -Namespace root\OpenHardwareMonitor -ClassName Sensor })
$libreHardwareSensors = @(Invoke-OptionalProbe "librehardwaremonitor sensors" { Get-CimInstance -Namespace root\LibreHardwareMonitor -ClassName Sensor })
$enclosures = @(Invoke-Probe "enclosure" { Get-CimInstance Win32_SystemEnclosure })
$tpm = @(Invoke-OptionalProbe "tpm" { Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm })

$powerCfgA = Invoke-TextCommand -Name "powercfg available sleep states" -FilePath "powercfg.exe" -Arguments @("/a")
$problemDevicesText = Invoke-TextCommand -Name "pnputil problem devices" -FilePath "pnputil.exe" -Arguments @("/enum-devices", "/problem")
$volumeDirtyResults = @()
foreach ($volume in $volumes) {
  if ($volume.DeviceID -match "^[A-Z]:$") {
    $dirtyOutput = Invoke-TextCommand -Name "fsutil dirty query $($volume.DeviceID)" -FilePath "fsutil.exe" -Arguments @("dirty", "query", $volume.DeviceID)
    $volumeDirtyResults += [pscustomobject]@{
      DeviceID = $volume.DeviceID
      Output = @($dirtyOutput)
      IsDirty = (($dirtyOutput -join " ") -match "dirty" -and ($dirtyOutput -join " ") -notmatch "not dirty")
      IsUnsupported = (($dirtyOutput -join " ") -match "requires|denied|not supported|failed|error")
    }
  }
}

$dxdiagText = @()
$dxdiagPath = Join-Path $env:TEMP ("hardware-truth-dxdiag-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
  $dx = Start-Process -FilePath "dxdiag.exe" -ArgumentList @("/dontskip", "/whql:off", "/t", $dxdiagPath) -WindowStyle Hidden -PassThru
  if ($dx.WaitForExit(35000) -and (Test-Path $dxdiagPath)) {
    $dxdiagText = @(Get-Content -Path $dxdiagPath -ErrorAction SilentlyContinue)
  } else {
    try { if (-not $dx.HasExited) { $dx.Kill() } } catch {}
    $optionalProbeErrors += [pscustomobject]@{ Name = "dxdiag"; Error = "dxdiag did not finish within 35 seconds or did not write output." }
  }
} catch {
  $optionalProbeErrors += [pscustomobject]@{ Name = "dxdiag"; Error = $_.Exception.Message }
} finally {
  Remove-Item -LiteralPath $dxdiagPath -Force -ErrorAction SilentlyContinue
}

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
  "Microsoft-Windows-MemoryDiagnostics-Results",
  "Microsoft-Windows-Kernel-PnP",
  "Microsoft-Windows-UserPnp",
  "Microsoft-Windows-DriverFrameworks-UserMode"
)

$events = @()
foreach ($provider in $eventProviders) {
  $events += @(Invoke-Probe "event $provider" {
    Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = $provider; StartTime = $startTime } -MaxEvents 30 |
      Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
  })
}

$reliabilityRecords = @(Invoke-OptionalProbe "reliability records" {
  Get-CimInstance -Namespace root\cimv2 -ClassName Win32_ReliabilityRecords |
    Where-Object { $_.TimeGenerated -ge $startTime } |
    Select-Object -First 120 TimeGenerated, SourceName, ProductName, EventIdentifier, Message
})
$werEvents = @(Invoke-OptionalProbe "windows error reporting application events" {
  Get-WinEvent -FilterHashtable @{ LogName = "Application"; ProviderName = "Windows Error Reporting"; StartTime = $startTime } -MaxEvents 80 |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
})
$dumpRoots = @(
  (Join-Path $env:SystemRoot "LiveKernelReports"),
  (Join-Path $env:SystemRoot "Minidump"),
  (Join-Path $env:SystemRoot "MEMORY.DMP")
)
$crashDumpFiles = @()
foreach ($dumpRoot in $dumpRoots) {
  if (Test-Path -LiteralPath $dumpRoot) {
    $item = Get-Item -LiteralPath $dumpRoot -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer) {
      $crashDumpFiles += $item
    } else {
      $crashDumpFiles += @(Get-ChildItem -LiteralPath $dumpRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startTime -and $_.Extension -match "\.dmp|\.mdmp|\.hdmp" } |
        Select-Object -First 80)
    }
  }
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

foreach ($enclosure in $enclosures) {
  New-Component -Category "Chassis" -Name (($enclosure.Manufacturer, $enclosure.SMBIOSAssetTag | Where-Object { $_ }) -join " ") -Status "ok" -Confidence "low" -Evidence @{
    Manufacturer = $enclosure.Manufacturer
    ChassisTypes = $enclosure.ChassisTypes
    SerialNumber = $enclosure.SerialNumber
    AssetTag = $enclosure.SMBIOSAssetTag
  } -Signals @() -Recommendations @("Windows can identify the chassis, but only visual inspection can prove case damage, dust, loose cables, fan noise, or bent pins.")
}

foreach ($item in $tpm) {
  $tpmStatus = if ($item.IsEnabled_InitialValue -and $item.IsActivated_InitialValue) { "ok" } else { "info" }
  New-Component -Category "Firmware Security Hardware" -Name "TPM" -Status $tpmStatus -Confidence "medium" -Evidence @{
    ManufacturerId = $item.ManufacturerIdTxt
    SpecVersion = $item.SpecVersion
    IsEnabled = $item.IsEnabled_InitialValue
    IsActivated = $item.IsActivated_InitialValue
    IsOwned = $item.IsOwned_InitialValue
  } -Signals $(if ($tpmStatus -eq "ok") { @() } else { @("TPM is present but not fully enabled/activated according to Windows.") }) -Recommendations $(if ($tpmStatus -eq "ok") { @("TPM hardware is present and enabled according to Windows.") } else { @("Review BIOS/UEFI TPM settings only if you need TPM-backed security features.") })
}

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

$memoryDiagnosticResults = @($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-MemoryDiagnostics-Results" })
$memoryDiagnosticProblemEvents = @($memoryDiagnosticResults | Where-Object { $_.Message -match "hardware problems|errors|problem|failed" -and $_.Message -notmatch "no memory errors|no errors|detected no errors" })
$memoryDiagnosticOkEvents = @($memoryDiagnosticResults | Where-Object { $_.Message -match "no memory errors|no errors|detected no errors" })
$memoryDiagnosticStatus = if ($memoryDiagnosticProblemEvents.Count -gt 0) { "warning" } elseif ($memoryDiagnosticOkEvents.Count -gt 0) { "ok" } else { "unknown" }
New-Component -Category "Memory Diagnostic History" -Name "Windows Memory Diagnostic results" -Status $memoryDiagnosticStatus -Confidence "medium" -Evidence @{
  RecentResultCount = $memoryDiagnosticResults.Count
  ProblemResultCount = $memoryDiagnosticProblemEvents.Count
  LatestResult = if ($memoryDiagnosticResults.Count -gt 0) { Convert-ToBoundedText $memoryDiagnosticResults[0].Message 700 } else { $null }
} -Signals $(if ($memoryDiagnosticStatus -eq "warning") { @("$($memoryDiagnosticProblemEvents.Count) Windows Memory Diagnostic problem result(s) were found.") } elseif ($memoryDiagnosticStatus -eq "unknown") { @("No recent Windows Memory Diagnostic result was found in the scan window.") } else { @() }) -Recommendations $(if ($memoryDiagnosticStatus -eq "warning") { @("Run an offline memory test and isolate DIMMs/slots if errors reproduce.") } elseif ($memoryDiagnosticStatus -eq "unknown") { @("Run Windows Memory Diagnostic or MemTest86 from boot if RAM certainty is required.") } else { @("The latest Windows Memory Diagnostic result in the scan window did not report memory errors.") })

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

$smartPredicting = @($smartStatus | Where-Object { $_.PredictFailure -eq $true })
if ($smartStatus.Count -gt 0) {
  New-Component -Category "Storage SMART Prediction" -Name "MSStorageDriver FailurePredictStatus" -Status $(if ($smartPredicting.Count -gt 0) { "critical" } else { "ok" }) -Confidence "medium" -Evidence @{
    DeviceCount = $smartStatus.Count
    PredictFailureCount = $smartPredicting.Count
    Devices = @($smartStatus | Select-Object -First 20 InstanceName, PredictFailure, Reason)
  } -Signals $(if ($smartPredicting.Count -gt 0) { @("$($smartPredicting.Count) drive(s) report SMART predicted failure.") } else { @() }) -Recommendations $(if ($smartPredicting.Count -gt 0) { @("Back up immediately and replace the affected drive after vendor confirmation.") } else { @("Windows SMART failure prediction did not report imminent failure. Attribute-level vendor diagnostics are still stronger.") })
} else {
  New-Component -Category "Storage SMART Prediction" -Name "MSStorageDriver FailurePredictStatus" -Status "unknown" -Confidence "low" -Evidence @{ DeviceCount = 0 } -Signals @("Windows did not expose SMART failure-prediction rows to this scanner.") -Recommendations @("Use the SSD/HDD vendor tool or smartctl for drive attribute verification.")
}

$storageOptionalProbeErrors = @($optionalProbeErrors | Where-Object { $_.Name -match "physicaldisks|storage counters|smart" })
if ($storageOptionalProbeErrors.Count -gt 0) {
  New-Component -Category "Storage Advanced Health" -Name "SMART and Storage module telemetry" -Status "unknown" -Confidence "medium" -Evidence @{
    Errors = $storageOptionalProbeErrors
    FallbackUsed = "Win32_DiskDrive status and recent disk/NTFS/storage event scan"
  } -Signals @("Advanced storage health providers were unavailable on this Windows installation.") -Recommendations @("Install or run vendor storage diagnostics such as Samsung Magician, the SSD vendor tool, or smartctl to prove SMART attribute health beyond Windows generic disk status.")
}

$diskEvents = @($events | Where-Object { $_.ProviderName -match "disk|Disk|Ntfs|stor|volmgr" })
if ($diskEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Storage subsystem" -Title "Recent disk or filesystem reliability events" -Detail "Windows logged storage-related errors or warnings in the recent scan window." -Evidence "$($diskEvents.Count) event(s) since $startTime" -Recommendation "Review the listed disk, cable, controller, and filesystem evidence; run vendor diagnostics for affected drives." -Confidence "medium"
}

foreach ($volume in $volumes) {
  $sizeRemaining = if ($volume.FreeSpace) { [math]::Round(($volume.FreeSpace / 1GB), 2) } else { $null }
  $size = if ($volume.Size) { [math]::Round(($volume.Size / 1GB), 2) } else { $null }
  $status = "ok"
  $signals = @()
  New-Component -Category "Volume" -Name (($volume.DeviceID, $volume.VolumeName | Where-Object { $_ }) -join " ") -Status $status -Confidence "low" -Evidence @{
    DeviceID = $volume.DeviceID
    DriveType = $volume.DriveType
    FileSystem = $volume.FileSystem
    VolumeName = $volume.VolumeName
    SizeGB = $size
    FreeGB = $sizeRemaining
  } -Signals $signals -Recommendations @("Logical volume inventory is readable. Filesystem integrity still requires targeted read-only checks or repair tools against a specific volume.")
}

$dirtyVolumes = @($volumeDirtyResults | Where-Object { $_.IsDirty })
$unsupportedDirtyChecks = @($volumeDirtyResults | Where-Object { $_.IsUnsupported })
New-Component -Category "Volume Dirty Bit" -Name "Read-only filesystem repair flag check" -Status $(if ($dirtyVolumes.Count -gt 0) { "warning" } elseif ($volumeDirtyResults.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  CheckedVolumeCount = $volumeDirtyResults.Count
  DirtyVolumeCount = $dirtyVolumes.Count
  UnsupportedOrFailedCount = $unsupportedDirtyChecks.Count
  Results = @($volumeDirtyResults | Select-Object -First 20 DeviceID, IsDirty, IsUnsupported, Output)
} -Signals $(if ($dirtyVolumes.Count -gt 0) { @("$($dirtyVolumes.Count) volume(s) have the filesystem dirty bit set.") } elseif ($volumeDirtyResults.Count -eq 0) { @("No drive-letter volumes were eligible for fsutil dirty query.") } else { @() }) -Recommendations $(if ($dirtyVolumes.Count -gt 0) { @("Back up affected volumes, then run read-only checks before any repair; a dirty bit can indicate an interrupted write, filesystem issue, or storage instability.") } else { @("No filesystem dirty bit was reported by fsutil for checked volumes.") })

if ($dirtyVolumes.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Volume dirty bit" -Title "Filesystem dirty bit is set" -Detail "Windows reports at least one volume may need filesystem checking." -Evidence "$($dirtyVolumes.Count) dirty volume(s): $((@($dirtyVolumes | ForEach-Object { $_.DeviceID }) -join ', '))" -Recommendation "Back up first, then use read-only diagnostics or a planned repair window for the affected volume." -Confidence "medium"
}

foreach ($thermal in $thermalZones) {
  $tempC = if ($thermal.CurrentTemperature) { [math]::Round((($thermal.CurrentTemperature / 10) - 273.15), 1) } else { $null }
  $status = if ($tempC -and ($tempC -lt -20 -or $tempC -gt 100)) { "unknown" } elseif ($tempC -and $tempC -ge 85) { "warning" } else { "ok" }
  New-Component -Category "Thermal Sensor" -Name ($thermal.InstanceName) -Status $status -Confidence "low" -Evidence @{
    CurrentTemperatureC = $tempC
    RawTenthsKelvin = $thermal.CurrentTemperature
    CriticalTripPoint = $thermal.CriticalTripPoint
  } -Signals $(if ($status -eq "warning") { @("Thermal zone reports $tempC C.") } elseif ($status -eq "unknown") { @("Thermal zone value appears invalid or vendor-abstracted.") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Inspect cooling, airflow, dust, fans, and thermal paste; verify with vendor sensors under controlled load.") } else { @("No thermal warning was visible from ACPI thermal telemetry, but motherboard/vendor sensors are more reliable.") })
}

if ($thermalZones.Count -eq 0) {
  New-Component -Category "Thermal Sensor" -Name "ACPI thermal telemetry" -Status "unknown" -Confidence "low" -Evidence @{ SensorCount = 0 } -Signals @("Windows did not expose ACPI thermal zones to this scanner.") -Recommendations @("Use motherboard/GPU vendor tools for sensor-grade thermal validation.")
}

foreach ($fan in $fans) {
  $status = if ($fan.Status -and $fan.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Cooling Fan Sensor" -Name ($fan.Name) -Status $status -Confidence "low" -Evidence @{
    Status = $fan.Status
    ActiveCooling = $fan.ActiveCooling
    DesiredSpeed = $fan.DesiredSpeed
  } -Signals $(if ($status -eq "warning") { @("Fan WMI status is $($fan.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Inspect the fan physically and verify RPM in motherboard/vendor monitoring software.") } else { @("No fan fault was visible through WMI. Fan noise/bearing issues still require physical inspection.") })
}

if ($fans.Count -eq 0) {
  New-Component -Category "Cooling Fan Sensor" -Name "WMI fan telemetry" -Status "unknown" -Confidence "low" -Evidence @{ SensorCount = 0 } -Signals @("Windows did not expose fan sensors through WMI.") -Recommendations @("Use BIOS, motherboard software, or physical inspection to verify fans and pump behavior.")
}

$thirdPartySensors = @($openHardwareSensors + $libreHardwareSensors)
$thirdPartyTemperatures = @($thirdPartySensors | Where-Object { $_.SensorType -match "Temperature" })
$thirdPartyFans = @($thirdPartySensors | Where-Object { $_.SensorType -match "Fan" })
$hotThirdPartySensors = @($thirdPartyTemperatures | Where-Object { $null -ne $_.Value -and [double]$_.Value -ge 85 })
if ($thirdPartySensors.Count -gt 0) {
  New-Component -Category "Sensor Telemetry" -Name "OpenHardwareMonitor/LibreHardwareMonitor sensors" -Status $(if ($hotThirdPartySensors.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
    SensorCount = $thirdPartySensors.Count
    TemperatureSensorCount = $thirdPartyTemperatures.Count
    FanSensorCount = $thirdPartyFans.Count
    HotSensors = @($hotThirdPartySensors | Select-Object -First 20 Name, SensorType, Value, Identifier)
    SampleSensors = @($thirdPartySensors | Select-Object -First 20 Name, SensorType, Value, Identifier)
  } -Signals $(if ($hotThirdPartySensors.Count -gt 0) { @("$($hotThirdPartySensors.Count) third-party temperature sensor(s) read at or above 85 C.") } else { @() }) -Recommendations $(if ($hotThirdPartySensors.Count -gt 0) { @("Inspect cooling immediately and validate with BIOS/vendor sensor tools.") } else { @("Third-party sensor namespaces were available and did not show high temperature at scan time.") })
} else {
  $sensorProbeErrors = @($optionalProbeErrors | Where-Object { $_.Name -match "openhardwaremonitor|librehardwaremonitor" })
  New-Component -Category "Sensor Telemetry" -Name "OpenHardwareMonitor/LibreHardwareMonitor sensors" -Status "unknown" -Confidence "low" -Evidence @{
    SensorCount = 0
    ProbeErrors = $sensorProbeErrors
  } -Signals @("No OpenHardwareMonitor or LibreHardwareMonitor WMI sensor namespace was available.") -Recommendations @("Install or run a trusted sensor tool if CPU package temperature, fan RPM, pump RPM, VRM temperature, or motherboard sensor certainty is required.")
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

$dxProblemLines = @($dxdiagText | Where-Object {
  $line = [string]$_
  $line -match "problem|error|not working|failed" -and
  $line -notmatch "No problems found|No Problem|Problem Code:\s*(No Problem|Unknown)|Device Problem Code:\s*(No Problem|Unknown)|Windows Error Reporting:\s*$|GPU Mux Support: Development, Uninitialized - Query driver runtime status failed"
})
$dxOkCount = @($dxdiagText | Where-Object { $_ -match "No problems found" }).Count
if ($dxdiagText.Count -gt 0) {
  $dxStatus = if ($dxProblemLines.Count -gt 0) { "warning" } else { "ok" }
  New-Component -Category "DirectX Diagnostic" -Name "dxdiag display/audio/input" -Status $dxStatus -Confidence "medium" -Evidence @{
    NoProblemsFoundLines = $dxOkCount
    ProblemLines = @($dxProblemLines | Select-Object -First 12)
  } -Signals $(if ($dxStatus -eq "warning") { @("$($dxProblemLines.Count) dxdiag problem/error line(s) found.") } else { @() }) -Recommendations $(if ($dxStatus -eq "warning") { @("Review dxdiag problem lines, then check affected GPU/audio/input drivers or hardware.") } else { @("dxdiag did not report display/audio/input problems in its generated report.") })
} else {
  New-Component -Category "DirectX Diagnostic" -Name "dxdiag display/audio/input" -Status "unknown" -Confidence "low" -Evidence @{ OutputLines = 0 } -Signals @("dxdiag output was unavailable.") -Recommendations @("Run dxdiag manually if graphics/audio/input symptoms persist.")
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

foreach ($monitor in $monitors) {
  $status = if ($monitor.Status -and $monitor.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Monitor" -Name ($monitor.Name) -Status $status -Confidence "low" -Evidence @{
    ScreenWidth = $monitor.ScreenWidth
    ScreenHeight = $monitor.ScreenHeight
    PixelsPerXLogicalInch = $monitor.PixelsPerXLogicalInch
    PixelsPerYLogicalInch = $monitor.PixelsPerYLogicalInch
    Status = $monitor.Status
  } -Signals $(if ($status -eq "warning") { @("Monitor status is $($monitor.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check display cable/port/monitor power and driver detection.") } else { @("Monitor detection has no Windows status fault. Dead pixels, flicker, and cable intermittence require visual testing.") })
}

foreach ($keyboard in $keyboards) {
  $status = if ($keyboard.Status -and $keyboard.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Input Device" -Name ($keyboard.Name) -Status $status -Confidence "medium" -Evidence @{
    Status = $keyboard.Status
    Layout = $keyboard.Layout
    FunctionKeys = $keyboard.NumberOfFunctionKeys
  } -Signals $(if ($status -eq "warning") { @("Keyboard status is $($keyboard.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check USB/Bluetooth path or replace the keyboard if the status persists.") } else { @("Keyboard is detected without Windows status faults. Individual key failures require physical key testing.") })
}

foreach ($pointing in $pointingDevices) {
  $status = if ($pointing.Status -and $pointing.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Input Device" -Name ($pointing.Name) -Status $status -Confidence "medium" -Evidence @{
    Status = $pointing.Status
    HardwareType = $pointing.HardwareType
    PointingType = $pointing.PointingType
    Buttons = $pointing.NumberOfButtons
  } -Signals $(if ($status -eq "warning") { @("Pointing device status is $($pointing.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check USB/Bluetooth path or replace the pointing device if the status persists.") } else { @("Pointing device is detected without Windows status faults. Button/sensor issues require physical testing.") })
}

foreach ($usb in $usbControllers) {
  $status = if ($usb.Status -and $usb.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "USB Controller" -Name ($usb.Name) -Status $status -Confidence "medium" -Evidence @{
    Manufacturer = $usb.Manufacturer
    Status = $usb.Status
    ProtocolSupported = $usb.ProtocolSupported
  } -Signals $(if ($status -eq "warning") { @("USB controller status is $($usb.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check chipset/USB drivers and test affected ports with known-good devices.") } else { @("USB controller reports no Windows status fault. Individual ports still need physical test with a known-good device.") })
}

New-Component -Category "USB Inventory" -Name "USB hubs detected" -Status "info" -Confidence "medium" -Evidence @{
  HubCount = $usbHubs.Count
  Hubs = @($usbHubs | Select-Object -First 20 Name, Status, DeviceID)
} -Signals @() -Recommendations @("USB hub inventory is captured. Intermittent ports/cables require physical testing with known-good devices.")

$pciProblems = @($pciDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
New-Component -Category "PCI and Expansion Bus" -Name "PCI/PCIe device inventory" -Status $(if ($pciProblems.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  DeviceCount = $pciDevices.Count
  ProblemDeviceCount = $pciProblems.Count
  ProblemDevices = @($pciProblems | Select-Object -First 20 Name, PNPClass, ConfigManagerErrorCode, Status)
  SampleDevices = @($pciDevices | Select-Object -First 25 Name, PNPClass, Status)
} -Signals $(if ($pciProblems.Count -gt 0) { @("$($pciProblems.Count) PCI/PCIe device(s) have Device Manager problem codes.") } else { @() }) -Recommendations $(if ($pciProblems.Count -gt 0) { @("Fix PCI/PCIe problem devices before reseating cards or replacing hardware.") } else { @("No PCI/PCIe Device Manager problem code was found. Link stability under load still needs symptom-driven testing.") })

New-Component -Category "Firmware Device Inventory" -Name "Firmware-class PnP devices" -Status "info" -Confidence "medium" -Evidence @{
  DeviceCount = $firmwareDevices.Count
  Devices = @($firmwareDevices | Select-Object -First 20 Name, PNPClass, Status, ConfigManagerErrorCode)
} -Signals @() -Recommendations @("Firmware-class device inventory is captured. BIOS/firmware updates should only be considered for a specific fix or vendor recommendation.")

foreach ($sound in $soundDevices) {
  $status = if ($sound.Status -and $sound.Status -ne "OK") { "warning" } else { "ok" }
  New-Component -Category "Audio" -Name ($sound.Name) -Status $status -Confidence "medium" -Evidence @{
    Manufacturer = $sound.Manufacturer
    Status = $sound.Status
    ProductName = $sound.ProductName
  } -Signals $(if ($status -eq "warning") { @("Audio device status is $($sound.Status).") } else { @() }) -Recommendations $(if ($status -eq "warning") { @("Check the device path, cabling, and driver package.") } else { @("No audio hardware fault was reported.") })
}

$unsignedDrivers = @($signedDrivers | Where-Object { $_.IsSigned -eq $false })
New-Component -Category "Driver Integrity" -Name "PnP signed driver inventory" -Status $(if ($unsignedDrivers.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  DriverCount = $signedDrivers.Count
  UnsignedDriverCount = $unsignedDrivers.Count
  UnsignedDrivers = @($unsignedDrivers | Select-Object -First 20 DeviceName, DriverProviderName, DriverVersion)
} -Signals $(if ($unsignedDrivers.Count -gt 0) { @("$($unsignedDrivers.Count) unsigned PnP driver(s) found.") } else { @() }) -Recommendations $(if ($unsignedDrivers.Count -gt 0) { @("Review unsigned drivers; driver integrity issues can mimic hardware failures.") } else { @("All enumerated PnP drivers report signed status.") })

New-Component -Category "Power Capabilities" -Name "powercfg /a" -Status "info" -Confidence "medium" -Evidence @{
  Lines = @($powerCfgA | Select-Object -First 40)
} -Signals @() -Recommendations @("Power capability data was collected. PSU quality, wall power, and power-cable problems still require physical/load testing.")

$deviceReliabilityEvents = @($events | Where-Object { $_.ProviderName -match "Kernel-PnP|UserPnp|DeviceSetupManager|DriverFrameworks" })
$deviceReliabilityProblemEvents = @($deviceReliabilityEvents | Where-Object { $_.LevelDisplayName -match "Warning|Error|Critical" })
New-Component -Category "Device Reliability Events" -Name "Recent PnP/device setup history" -Status $(if ($deviceReliabilityProblemEvents.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  EventCount = $deviceReliabilityEvents.Count
  ProblemEventCount = $deviceReliabilityProblemEvents.Count
  ProblemEvents = @($deviceReliabilityProblemEvents | Select-Object -First 20 TimeCreated, Id, ProviderName, LevelDisplayName, @{ Name = "Message"; Expression = { Convert-ToBoundedText $_.Message 500 } })
} -Signals $(if ($deviceReliabilityProblemEvents.Count -gt 0) { @("$($deviceReliabilityProblemEvents.Count) recent PnP/device setup warning or error event(s).") } else { @() }) -Recommendations $(if ($deviceReliabilityProblemEvents.Count -gt 0) { @("Review the listed device setup/driver events; they can indicate failing devices, unstable USB paths, or driver install problems.") } else { @("No recent PnP/device setup warning or error event was found in the scan window.") })

if ($deviceReliabilityProblemEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Device reliability" -Title "Recent PnP or device setup warning events" -Detail "Windows logged device setup, PnP, or driver-framework warning/error events in the scan window." -Evidence "$($deviceReliabilityProblemEvents.Count) event(s) since $startTime" -Recommendation "Inspect the listed device IDs/messages and correlate them with recently connected hardware or driver changes." -Confidence "medium"
}

$hardwareReliabilityRecords = @($reliabilityRecords | Where-Object {
  $recordText = "$(Convert-ToBoundedText $_.SourceName 200) $(Convert-ToBoundedText $_.ProductName 300) $(Convert-ToBoundedText $_.Message 1200)"
  $recordText -match "LiveKernelEvent|hardware error|BlueScreen|bugcheck|WHEA|VIDEO_TDR|WATCHDOG|display driver|nvlddmkm|amdkmdag|disk has|bad block|memory corruption|driver power state|device reset|stopped responding" -and
  $recordText -notmatch "WindowsUpdateClient|Installation Successful|Installation Failure|Security Intelligence Update|Windows successfully installed|Windows failed to install"
})
$werHardwareEvents = @($werEvents | Where-Object {
  $_.Message -match "LiveKernelEvent|hardware error|BlueScreen|bugcheck|WHEA|VIDEO_TDR|WATCHDOG|display driver|nvlddmkm|amdkmdag|disk has|bad block|memory corruption|driver power state|device reset|stopped responding"
})
$crashSignalCount = $hardwareReliabilityRecords.Count + $werHardwareEvents.Count
New-Component -Category "Reliability Monitor" -Name "Hardware-related crash and WER history" -Status $(if ($crashSignalCount -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  ReliabilityRecordCount = $reliabilityRecords.Count
  HardwareReliabilityRecordCount = $hardwareReliabilityRecords.Count
  WindowsErrorReportingHardwareEventCount = $werHardwareEvents.Count
  ReliabilityRecords = @($hardwareReliabilityRecords | Select-Object -First 20 TimeGenerated, SourceName, ProductName, EventIdentifier, @{ Name = "Message"; Expression = { Convert-ToBoundedText $_.Message 700 } })
  WindowsErrorReportingEvents = @($werHardwareEvents | Select-Object -First 20 TimeCreated, Id, @{ Name = "Message"; Expression = { Convert-ToBoundedText $_.Message 700 } })
} -Signals $(if ($crashSignalCount -gt 0) { @("$crashSignalCount hardware-related Reliability Monitor / Windows Error Reporting crash signal(s) were found.") } else { @() }) -Recommendations $(if ($crashSignalCount -gt 0) { @("Review the crash bucket names and correlate them with GPU, storage, RAM, device, or driver symptoms before replacing hardware.") } else { @("No hardware-related Reliability Monitor or Windows Error Reporting crash signal was found in the scan window.") })

if ($crashSignalCount -gt 0) {
  New-Finding -Severity "warning" -Component "Reliability Monitor" -Title "Recent hardware-related crash or WER evidence" -Detail "Reliability Monitor or Windows Error Reporting contains crash records that match hardware, LiveKernelEvent, bugcheck, driver, disk, display, memory, or device patterns." -Evidence "$crashSignalCount record(s) since $startTime" -Recommendation "Inspect the listed bucket/message text, then test the implicated hardware path with vendor tools or controlled load only if the pattern repeats." -Confidence "medium"
}

$recentCrashDumps = @($crashDumpFiles | Where-Object { $_.LastWriteTime -ge $startTime })
$liveKernelDumps = @($recentCrashDumps | Where-Object { $_.FullName -match "LiveKernelReports" })
New-Component -Category "Crash Dump Artifacts" -Name "Recent Windows dump files" -Status $(if ($recentCrashDumps.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  RecentDumpCount = $recentCrashDumps.Count
  LiveKernelDumpCount = $liveKernelDumps.Count
  Dumps = @($recentCrashDumps | Sort-Object LastWriteTime -Descending | Select-Object -First 30 @{ Name = "Path"; Expression = { $_.FullName } }, LastWriteTime, @{ Name = "SizeMB"; Expression = { [math]::Round($_.Length / 1MB, 2) } })
} -Signals $(if ($recentCrashDumps.Count -gt 0) { @("$($recentCrashDumps.Count) recent Windows crash dump artifact(s) were found.") } else { @() }) -Recommendations $(if ($recentCrashDumps.Count -gt 0) { @("Preserve these dumps before cleanup; analyze them to identify whether GPU, storage, USB, RAM, driver, or power instability is implicated.") } else { @("No recent Windows crash dump artifacts were found in the checked dump locations.") })

if ($recentCrashDumps.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Crash dump artifacts" -Title "Recent Windows crash dump files exist" -Detail "Crash dump files can contain the strongest evidence for intermittent hardware, driver, GPU, USB, RAM, storage, or power faults." -Evidence "$($recentCrashDumps.Count) dump file(s), including $($liveKernelDumps.Count) LiveKernelReports file(s), since $startTime" -Recommendation "Do not delete the dump files until they are analyzed; correlate timestamps with crashes or hardware symptoms." -Confidence "medium"
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

New-Diagnostic -Name "Device Manager problem-code sweep" -Status $(if ($pnpProblems.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$($pnpProblems.Count) problem device(s) from $($pnpAll.Count) enumerated PnP device(s)." -NextStep $(if ($pnpProblems.Count -gt 0) { "Open Device Manager and fix the listed problem-code devices first." } else { "No Device Manager problem codes found." })
New-Diagnostic -Name "DirectX display/audio/input diagnostic" -Status $(if ($dxdiagText.Count -eq 0) { "unavailable" } elseif ($dxProblemLines.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$(if ($dxdiagText.Count -gt 0) { "$dxOkCount 'No problems found' line(s), $($dxProblemLines.Count) problem/error line(s)." } else { "dxdiag did not return output." })" -NextStep $(if ($dxProblemLines.Count -gt 0) { "Review dxdiag problem lines in the raw report." } else { "No dxdiag problem lines found." })
New-Diagnostic -Name "Storage SMART and reliability telemetry" -Status $(if ($optionalProbeErrors | Where-Object { $_.Name -match "physicaldisks|storage counters|smart" }) { "limited" } elseif ($smartStatus | Where-Object { $_.PredictFailure -eq $true }) { "critical" } else { "passed" }) -Evidence "$(if ($optionalProbeErrors | Where-Object { $_.Name -match "physicaldisks|storage counters|smart" }) { "Windows advanced storage providers were unavailable; generic disk status and event logs were used." } else { "Windows advanced storage providers returned data." })" -NextStep "Use vendor SSD/HDD diagnostics or smartctl for full drive attribute verification."
New-Diagnostic -Name "WHEA and recent hardware event sweep" -Status $(if (($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-WHEA-Logger" }).Count -gt 0) { "warning" } else { "passed" }) -Evidence "$(($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-WHEA-Logger" }).Count) WHEA event(s) in the last $RecentDays day(s)." -NextStep "If WHEA events exist, correlate the listed component with CPU/RAM/GPU/PCIe/power hardware."
New-Diagnostic -Name "NVIDIA GPU live telemetry" -Status $(if ($nvidiaCommand -and $nvidiaRows.Count -gt 0) { "passed" } elseif ($videoControllers | Where-Object { $_.Name -match "NVIDIA" }) { "limited" } else { "unavailable" }) -Evidence "$(if ($nvidiaRows.Count -gt 0) { ($nvidiaRows | ForEach-Object { "$($_.Name): $($_.TemperatureC)C, PState $($_.PState), driver $($_.DriverVersion)" }) -join "; " } else { "nvidia-smi telemetry not available or no NVIDIA GPU detected." })" -NextStep "Run vendor/load diagnostics only if symptoms happen under GPU load."
New-Diagnostic -Name "Thermal and fan telemetry" -Status $(if ($hotThirdPartySensors.Count -gt 0) { "warning" } elseif ($thermalZones.Count -eq 0 -and $fans.Count -eq 0 -and $thirdPartySensors.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($thermalZones.Count) ACPI thermal zone(s), $($fans.Count) WMI fan sensor(s), $($thirdPartySensors.Count) third-party sensor row(s)." -NextStep "Use BIOS/vendor tools and physical inspection for definitive fan, pump, dust, and thermal-paste validation."
New-Diagnostic -Name "RAM live evidence and diagnostic history" -Status $(if ($memoryDiagnosticProblemEvents.Count -gt 0) { "warning" } elseif ($memoryDiagnosticOkEvents.Count -gt 0) { "passed" } else { "limited" }) -Evidence "$($memoryModules.Count) DIMM(s) inventoried; $($memoryDiagnosticResults.Count) Windows Memory Diagnostic result event(s) in the last $RecentDays day(s)." -NextStep "Run Windows Memory Diagnostic or MemTest86 from boot for current physical RAM fault testing."
New-Diagnostic -Name "PCI/PCIe and device setup reliability" -Status $(if ($pciProblems.Count -gt 0 -or $deviceReliabilityProblemEvents.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$($pciDevices.Count) PCI/PCIe device(s), $($pciProblems.Count) PCI problem device(s), $($deviceReliabilityProblemEvents.Count) recent PnP/device setup warning or error event(s)." -NextStep "If warnings exist, fix the specific device/driver path before assuming motherboard, slot, or expansion-card failure."
New-Diagnostic -Name "Reliability Monitor and WER crash sweep" -Status $(if ($crashSignalCount -gt 0) { "warning" } elseif ($reliabilityRecords.Count -eq 0 -and $werEvents.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($hardwareReliabilityRecords.Count) hardware-matching Reliability Monitor record(s), $($werHardwareEvents.Count) hardware-matching Windows Error Reporting event(s)." -NextStep "If records exist, inspect the crash bucket/message text and correlate repeated patterns before replacing hardware."
New-Diagnostic -Name "Crash dump artifact sweep" -Status $(if ($recentCrashDumps.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$($recentCrashDumps.Count) recent dump file(s), $($liveKernelDumps.Count) LiveKernelReports file(s), in checked Windows dump locations." -NextStep "If dump files exist, analyze them before cleanup to identify the implicated driver or hardware path."
New-Diagnostic -Name "Filesystem dirty-bit sweep" -Status $(if ($dirtyVolumes.Count -gt 0) { "warning" } elseif ($volumeDirtyResults.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($volumeDirtyResults.Count) volume(s) checked; $($dirtyVolumes.Count) dirty volume(s); $($unsupportedDirtyChecks.Count) unsupported/failed check(s)." -NextStep "If a volume is dirty, back up first and schedule filesystem diagnostics before repair."
New-Diagnostic -Name "Physical inspection boundary" -Status "not_run" -Evidence "Software cannot see loose cables, dust, port wear, bent pins, fan bearing noise, PSU ripple, swollen capacitors, or intermittent movement-sensitive faults." -NextStep "Physically inspect and test ports/cables/fans/PSU only if symptoms or this report point there."

if ($probeErrors.Count -gt 0) {
  New-Component -Category "Scanner Coverage" -Name "Probe errors" -Status "unknown" -Confidence "medium" -Evidence @{ Errors = $probeErrors } -Signals @("$($probeErrors.Count) probe(s) returned errors or no access.") -Recommendations @("Review probe errors before treating missing telemetry as healthy.")
}

$report = [pscustomobject]@{
  scanner = "hardware-truth-scanner"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  host = Convert-ToBoundedText $hostName 200
  os = Convert-ToBoundedText "$($os.Caption) $($os.Version)" 300
  scanWindowDays = $RecentDays
  summary = [pscustomobject]@{
    overallStatus = "unknown"
    componentCount = 0
    findingCount = 0
    criticalCount = 0
    warningCount = 0
    unknownCount = 0
  }
  components = Convert-ToJsonSafe -Value @($components) -Depth 5 -MaxItems 500
  findings = Convert-ToJsonSafe -Value @($findings) -Depth 4 -MaxItems 500
  diagnostics = Convert-ToJsonSafe -Value @($diagnostics) -Depth 3 -MaxItems 100
  coverageLimits = @(
    "Software telemetry cannot guarantee detection of loose internal cables, dust buildup, bad ports that were not exercised, swollen capacitors, bent pins, cracked solder joints, fan bearing noise, weak PSU ripple, or intermittent faults that did not occur during the scan window.",
    "RAM health cannot be proven from inventory alone. A boot-level memory diagnostic or MemTest86 pass is required for physical RAM certainty.",
    "CPU, GPU, PSU, and cooling problems that appear only under sustained load need a controlled stress test with temperature and power monitoring.",
    "SMART and Windows storage health are strong signals, but vendor diagnostics are still required before trusting or discarding a drive.",
    "This scan is read-only and avoids rebooting, destructive filesystem repair, firmware flashing, and hardware stress testing."
  )
  raw = [pscustomobject]@{
    RecentEventCount = @($events).Count
    RecentEvents = @($events | Select-Object -First 40 | ForEach-Object {
      "$(Convert-ToBoundedText $_.TimeCreated 40) | Id=$($_.Id) | Provider=$(Convert-ToBoundedText $_.ProviderName 120) | Level=$(Convert-ToBoundedText $_.LevelDisplayName 80) | $(Convert-ToBoundedText $_.Message 500)"
    })
    NvidiaDetail = @($nvidiaDetails | Select-Object -First 120 | ForEach-Object { Convert-ToBoundedText $_ 500 })
    DxDiagProblemLines = @($dxProblemLines | Select-Object -First 40 | ForEach-Object { Convert-ToBoundedText $_ 500 })
    PowerCfgAvailableSleepStates = @($powerCfgA | Select-Object -First 60 | ForEach-Object { Convert-ToBoundedText $_ 500 })
    PnPProblemDeviceText = @($problemDevicesText | Select-Object -First 80 | ForEach-Object { Convert-ToBoundedText $_ 500 })
    ReliabilityRecords = @($hardwareReliabilityRecords | Select-Object -First 40 | ForEach-Object {
      "$(Convert-ToBoundedText $_.TimeGenerated 40) | Source=$(Convert-ToBoundedText $_.SourceName 120) | Product=$(Convert-ToBoundedText $_.ProductName 120) | Id=$($_.EventIdentifier) | $(Convert-ToBoundedText $_.Message 700)"
    })
    WindowsErrorReportingEvents = @($werHardwareEvents | Select-Object -First 40 | ForEach-Object {
      "$(Convert-ToBoundedText $_.TimeCreated 40) | Id=$($_.Id) | $(Convert-ToBoundedText $_.Message 700)"
    })
    CrashDumpFiles = @($recentCrashDumps | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object {
      "$(Convert-ToBoundedText $_.LastWriteTime 40) | $([math]::Round($_.Length / 1MB, 2)) MB | $(Convert-ToBoundedText $_.FullName 500)"
    })
    VolumeDirtyResults = @($volumeDirtyResults | ForEach-Object {
      "$($_.DeviceID) | Dirty=$($_.IsDirty) | Unsupported=$($_.IsUnsupported) | $(Convert-ToBoundedText (($_.Output) -join ' ') 500)"
    })
    ProbeErrors = @($probeErrors | ForEach-Object { "$(Convert-ToBoundedText $_.Name 120): $(Convert-ToBoundedText $_.Error 500)" })
    OptionalProbeErrors = @($optionalProbeErrors | ForEach-Object { "$(Convert-ToBoundedText $_.Name 120): $(Convert-ToBoundedText $_.Error 500)" })
  }
}

$report | ConvertTo-Json -Depth 8 -Compress:$false
