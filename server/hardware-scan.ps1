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
    } elseif ($propertyValue -is [array]) {
      $safeObject[$property.Name] = Convert-ToSafeEvidenceValue $propertyValue
    } elseif ($propertyValue -is [hashtable]) {
      $safeObject[$property.Name] = Convert-ToSafeEvidenceValue $propertyValue
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

function Get-AssociationReferenceDeviceId {
  param($Reference)

  if ($null -eq $Reference) { return $null }
  $deviceIdProperty = $Reference.PSObject.Properties["DeviceID"]
  if ($deviceIdProperty -and -not [string]::IsNullOrWhiteSpace([string]$deviceIdProperty.Value)) {
    return [string]$deviceIdProperty.Value
  }

  $text = [string]$Reference
  if ($text -match 'DeviceID="([^"]+)"') {
    return (($Matches[1] -replace "\\\\", "\") -replace '\\"', '"')
  }
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Convert-EdidText {
  param($Values)

  if ($null -eq $Values) { return $null }
  $chars = @()
  foreach ($value in @($Values)) {
    $number = 0
    if ([int]::TryParse(([string]$value), [ref]$number) -and $number -gt 0 -and $number -lt 127) {
      $chars += [char]$number
    }
  }
  $text = (-join $chars).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Get-VideoOutputTechnologyName {
  param($Value)

  switch ([int64]$Value) {
    -2 { return "Uninitialized" }
    -1 { return "Other" }
    0 { return "HD15/VGA" }
    1 { return "S-Video" }
    2 { return "Composite video" }
    3 { return "Component video" }
    4 { return "DVI" }
    5 { return "HDMI" }
    6 { return "LVDS/internal panel" }
    8 { return "D-JPN" }
    9 { return "SDI" }
    10 { return "DisplayPort external" }
    11 { return "DisplayPort embedded" }
    12 { return "UDI external" }
    13 { return "UDI embedded" }
    14 { return "SDTVDongle" }
    15 { return "Miracast" }
    16 { return "Indirect wired" }
    2147483648 { return "Internal" }
    default { return "Unknown ($Value)" }
  }
}

function Get-DumpHint {
  param(
    [System.IO.FileInfo]$File,
    [int]$MaxBytes = 8388608
  )

  $hintPatterns = "WATCHDOG[0-9]*|LiveKernelEvent|VIDEO_TDR_FAILURE|DPC_WATCHDOG_VIOLATION|VIDEO_ENGINE_TIMEOUT_DETECTED|VIDEO_SCHEDULER_INTERNAL_ERROR|nvlddmkm|amdkmdag|dxgkrnl|dxgmms2|WHEA|BugCheck|USBXHCI|USBHUB|storport|stornvme|storahci|disk|ntfs|memory_corruption|MEMORY_MANAGEMENT|DRIVER_POWER_STATE_FAILURE|PCI|HDAudBus|AUDIO"
  $result = [ordered]@{
    Path = $File.FullName
    LastWriteTime = $File.LastWriteTime
    SizeMB = [math]::Round($File.Length / 1MB, 2)
    ScannedBytes = 0
    ScanStatus = "not_scanned"
    Hints = @()
  }

  try {
    $bytesToRead = [math]::Min([int64]$MaxBytes, [int64]$File.Length)
    if ($bytesToRead -le 0) {
      $result["ScanStatus"] = "empty"
      return [pscustomobject]$result
    }

    $buffer = New-Object byte[] $bytesToRead
    $stream = [System.IO.File]::Open($File.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $read = $stream.Read($buffer, 0, $buffer.Length)
    } finally {
      $stream.Dispose()
    }

    if ($read -lt $buffer.Length) {
      $buffer = $buffer[0..([math]::Max(0, $read - 1))]
    }

    $result["ScannedBytes"] = $read
    $folderName = Split-Path -Leaf (Split-Path -Parent $File.FullName)
    $fileName = $File.Name
    $ascii = [Text.Encoding]::ASCII.GetString($buffer)
    $unicode = [Text.Encoding]::Unicode.GetString($buffer)
    $text = "$folderName $fileName`n$ascii`n$unicode"
    $hints = @([regex]::Matches($text, $hintPatterns, [Text.RegularExpressions.RegexOptions]::IgnoreCase) |
      ForEach-Object { $_.Value } |
      Where-Object { $_ } |
      Select-Object -Unique -First 50)

    $result["Hints"] = @($hints)
    $result["ScanStatus"] = if ($hints.Count -gt 0) { "hints_found" } else { "no_keyword_hints" }
    return [pscustomobject]$result
  } catch {
    $result["ScanStatus"] = "failed: $($_.Exception.Message)"
    return [pscustomobject]$result
  }
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

function New-PnpInventoryComponent {
  param(
    [string]$Name,
    [array]$Devices,
    [string]$AbsentRecommendation,
    [string]$HealthyRecommendation,
    [string]$ProblemRecommendation
  )

  $problemDevices = @($Devices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
  $status = if ($problemDevices.Count -gt 0) { "warning" } elseif ($Devices.Count -eq 0) { "info" } else { "ok" }
  $signals = @()
  if ($problemDevices.Count -gt 0) {
    $signals = @("$($problemDevices.Count) device(s) in this peripheral group have Device Manager problem codes.")
  }
  $recommendations = if ($problemDevices.Count -gt 0) {
    @($ProblemRecommendation)
  } elseif ($Devices.Count -eq 0) {
    @($AbsentRecommendation)
  } else {
    @($HealthyRecommendation)
  }

  New-Component -Category "Peripheral Inventory" -Name $Name -Status $status -Confidence "medium" -Evidence @{
    DeviceCount = $Devices.Count
    ProblemDeviceCount = $problemDevices.Count
    ProblemDevices = @($problemDevices | Select-Object -First 20 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
    SampleDevices = @($Devices | Select-Object -First 30 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  } -Signals $signals -Recommendations $recommendations
}

function As-Text {
  param($Value)
  if ($null -eq $Value) { return "" }
  if ($Value -is [array]) { return (($Value | ForEach-Object { [string]$_ }) -join ", ") }
  return [string]$Value
}

function Convert-PnpUtilDriverPackages {
  param([string[]]$Lines)

  $packages = @()
  $current = [ordered]@{ Files = @() }
  foreach ($line in @($Lines)) {
    if ($line -match "^Published Name:\s*(.+)$") {
      if ($current.Contains("PublishedName")) { $packages += [pscustomobject]$current }
      $current = [ordered]@{ Files = @(); PublishedName = $Matches[1].Trim() }
    } elseif ($line -match "^Original Name:\s*(.+)$") {
      $current["OriginalName"] = $Matches[1].Trim()
    } elseif ($line -match "^Provider Name:\s*(.+)$") {
      $current["ProviderName"] = $Matches[1].Trim()
    } elseif ($line -match "^Class Name:\s*(.+)$") {
      $current["ClassName"] = $Matches[1].Trim()
    } elseif ($line -match "^Class GUID:\s*(.+)$") {
      $current["ClassGuid"] = $Matches[1].Trim()
    } elseif ($line -match "^Driver Version:\s*(.+)$") {
      $current["DriverVersion"] = $Matches[1].Trim()
    } elseif ($line -match "^Signer Name:\s*(.+)$") {
      $current["SignerName"] = $Matches[1].Trim()
    } elseif ($line -match "^Catalog File:\s*(.+)$") {
      $current["CatalogFile"] = $Matches[1].Trim()
    } elseif ($line -match "^\s{4}(.+)$") {
      $current["Files"] += $Matches[1].Trim()
    }
  }
  if ($current.Contains("PublishedName")) { $packages += [pscustomobject]$current }
  return @($packages)
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

function Invoke-BoundedTextProcess {
  param(
    [string]$Name,
    [string]$FilePath,
    [string[]]$Arguments,
    [int]$TimeoutMs = 45000
  )

  $stdoutPath = Join-Path $env:TEMP ("hardware-truth-" + [guid]::NewGuid().ToString("N") + ".out")
  $stderrPath = Join-Path $env:TEMP ("hardware-truth-" + [guid]::NewGuid().ToString("N") + ".err")
  $timedOut = $false
  $exitCode = $null
  try {
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (-not $process.WaitForExit($TimeoutMs)) {
      $timedOut = $true
      try { $process.Kill() } catch {}
    } else {
      $exitCode = $process.ExitCode
    }

    $stdout = @(Get-Content -Path $stdoutPath -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
    $stderr = @(Get-Content -Path $stderrPath -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
      Name = $Name
      FilePath = $FilePath
      Arguments = ($Arguments -join " ")
      TimedOut = $timedOut
      ExitCode = $exitCode
      Output = $stdout
      ErrorOutput = $stderr
    }
  } catch {
    $script:optionalProbeErrors += [pscustomobject]@{
      Name = $Name
      Error = $_.Exception.Message
    }
    return [pscustomobject]@{
      Name = $Name
      FilePath = $FilePath
      Arguments = ($Arguments -join " ")
      TimedOut = $false
      ExitCode = $null
      Output = @()
      ErrorOutput = @($_.Exception.Message)
    }
  } finally {
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

$probeErrors = @()
$optionalProbeErrors = @()
$components = @()
$findings = @()
$diagnostics = @()
$startTime = (Get-Date).AddDays(-1 * $RecentDays)
$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { (Invoke-Probe "hostname" { hostname.exe }) -join "" }
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$computer = Invoke-Probe "computer" { Get-CimInstance Win32_ComputerSystem }
$os = Invoke-Probe "os" { Get-CimInstance Win32_OperatingSystem }
$bios = Invoke-Probe "bios" { Get-CimInstance Win32_BIOS }
$baseBoard = Invoke-Probe "baseboard" { Get-CimInstance Win32_BaseBoard }
$processors = @(Invoke-Probe "cpu" { Get-CimInstance Win32_Processor })
$processorPerfCounters = @(Invoke-OptionalProbe "processor information counters" { Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation })
$systemPerfCounters = @(Invoke-OptionalProbe "system processor queue counters" { Get-CimInstance Win32_PerfFormattedData_PerfOS_System })
$memoryModules = @(Invoke-Probe "memory" { Get-CimInstance Win32_PhysicalMemory })
$memoryArrays = @(Invoke-OptionalProbe "memory arrays" { Get-CimInstance Win32_PhysicalMemoryArray })
$memoryPerfCounters = @(Invoke-OptionalProbe "memory performance counters" { Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory })
$pageFileUsage = @(Invoke-OptionalProbe "page file usage" { Get-CimInstance Win32_PageFileUsage })
$diskDrives = @(Invoke-Probe "diskdrives" { Get-CimInstance Win32_DiskDrive })
$diskPartitions = @(Invoke-Probe "disk partitions" { Get-CimInstance Win32_DiskPartition })
$diskDriveToPartition = @(Invoke-Probe "disk drive partition map" { Get-CimInstance Win32_DiskDriveToDiskPartition })
$logicalDiskToPartition = @(Invoke-Probe "logical disk partition map" { Get-CimInstance Win32_LogicalDiskToPartition })
$physicalDiskPerfCounters = @(Invoke-OptionalProbe "physical disk perf counters" { Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk })
$logicalDiskPerfCounters = @(Invoke-OptionalProbe "logical disk perf counters" { Get-CimInstance Win32_PerfFormattedData_PerfDisk_LogicalDisk })
$physicalDisks = @()
$storageCounters = @()
$optionalProbeErrors += [pscustomobject]@{ Name = "physicaldisks"; Error = "Skipped Get-PhysicalDisk because this host's Windows Storage provider returns invalid-property errors/hangs; using Win32_DiskDrive and event evidence instead." }
$optionalProbeErrors += [pscustomobject]@{ Name = "storage counters"; Error = "Skipped Get-StorageReliabilityCounter because it depends on the same unstable Windows Storage provider on this host." }
$smartStatus = @(Invoke-OptionalProbe "smart predict" { Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus })
$volumes = @(Invoke-Probe "logical volumes" { Get-CimInstance Win32_LogicalDisk })
$videoControllers = @(Invoke-Probe "video" { Get-CimInstance Win32_VideoController })
$soundDevices = @(Invoke-Probe "audio" { Get-CimInstance Win32_SoundDevice })
$networkAdapters = @(Invoke-Probe "network" { Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true } })
$networkInterfaceCounters = @(Invoke-OptionalProbe "network interface counters" { Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface })
$batteries = @(Invoke-Probe "battery" { Get-CimInstance Win32_Battery })
$powerSupplies = @(Invoke-OptionalProbe "power supplies" { Get-CimInstance Win32_PowerSupply })
$upsDevices = @(Invoke-OptionalProbe "ups devices" { Get-CimInstance Win32_UninterruptiblePowerSupply })
$pnpProblems = @(Invoke-Probe "pnp problems" { Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -ne 0 } })
$pnpAll = @(Invoke-Probe "pnp all" { Get-CimInstance Win32_PnPEntity })
$pciDevices = @($pnpAll | Where-Object { $_.PNPDeviceID -like "PCI\*" })
$pciBridgeDevices = @($pciDevices | Where-Object { $_.Name -match "PCI Express|PCIe|Root Port|Upstream Switch Port|Downstream Switch Port|Switch Port|PCI-to-PCI" } | Sort-Object Name, DeviceID -Unique)
$pciLaneSensitiveDevices = @($pciDevices | Where-Object { $_.PNPClass -in @("Display", "Net", "SCSIAdapter", "HDC", "USB") -or $_.Name -match "GPU|NVIDIA|Radeon|NVMe|NVM Express|SATA|AHCI|USB|USB4|Ethernet|Wi-Fi|Thunderbolt|High Definition Audio" } | Sort-Object PNPClass, Name, DeviceID -Unique)
$firmwareDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "Firmware" -or $_.Name -match "firmware|BIOS|UEFI" })
$usbPnpDevices = @($pnpAll | Where-Object { $_.PNPDeviceID -like "USB\*" -or $_.PNPDeviceID -like "USBSTOR\*" -or $_.PNPDeviceID -like "USB4\*" })
$usbProblemDevices = @($usbPnpDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
$usbStorageDevices = @($usbPnpDevices | Where-Object { $_.PNPClass -match "DiskDrive|SCSIAdapter" -or $_.Name -match "mass storage|attached scsi|UAS" -or $_.PNPDeviceID -like "USBSTOR\*" })
$usbHubDevices = @($usbPnpDevices | Where-Object { $_.Name -match "hub|root hub|router|composite" -or $_.PNPClass -eq "USB" })
$storageControllerDevices = @($pnpAll | Where-Object { $_.PNPClass -match "HDC|SCSIAdapter|StorageController" -or (($_.PNPClass -notin @("DiskDrive", "Volume")) -and $_.Name -match "storage controller|NVMe controller|NVM Express Controller|SATA controller|AHCI|RAID controller|SCSI adapter|UAS|USB Attached|Standard NVM|Microsoft Storage Spaces|stornvme|storahci") } | Sort-Object DeviceID -Unique)
$storageControllerProblemDevices = @($storageControllerDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
$hidPeripheralDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "HIDClass" -or $_.Name -match "HID|Human Interface|game controller|gamepad|joystick|XINPUT|touchscreen|touchpad|\bpen\b|digitizer" })
$bluetoothPeripheralDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "Bluetooth" -or $_.Name -match "Bluetooth" -or $_.DeviceID -match "^BTH" })
$cameraPeripheralDevices = @($pnpAll | Where-Object { $_.PNPClass -in @("Camera", "Image", "Imaging") -or $_.Name -match "camera|webcam|imaging" })
$sensorPeripheralDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "Sensor" -or $_.Name -match "sensor|accelerometer|gyroscope|ambient light|lid switch" })
$printerPeripheralDevices = @($pnpAll | Where-Object { $_.PNPClass -in @("Printer", "PrintQueue", "WSDPrintDevice") -or $_.Name -match "printer|print queue|fax" })
$peripheralInventoryDevices = @($hidPeripheralDevices + $bluetoothPeripheralDevices + $cameraPeripheralDevices + $sensorPeripheralDevices + $printerPeripheralDevices | Where-Object { $_ })
$peripheralProblemDevices = @($peripheralInventoryDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 } | Sort-Object DeviceID -Unique)
$audioEndpointDevices = @($pnpAll | Where-Object { $_.PNPClass -eq "AudioEndpoint" })
$audioMediaDevices = @($pnpAll | Where-Object { $_.PNPClass -ne "AudioEndpoint" -and ($_.PNPClass -eq "MEDIA" -or $_.PNPClass -eq "AudioProcessingObject" -or $_.Name -match "audio|speaker|headset|microphone|sound") })
$audioInventoryDevices = @($audioEndpointDevices + $audioMediaDevices | Where-Object { $_ } | Sort-Object DeviceID -Unique)
$audioProblemDevices = @($audioInventoryDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
$signedDrivers = @(Invoke-Probe "signed drivers" { Get-CimInstance Win32_PnPSignedDriver })
$monitors = @(Invoke-Probe "monitors" { Get-CimInstance Win32_DesktopMonitor })
$monitorIds = @(Invoke-OptionalProbe "monitor edid identity" { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID })
$monitorDisplayParams = @(Invoke-OptionalProbe "monitor display params" { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams })
$monitorConnectionParams = @(Invoke-OptionalProbe "monitor connection params" { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams })
$keyboards = @(Invoke-Probe "keyboards" { Get-CimInstance Win32_Keyboard })
$pointingDevices = @(Invoke-Probe "pointing devices" { Get-CimInstance Win32_PointingDevice })
$usbControllers = @(Invoke-Probe "usb controllers" { Get-CimInstance Win32_USBController })
$usbHubs = @(Invoke-Probe "usb hubs" { Get-CimInstance Win32_USBHub })
$usbControllerDeviceAssociations = @(Invoke-OptionalProbe "usb controller device associations" { Get-CimInstance Win32_USBControllerDevice })
$fans = @(Invoke-Probe "fans" { Get-CimInstance Win32_Fan })
$thermalZones = @(Invoke-OptionalProbe "thermal zones" { Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature })
$openHardwareSensors = @(Invoke-OptionalProbe "openhardwaremonitor sensors" { Get-CimInstance -Namespace root\OpenHardwareMonitor -ClassName Sensor })
$libreHardwareSensors = @(Invoke-OptionalProbe "librehardwaremonitor sensors" { Get-CimInstance -Namespace root\LibreHardwareMonitor -ClassName Sensor })
$enclosures = @(Invoke-Probe "enclosure" { Get-CimInstance Win32_SystemEnclosure })
$tpm = @(Invoke-OptionalProbe "tpm" { Get-CimInstance -Namespace root\cimv2\Security\MicrosoftTpm -ClassName Win32_Tpm })

$powerCfgA = Invoke-TextCommand -Name "powercfg available sleep states" -FilePath "powercfg.exe" -Arguments @("/a")
$problemDevicesText = Invoke-TextCommand -Name "pnputil problem devices" -FilePath "pnputil.exe" -Arguments @("/enum-devices", "/problem")
$driverPackageText = Invoke-TextCommand -Name "pnputil driver packages with files" -FilePath "pnputil.exe" -Arguments @("/enum-drivers", "/files")
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

$dirtyVolumeReadOnlyChecks = @()
foreach ($dirtyResult in @($volumeDirtyResults | Where-Object { $_.IsDirty -eq $true } | Select-Object -First 3)) {
  $checkResult = Invoke-BoundedTextProcess -Name "read-only chkdsk $($dirtyResult.DeviceID)" -FilePath "chkdsk.exe" -Arguments @($dirtyResult.DeviceID) -TimeoutMs 45000
  $checkText = ((@($checkResult.Output) + @($checkResult.ErrorOutput)) -join " ")
  $problemLines = @(
    (@($checkResult.Output) + @($checkResult.ErrorOutput)) |
      Where-Object { $_ -match "error|errors|corrupt|corruption|bad sector|bad clusters|invalid|unreadable|failed|failure|problem|cannot continue|insufficient" -and $_ -notmatch "found no problems|No further action is required" } |
      Select-Object -First 30
  )
  $cleanVerdict = [bool]($checkText -match "Windows has scanned the file system and found no problems|No further action is required|Windows found no problems")
  $dirtyVolumeReadOnlyChecks += [pscustomobject]@{
    DeviceID = $dirtyResult.DeviceID
    TimedOut = $checkResult.TimedOut
    ExitCode = $checkResult.ExitCode
    CompletedWithCleanVerdict = $cleanVerdict
    ProblemLineCount = $problemLines.Count
    ProblemLines = @($problemLines)
    OutputHead = @($checkResult.Output | Select-Object -First 30)
    OutputTail = @($checkResult.Output | Select-Object -Last 20)
    ErrorOutput = @($checkResult.ErrorOutput | Select-Object -First 20)
  }
}

$dxdiagText = @()
$dxdiagSkippedReason = $null
$dxdiagPath = Join-Path $env:TEMP ("hardware-truth-dxdiag-" + [guid]::NewGuid().ToString("N") + ".txt")
if ($env:HARDWARE_TRUTH_RUN_DXDIAG -eq "1") {
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
} else {
  $dxdiagSkippedReason = "Skipped live dxdiag by default because it performs graphics-driver probing and this machine has recent LiveKernelReports WATCHDOG dumps. Set HARDWARE_TRUTH_RUN_DXDIAG=1 before launching to opt in."
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
$unexpectedShutdownEvents = @(Invoke-OptionalProbe "unexpected shutdown events" {
  Get-WinEvent -FilterHashtable @{ LogName = "System"; ProviderName = "EventLog"; Id = 6008; StartTime = $startTime } -MaxEvents 30 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, ProviderName, LevelDisplayName, Message
})

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
$dumpRootResults = @()
foreach ($dumpRoot in $dumpRoots) {
  $rootErrors = @()
  $rootFiles = @()
  if (Test-Path -LiteralPath $dumpRoot) {
    $item = Get-Item -LiteralPath $dumpRoot -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer) {
      $crashDumpFiles += $item
      $rootFiles += $item
    } else {
      $accessErrors = @()
      $rootFiles = @(Get-ChildItem -LiteralPath $dumpRoot -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable accessErrors |
        Where-Object { $_.LastWriteTime -ge $startTime -and $_.Extension -match "\.dmp|\.mdmp|\.hdmp" } |
        Select-Object -First 80)
      $crashDumpFiles += $rootFiles
      $rootErrors = @($accessErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique)
    }
    $dumpRootResults += [pscustomobject]@{
      Root = $dumpRoot
      Exists = $true
      RecentDumpCount = @($rootFiles).Count
      AccessErrors = $rootErrors
    }
  } else {
    $dumpRootResults += [pscustomobject]@{
      Root = $dumpRoot
      Exists = $false
      RecentDumpCount = 0
      AccessErrors = @("Path not found or not accessible to this process.")
    }
  }
}

$nvidiaRows = @()
$nvidiaDetails = @()
$nvidiaCommand = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($nvidiaCommand) {
  $query = "name,driver_version,vbios_version,memory.total,memory.used,memory.free,temperature.gpu,fan.speed,pstate,power.draw,power.limit,clocks.current.graphics,clocks.current.memory,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max,display_active,display_mode,utilization.gpu"
  $csv = @(Invoke-Probe "nvidia query" { & $nvidiaCommand.Source "--query-gpu=$query" "--format=csv,noheader,nounits" })
  foreach ($line in $csv) {
    $parts = $line -split "\s*,\s*"
    if ($parts.Count -ge 20) {
      $nvidiaRows += [pscustomobject]@{
        Name = $parts[0]
        DriverVersion = $parts[1]
        VbiosVersion = $parts[2]
        MemoryTotalMiB = $parts[3]
        MemoryUsedMiB = $parts[4]
        MemoryFreeMiB = $parts[5]
        MemoryTotalGB = if ($parts[3] -match "^\d+(\.\d+)?$") { [math]::Round(([double]$parts[3] / 1024), 2) } else { $null }
        MemoryUsedGB = if ($parts[4] -match "^\d+(\.\d+)?$") { [math]::Round(([double]$parts[4] / 1024), 2) } else { $null }
        MemoryFreeGB = if ($parts[5] -match "^\d+(\.\d+)?$") { [math]::Round(([double]$parts[5] / 1024), 2) } else { $null }
        TemperatureC = $parts[6]
        FanPercent = $parts[7]
        PState = $parts[8]
        PowerDrawW = $parts[9]
        PowerLimitW = $parts[10]
        GraphicsClockMhz = $parts[11]
        MemoryClockMhz = $parts[12]
        PcieGen = $parts[13]
        PcieGenMax = $parts[14]
        PcieWidth = $parts[15]
        PcieWidthMax = $parts[16]
        DisplayActive = $parts[17]
        DisplayMode = $parts[18]
        UtilizationPercent = $parts[19]
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

New-Component -Category "Scanner Privilege" -Name "Windows access level" -Status $(if ($isElevated) { "ok" } else { "unknown" }) -Confidence "high" -Evidence @{
  IsAdministrator = $isElevated
  User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
} -Signals $(if ($isElevated) { @() } else { @("Scanner is not running elevated; protected dump, storage, event, and sensor locations may be incomplete.") }) -Recommendations $(if ($isElevated) { @("Scanner has administrator access for protected Windows telemetry paths.") } else { @("Run the launcher as administrator when you need maximum protected Windows dump/storage/event access.") })

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

$processorTotalCounters = @($processorPerfCounters | Where-Object { $_.Name -eq "_Total" -or $_.Name -match "^[0-9]+,_Total$" } | Select-Object -First 3)
$logicalProcessorCounters = @($processorPerfCounters | Where-Object { $_.Name -match "^[0-9]+,[0-9]+$" })
$systemPerfSample = @($systemPerfCounters | Select-Object -First 1)
$totalLogicalProcessors = [int](($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
$highCpuLoadSamples = @($processors | Where-Object { $_.LoadPercentage -ge 90 })
$cpuQueueLength = if ($systemPerfSample.Count -gt 0) { $systemPerfSample[0].ProcessorQueueLength } else { $null }
$cpuTopologySignals = @()
if ($processorPerfCounters.Count -eq 0) { $cpuTopologySignals += "Windows did not expose processor performance counter rows to this scanner." }
if ($highCpuLoadSamples.Count -gt 0) { $cpuTopologySignals += "The CPU was sampled under high current load ($((@($highCpuLoadSamples | ForEach-Object { $_.LoadPercentage }) | Select-Object -First 3) -join ', ')%). This is workload evidence, not a hardware fault by itself." }
if ($cpuQueueLength -ne $null -and $totalLogicalProcessors -gt 0 -and $cpuQueueLength -gt ($totalLogicalProcessors * 2)) { $cpuTopologySignals += "Processor queue length was high during the sample ($cpuQueueLength queued thread(s) for $totalLogicalProcessors logical processor(s))." }
New-Component -Category "CPU Live Topology" -Name "Processor topology, cache, virtualization, and live counters" -Status $(if ($processors.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  ProcessorCount = $processors.Count
  TotalCores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
  TotalEnabledCores = ($processors | Measure-Object -Property NumberOfEnabledCore -Sum).Sum
  TotalLogicalProcessors = $totalLogicalProcessors
  ProcessorRows = @($processors | Select-Object Name, Manufacturer, SocketDesignation, ProcessorId, NumberOfCores, NumberOfEnabledCore, NumberOfLogicalProcessors, ThreadCount, MaxClockSpeed, CurrentClockSpeed, LoadPercentage, L2CacheSize, L3CacheSize, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions, VMMonitorModeExtensions, Revision, Stepping, Status)
  TotalCounterRows = @($processorTotalCounters | Select-Object Name, PercentProcessorPerformance, PercentProcessorUtility, ProcessorFrequency, PercentPrivilegedTime, PercentUserTime, PercentInterruptTime, InterruptsPerSec)
  LogicalProcessorCounterCount = $logicalProcessorCounters.Count
  LogicalProcessorSamples = @($logicalProcessorCounters | Select-Object -First 24 Name, PercentProcessorPerformance, PercentProcessorUtility, ProcessorFrequency, PercentPrivilegedTime, PercentUserTime, PercentInterruptTime, InterruptsPerSec)
  SystemProcessorQueue = @($systemPerfSample | Select-Object ProcessorQueueLength, ContextSwitchesPersec, SystemCallsPersec)
} -Signals $cpuTopologySignals -Recommendations @("Use these CPU identity, cache, clock, virtualization, interrupt, and queue rows to correlate symptoms with CPU load or scheduler pressure. Physical CPU, cooling, motherboard VRM, and PSU stability still require controlled temperature and load testing if symptoms occur.")

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

$memoryArrayRows = @($memoryArrays | ForEach-Object {
  $maxCapacityKb = if ($_.MaxCapacityEx -and $_.MaxCapacityEx -gt 0) { [int64]$_.MaxCapacityEx } else { [int64]$_.MaxCapacity }
  [pscustomobject]@{
    Tag = $_.Tag
    Location = switch ([int]$_.Location) { 3 { "System board or motherboard" } 10 { "PC Card" } 11 { "Proprietary add-on card" } default { $_.Location } }
    Use = switch ([int]$_.Use) { 3 { "System memory" } 4 { "Video memory" } 5 { "Flash memory" } default { $_.Use } }
    SlotCount = $_.MemoryDevices
    MaxCapacityGB = if ($maxCapacityKb -gt 0) { [math]::Round(($maxCapacityKb / 1MB), 2) } else { $null }
    ErrorCorrection = switch ([int]$_.MemoryErrorCorrection) { 3 { "None" } 4 { "Parity" } 5 { "Single-bit ECC" } 6 { "Multi-bit ECC" } 7 { "CRC" } default { $_.MemoryErrorCorrection } }
  }
})
$memorySlotRows = @($memoryModules | ForEach-Object {
  [pscustomobject]@{
    BankLabel = $_.BankLabel
    DeviceLocator = $_.DeviceLocator
    CapacityGB = if ($_.Capacity) { [math]::Round(($_.Capacity / 1GB), 2) } else { $null }
    ConfiguredClockMHz = $_.ConfiguredClockSpeed
    RatedSpeedMHz = $_.Speed
    ConfiguredVoltageMv = $_.ConfiguredVoltage
    Manufacturer = $_.Manufacturer
    PartNumber = ($_.PartNumber -as [string]).Trim()
    SMBIOSMemoryType = switch ([int]$_.SMBIOSMemoryType) { 20 { "DDR" } 24 { "DDR3" } 26 { "DDR4" } 34 { "DDR5" } default { $_.SMBIOSMemoryType } }
    FormFactor = switch ([int]$_.FormFactor) { 8 { "DIMM" } 12 { "SODIMM" } default { $_.FormFactor } }
    SerialNumber = $_.SerialNumber
  }
})
$declaredMemorySlotCount = @($memoryArrayRows | Measure-Object -Property SlotCount -Sum).Sum
$populatedMemorySlotCount = $memoryModules.Count
$emptyMemorySlotCount = if ($declaredMemorySlotCount -ne $null -and $declaredMemorySlotCount -ge $populatedMemorySlotCount) { $declaredMemorySlotCount - $populatedMemorySlotCount } else { $null }
$memoryTopologySignals = @()
if ($memoryArrays.Count -eq 0) { $memoryTopologySignals += "Windows did not expose SMBIOS physical memory-array rows." }
if ($declaredMemorySlotCount -and $emptyMemorySlotCount -gt 0) { $memoryTopologySignals += "$emptyMemorySlotCount declared motherboard memory slot(s) are not populated." }
New-Component -Category "Memory Slot Topology" -Name "DIMM slots and error-correction metadata" -Status $(if ($memoryArrays.Count -eq 0 -and $memoryModules.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  ArrayCount = $memoryArrays.Count
  DeclaredSlotCount = $declaredMemorySlotCount
  PopulatedSlotCount = $populatedMemorySlotCount
  EmptySlotCount = $emptyMemorySlotCount
  TotalInstalledGB = [math]::Round((($memoryModules | Measure-Object -Property Capacity -Sum).Sum / 1GB), 2)
  Arrays = $memoryArrayRows
  PopulatedSlots = $memorySlotRows
} -Signals $memoryTopologySignals -Recommendations @("Use this topology to match physical DIMMs and slots before reseating, upgrading, or isolating RAM faults. Cell-level RAM certainty still requires Windows Memory Diagnostic, MemTest86, or another boot-time memory test.")

$memoryPerfSample = @($memoryPerfCounters | Select-Object -First 1)
$memoryPerf = if ($memoryPerfSample.Count -gt 0) { $memoryPerfSample[0] } else { $null }
$commitPercent = if ($memoryPerf -and $null -ne $memoryPerf.PercentCommittedBytesInUse) { [double]$memoryPerf.PercentCommittedBytesInUse } else { $null }
$availableMemoryMb = if ($memoryPerf -and $null -ne $memoryPerf.AvailableMBytes) { [double]$memoryPerf.AvailableMBytes } else { $null }
$pagesOutputPerSec = if ($memoryPerf -and $null -ne $memoryPerf.PagesOutputPersec) { [double]$memoryPerf.PagesOutputPersec } else { $null }
$pageReadsPerSec = if ($memoryPerf -and $null -ne $memoryPerf.PageReadsPersec) { [double]$memoryPerf.PageReadsPersec } else { $null }
$pagesInputPerSec = if ($memoryPerf -and $null -ne $memoryPerf.PagesInputPersec) { [double]$memoryPerf.PagesInputPersec } else { $null }
$memoryCommittedGb = if ($memoryPerf -and $null -ne $memoryPerf.CommittedBytes) { [math]::Round(([double]$memoryPerf.CommittedBytes / 1GB), 2) } else { $null }
$memoryCommitLimitGb = if ($memoryPerf -and $null -ne $memoryPerf.CommitLimit) { [math]::Round(([double]$memoryPerf.CommitLimit / 1GB), 2) } else { $null }
$pageFileRows = @($pageFileUsage | ForEach-Object {
  $allocated = if ($null -ne $_.AllocatedBaseSize) { [double]$_.AllocatedBaseSize } else { 0 }
  $current = if ($null -ne $_.CurrentUsage) { [double]$_.CurrentUsage } else { 0 }
  $peak = if ($null -ne $_.PeakUsage) { [double]$_.PeakUsage } else { 0 }
  [pscustomobject]@{
    Name = $_.Name
    AllocatedMB = $_.AllocatedBaseSize
    CurrentUsageMB = $_.CurrentUsage
    PeakUsageMB = $_.PeakUsage
    CurrentUsagePercent = if ($allocated -gt 0) { [math]::Round(($current / $allocated) * 100, 1) } else { $null }
    PeakUsagePercent = if ($allocated -gt 0) { [math]::Round(($peak / $allocated) * 100, 1) } else { $null }
    TempPageFile = $_.TempPageFile
    Status = $_.Status
  }
})
$pageFilePressureRows = @($pageFileRows | Where-Object {
  ($null -ne $_.CurrentUsagePercent -and $_.CurrentUsagePercent -ge 90) -or
  ($null -ne $_.PeakUsagePercent -and $_.PeakUsagePercent -ge 90) -or
  $_.TempPageFile -eq $true
})
$memoryPressureSignals = @()
if ($memoryPerfSample.Count -eq 0) { $memoryPressureSignals += "Windows did not expose live memory performance counters to this scanner." }
if ($commitPercent -ne $null -and $commitPercent -ge 90) { $memoryPressureSignals += "Committed memory is high at $commitPercent% of the commit limit." }
if ($availableMemoryMb -ne $null -and $availableMemoryMb -lt 1024) { $memoryPressureSignals += "Available memory is low at $availableMemoryMb MB." }
if ($pagesOutputPerSec -ne $null -and $pagesOutputPerSec -gt 50) { $memoryPressureSignals += "Windows is paging memory out to disk at $pagesOutputPerSec pages/sec." }
if ($pageFileUsage.Count -eq 0) { $memoryPressureSignals += "Windows did not expose pagefile usage rows to this scanner." }
if ($pageFilePressureRows.Count -gt 0) { $memoryPressureSignals += "$($pageFilePressureRows.Count) pagefile row(s) show high current/peak usage or a temporary pagefile." }
$hasMemoryPressureWarning = (
  ($commitPercent -ne $null -and $commitPercent -ge 90) -or
  ($availableMemoryMb -ne $null -and $availableMemoryMb -lt 1024) -or
  ($pagesOutputPerSec -ne $null -and $pagesOutputPerSec -gt 50) -or
  $pageFilePressureRows.Count -gt 0
)
$memoryPressureStatus = if ($memoryPerfSample.Count -eq 0 -and $pageFileUsage.Count -eq 0) { "unknown" } elseif ($hasMemoryPressureWarning) { "warning" } else { "ok" }
New-Component -Category "Memory Live Pressure" -Name "RAM pressure, paging, and pagefile evidence" -Status $memoryPressureStatus -Confidence "medium" -Evidence @{
  CounterRows = $memoryPerfCounters.Count
  AvailableMemoryMB = $availableMemoryMb
  CommitPercent = $commitPercent
  CommittedGB = $memoryCommittedGb
  CommitLimitGB = $memoryCommitLimitGb
  PagesInputPerSec = $pagesInputPerSec
  PagesOutputPerSec = $pagesOutputPerSec
  PageReadsPerSec = $pageReadsPerSec
  PageWritesPerSec = if ($memoryPerf -and $null -ne $memoryPerf.PageWritesPersec) { [double]$memoryPerf.PageWritesPersec } else { $null }
  PageFaultsPerSec = if ($memoryPerf -and $null -ne $memoryPerf.PageFaultsPersec) { [double]$memoryPerf.PageFaultsPersec } else { $null }
  PoolNonpagedGB = if ($memoryPerf -and $null -ne $memoryPerf.PoolNonpagedBytes) { [math]::Round(([double]$memoryPerf.PoolNonpagedBytes / 1GB), 2) } else { $null }
  PoolPagedGB = if ($memoryPerf -and $null -ne $memoryPerf.PoolPagedBytes) { [math]::Round(([double]$memoryPerf.PoolPagedBytes / 1GB), 2) } else { $null }
  PageFileCount = $pageFileUsage.Count
  PageFiles = $pageFileRows
} -Signals $memoryPressureSignals -Recommendations $(if ($memoryPressureStatus -eq "warning") { @("Reduce memory pressure, check pagefile configuration/free system-drive space, and retest. If memory errors or crashes exist, still run an offline RAM diagnostic before replacing DIMMs.") } elseif ($memoryPressureStatus -eq "unknown") { @("Use Resource Monitor/Performance Monitor and an offline RAM diagnostic if memory symptoms exist because live memory counters were unavailable.") } else { @("No live commit/pagefile pressure signal was visible at scan time. This improves RAM subsystem evidence but does not prove physical RAM cells healthy without a boot-level memory diagnostic.") })

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

New-Component -Category "Storage Controller Inventory" -Name "Storage controller and adapter PnP devices" -Status $(if ($storageControllerProblemDevices.Count -gt 0) { "warning" } elseif ($storageControllerDevices.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  ControllerDeviceCount = $storageControllerDevices.Count
  ProblemDeviceCount = $storageControllerProblemDevices.Count
  ProblemDevices = @($storageControllerProblemDevices | Select-Object -First 20 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  Devices = @($storageControllerDevices | Select-Object -First 40 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
} -Signals $(if ($storageControllerProblemDevices.Count -gt 0) { @("$($storageControllerProblemDevices.Count) storage controller/adapter device(s) have Device Manager problem codes.") } elseif ($storageControllerDevices.Count -eq 0) { @("Windows did not expose storage controller or adapter PnP device rows to this scanner.") } else { @() }) -Recommendations $(if ($storageControllerProblemDevices.Count -gt 0) { @("Fix listed controller/adapter Device Manager problem codes before replacing drives, cables, slots, docks, or the motherboard.") } elseif ($storageControllerDevices.Count -eq 0) { @("Use Device Manager, BIOS/UEFI, or vendor controller tooling if storage symptoms exist because controller PnP rows were unavailable.") } else { @("Storage controllers/adapters are enumerated without Device Manager problem codes. Intermittent cable, slot, dock, controller, or power-path faults still require symptom-time testing.") })

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
$diskByDeviceId = @{}
foreach ($disk in $diskDrives) {
  if ($disk.DeviceID) { $diskByDeviceId[[string]$disk.DeviceID] = $disk }
}
$partitionByDeviceId = @{}
foreach ($partition in $diskPartitions) {
  if ($partition.DeviceID) { $partitionByDeviceId[[string]$partition.DeviceID] = $partition }
}
$volumeByDeviceId = @{}
foreach ($volume in $volumes) {
  if ($volume.DeviceID) { $volumeByDeviceId[[string]$volume.DeviceID] = $volume }
}
$dirtyByDeviceId = @{}
foreach ($dirtyResult in $volumeDirtyResults) {
  if ($dirtyResult.DeviceID) { $dirtyByDeviceId[[string]$dirtyResult.DeviceID] = $dirtyResult }
}
$logicalDiskByPartition = @{}
foreach ($association in $logicalDiskToPartition) {
  $partitionDeviceId = [string]$association.Antecedent.DeviceID
  $logicalDiskId = [string]$association.Dependent.DeviceID
  if ($partitionDeviceId -and $logicalDiskId) {
    $logicalDiskByPartition[$partitionDeviceId] = $logicalDiskId
  }
}

$storageMapRows = @()
foreach ($association in $diskDriveToPartition) {
  $diskDeviceId = [string]$association.Antecedent.DeviceID
  $partitionDeviceId = [string]$association.Dependent.DeviceID
  if (-not $diskDeviceId -or -not $partitionDeviceId) { continue }

  $disk = if ($diskByDeviceId.ContainsKey($diskDeviceId)) { $diskByDeviceId[$diskDeviceId] } else { $association.Antecedent }
  $partition = if ($partitionByDeviceId.ContainsKey($partitionDeviceId)) { $partitionByDeviceId[$partitionDeviceId] } else { $association.Dependent }
  $logicalDiskId = if ($logicalDiskByPartition.ContainsKey($partitionDeviceId)) { $logicalDiskByPartition[$partitionDeviceId] } else { $null }
  $volume = if ($logicalDiskId -and $volumeByDeviceId.ContainsKey($logicalDiskId)) { $volumeByDeviceId[$logicalDiskId] } else { $null }
  $dirtyResult = if ($logicalDiskId -and $dirtyByDeviceId.ContainsKey($logicalDiskId)) { $dirtyByDeviceId[$logicalDiskId] } else { $null }

  $storageMapRows += [pscustomobject]@{
    DiskIndex = $disk.Index
    PhysicalDrive = $diskDeviceId
    DiskModel = $disk.Model
    InterfaceType = $disk.InterfaceType
    DiskSizeGB = if ($disk.Size) { [math]::Round(($disk.Size / 1GB), 2) } else { $null }
    DiskSerialNumber = (($disk.SerialNumber -as [string]).Trim())
    Partition = $partitionDeviceId
    PartitionType = $partition.Type
    PartitionSizeGB = if ($partition.Size) { [math]::Round(($partition.Size / 1GB), 2) } else { $null }
    LogicalDisk = $logicalDiskId
    VolumeName = if ($volume) { $volume.VolumeName } else { $null }
    FileSystem = if ($volume) { $volume.FileSystem } else { $null }
    VolumeSizeGB = if ($volume -and $volume.Size) { [math]::Round(($volume.Size / 1GB), 2) } else { $null }
    VolumeFreeGB = if ($volume -and $volume.FreeSpace) { [math]::Round(($volume.FreeSpace / 1GB), 2) } else { $null }
    DirtyBit = if ($dirtyResult) { [bool]$dirtyResult.IsDirty } else { $null }
  }
}

$mappedLogicalDisks = @($storageMapRows | Where-Object { $_.LogicalDisk } | ForEach-Object { $_.LogicalDisk } | Select-Object -Unique)
$unmappedLogicalDisks = @($volumes | Where-Object { $_.DeviceID -match "^[A-Z]:$" -and $mappedLogicalDisks -notcontains $_.DeviceID } | Select-Object DeviceID, VolumeName, FileSystem, @{ Name = "SizeGB"; Expression = { if ($_.Size) { [math]::Round(($_.Size / 1GB), 2) } else { $null } } })
$dirtyStorageMapRows = @($storageMapRows | Where-Object { $_.DirtyBit -eq $true })
$dirtyStorageTargets = @($dirtyStorageMapRows | ForEach-Object { "$($_.LogicalDisk) on Disk $($_.DiskIndex) $($_.DiskModel) ($($_.PhysicalDrive))" })

New-Component -Category "Storage Mapping" -Name "Physical disk to volume map" -Status $(if ($dirtyStorageMapRows.Count -gt 0) { "warning" } elseif ($storageMapRows.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  MappingCount = $storageMapRows.Count
  MappedLogicalDiskCount = $mappedLogicalDisks.Count
  UnmappedLogicalDisks = @($unmappedLogicalDisks)
  DirtyMappedVolumeCount = $dirtyStorageMapRows.Count
  DirtyMappedVolumes = @($dirtyStorageMapRows | Select-Object -First 20 LogicalDisk, DiskIndex, PhysicalDrive, DiskModel, InterfaceType, Partition, FileSystem, VolumeName)
  Mappings = @($storageMapRows | Select-Object -First 50)
} -Signals $(if ($dirtyStorageMapRows.Count -gt 0) { @("$($dirtyStorageMapRows.Count) dirty volume(s) are mapped to exact physical disk rows.") } elseif ($storageMapRows.Count -eq 0) { @("Windows did not expose disk-to-partition-to-volume mappings to this scanner.") } else { @() }) -Recommendations $(if ($dirtyStorageMapRows.Count -gt 0) { @("Back up and run read-only filesystem diagnostics for: $((@($dirtyStorageTargets) | Select-Object -First 8) -join '; '). Do not repair until the mapped physical disk is confirmed stable.") } elseif ($storageMapRows.Count -eq 0) { @("Use Disk Management or PowerShell storage cmdlets to manually map volumes to physical disks before replacing hardware.") } else { @("Disk-to-volume mapping is captured, so future volume warnings can be tied to the exact physical drive.") })

$logicalDiskPerfRows = @($logicalDiskPerfCounters | Where-Object { $_.Name -ne "_Total" } | ForEach-Object {
  $counterName = $_.Name
  $mappedRows = @($storageMapRows | Where-Object { $_.LogicalDisk -eq $counterName })
  [pscustomobject]@{
    LogicalDisk = $counterName
    DiskIndex = if ($mappedRows.Count -gt 0) { $mappedRows[0].DiskIndex } else { $null }
    DiskModel = if ($mappedRows.Count -gt 0) { $mappedRows[0].DiskModel } else { $null }
    PhysicalDrive = if ($mappedRows.Count -gt 0) { $mappedRows[0].PhysicalDrive } else { $null }
    CurrentQueueLength = $_.CurrentDiskQueueLength
    AvgQueueLength = $_.AvgDiskQueueLength
    ReadsPerSec = $_.DiskReadsPersec
    WritesPerSec = $_.DiskWritesPersec
    ReadMBPerSec = [math]::Round(([double]$_.DiskReadBytesPersec / 1MB), 2)
    WriteMBPerSec = [math]::Round(([double]$_.DiskWriteBytesPersec / 1MB), 2)
    PercentDiskTime = $_.PercentDiskTime
    PercentFreeSpace = $_.PercentFreeSpace
    FreeGB = [math]::Round(([double]$_.FreeMegabytes / 1024), 2)
    SplitIOPerSec = $_.SplitIOPerSec
  }
})
$physicalDiskPerfRows = @($physicalDiskPerfCounters | Where-Object { $_.Name -ne "_Total" } | ForEach-Object {
  $diskIndex = if ($_.Name -match "^(\d+)") { [int]$Matches[1] } else { $null }
  $mappedRows = @($storageMapRows | Where-Object { $null -ne $diskIndex -and $_.DiskIndex -eq $diskIndex })
  [pscustomobject]@{
    CounterName = $_.Name
    DiskIndex = $diskIndex
    DiskModel = if ($mappedRows.Count -gt 0) { $mappedRows[0].DiskModel } else { $null }
    PhysicalDrive = if ($mappedRows.Count -gt 0) { $mappedRows[0].PhysicalDrive } else { $null }
    LogicalDisks = @($mappedRows | Where-Object { $_.LogicalDisk } | ForEach-Object { $_.LogicalDisk } | Select-Object -Unique)
    CurrentQueueLength = $_.CurrentDiskQueueLength
    AvgQueueLength = $_.AvgDiskQueueLength
    ReadsPerSec = $_.DiskReadsPersec
    WritesPerSec = $_.DiskWritesPersec
    ReadMBPerSec = [math]::Round(([double]$_.DiskReadBytesPersec / 1MB), 2)
    WriteMBPerSec = [math]::Round(([double]$_.DiskWriteBytesPersec / 1MB), 2)
    PercentDiskTime = $_.PercentDiskTime
    PercentIdleTime = $_.PercentIdleTime
    SplitIOPerSec = $_.SplitIOPerSec
  }
})
$busyLogicalDiskRows = @($logicalDiskPerfRows | Where-Object { $_.CurrentQueueLength -gt 4 -or $_.AvgQueueLength -gt 4 -or $_.PercentDiskTime -gt 90 })
$busyPhysicalDiskRows = @($physicalDiskPerfRows | Where-Object { $_.CurrentQueueLength -gt 4 -or $_.AvgQueueLength -gt 4 -or $_.PercentDiskTime -gt 90 })
$storagePerfSignals = @()
if ($physicalDiskPerfRows.Count -eq 0 -and $logicalDiskPerfRows.Count -eq 0) { $storagePerfSignals += "Windows did not expose live disk performance-counter rows to this scanner." }
if ($busyLogicalDiskRows.Count -gt 0 -or $busyPhysicalDiskRows.Count -gt 0) { $storagePerfSignals += "$($busyPhysicalDiskRows.Count) physical disk row(s) and $($busyLogicalDiskRows.Count) logical disk row(s) showed high live queue or disk-time pressure during the sample." }
New-Component -Category "Storage Performance Counters" -Name "Live disk queue, throughput, and free-space pressure" -Status $(if ($busyLogicalDiskRows.Count -gt 0 -or $busyPhysicalDiskRows.Count -gt 0) { "warning" } elseif ($physicalDiskPerfRows.Count -eq 0 -and $logicalDiskPerfRows.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  PhysicalCounterCount = $physicalDiskPerfRows.Count
  LogicalCounterCount = $logicalDiskPerfRows.Count
  BusyPhysicalDiskCount = $busyPhysicalDiskRows.Count
  BusyLogicalDiskCount = $busyLogicalDiskRows.Count
  BusyPhysicalDisks = @($busyPhysicalDiskRows | Select-Object -First 20)
  BusyLogicalDisks = @($busyLogicalDiskRows | Select-Object -First 20)
  PhysicalDisks = @($physicalDiskPerfRows | Select-Object -First 40)
  LogicalDisks = @($logicalDiskPerfRows | Select-Object -First 40)
} -Signals $storagePerfSignals -Recommendations $(if ($busyLogicalDiskRows.Count -gt 0 -or $busyPhysicalDiskRows.Count -gt 0) { @("Correlate busy disk rows with the mapped physical drive before repairing or replacing hardware. High queue/disk-time can be a normal active workload, filesystem pressure, cable/controller issue, or failing storage depending on symptoms and repeatability.") } elseif ($physicalDiskPerfRows.Count -eq 0 -and $logicalDiskPerfRows.Count -eq 0) { @("Use Resource Monitor, Performance Monitor, or vendor tools if storage symptoms exist because live disk counters were unavailable.") } else { @("No live disk queue or disk-time pressure was visible in this sample. Retest while storage symptoms are happening.") })

New-Component -Category "Volume Dirty Bit" -Name "Read-only filesystem repair flag check" -Status $(if ($dirtyVolumes.Count -gt 0) { "warning" } elseif ($volumeDirtyResults.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  CheckedVolumeCount = $volumeDirtyResults.Count
  DirtyVolumeCount = $dirtyVolumes.Count
  UnsupportedOrFailedCount = $unsupportedDirtyChecks.Count
  Results = @($volumeDirtyResults | Select-Object -First 20 DeviceID, IsDirty, IsUnsupported, Output)
} -Signals $(if ($dirtyVolumes.Count -gt 0) { @("$($dirtyVolumes.Count) volume(s) have the filesystem dirty bit set.") } elseif ($volumeDirtyResults.Count -eq 0) { @("No drive-letter volumes were eligible for fsutil dirty query.") } else { @() }) -Recommendations $(if ($dirtyVolumes.Count -gt 0) { @("Back up affected volumes, then run read-only checks before any repair; a dirty bit can indicate an interrupted write, filesystem issue, or storage instability.") } else { @("No filesystem dirty bit was reported by fsutil for checked volumes.") })

$dirtyVolumeReadOnlyProblemChecks = @($dirtyVolumeReadOnlyChecks | Where-Object { $_.ProblemLineCount -gt 0 })
$dirtyVolumeReadOnlyIncompleteChecks = @($dirtyVolumeReadOnlyChecks | Where-Object { $_.TimedOut -eq $true -or ($_.CompletedWithCleanVerdict -ne $true -and $_.ProblemLineCount -eq 0) })
New-Component -Category "Filesystem Read-Only Check" -Name "Dirty-volume chkdsk evidence" -Status $(if ($dirtyVolumeReadOnlyProblemChecks.Count -gt 0) { "warning" } elseif ($dirtyVolumeReadOnlyIncompleteChecks.Count -gt 0) { "unknown" } elseif ($dirtyVolumeReadOnlyChecks.Count -eq 0 -and $dirtyVolumes.Count -gt 0) { "unknown" } elseif ($dirtyVolumeReadOnlyChecks.Count -eq 0) { "ok" } else { "ok" }) -Confidence "medium" -Evidence @{
  DirtyVolumeCount = $dirtyVolumes.Count
  CheckedDirtyVolumeCount = $dirtyVolumeReadOnlyChecks.Count
  ProblemCheckCount = $dirtyVolumeReadOnlyProblemChecks.Count
  IncompleteCheckCount = $dirtyVolumeReadOnlyIncompleteChecks.Count
  Checks = @($dirtyVolumeReadOnlyChecks | Select-Object -First 10)
} -Signals $(if ($dirtyVolumeReadOnlyProblemChecks.Count -gt 0) { @("$($dirtyVolumeReadOnlyProblemChecks.Count) dirty-volume read-only chkdsk check(s) produced problem text.") } elseif ($dirtyVolumeReadOnlyIncompleteChecks.Count -gt 0) { @("$($dirtyVolumeReadOnlyIncompleteChecks.Count) dirty-volume read-only chkdsk check(s) did not reach a clean final verdict inside the bounded scan window.") } elseif ($dirtyVolumeReadOnlyChecks.Count -eq 0 -and $dirtyVolumes.Count -gt 0) { @("Dirty volume(s) exist, but no read-only chkdsk check was captured.") } else { @() }) -Recommendations $(if ($dirtyVolumeReadOnlyProblemChecks.Count -gt 0) { @("Back up the affected volume, preserve this output, and run a planned filesystem/vendor-storage diagnostic before any repair.") } elseif ($dirtyVolumeReadOnlyIncompleteChecks.Count -gt 0) { @("The read-only check did not finish cleanly inside the bounded scan. Back up first, then rerun chkdsk manually during a quiet window before repairing or replacing hardware.") } elseif ($dirtyVolumes.Count -gt 0) { @("Read-only chkdsk did not report problem text for dirty volume(s), but the dirty bit still requires backup and planned follow-up.") } else { @("No dirty volumes required a read-only chkdsk follow-up in this scan.") })

$storageRiskRows = @()
foreach ($disk in $diskDrives) {
  $diskIndex = $disk.Index
  $diskMappings = @($storageMapRows | Where-Object { $null -ne $diskIndex -and $_.DiskIndex -eq $diskIndex })
  $diskDirtyRows = @($diskMappings | Where-Object { $_.DirtyBit -eq $true })
  $diskReadOnlyChecks = @($dirtyVolumeReadOnlyChecks | Where-Object { $diskMappings.LogicalDisk -contains $_.DeviceID })
  $diskPhysicalPressure = @($busyPhysicalDiskRows | Where-Object { $null -ne $diskIndex -and $_.DiskIndex -eq $diskIndex })
  $diskLogicalPressure = @($busyLogicalDiskRows | Where-Object { $null -ne $diskIndex -and $_.DiskIndex -eq $diskIndex })
  $diskSignals = @()
  if ($disk.Status -and $disk.Status -ne "OK") { $diskSignals += "Win32_DiskDrive status is $($disk.Status)." }
  if ($disk.ConfigManagerErrorCode -and $disk.ConfigManagerErrorCode -ne 0) { $diskSignals += "Device Manager problem code $($disk.ConfigManagerErrorCode) is attached to this disk." }
  if ($diskDirtyRows.Count -gt 0) { $diskSignals += "Dirty filesystem flag on $((@($diskDirtyRows | ForEach-Object { $_.LogicalDisk }) | Select-Object -Unique) -join ', ')." }
  if (($diskReadOnlyChecks | Where-Object { $_.ProblemLineCount -gt 0 }).Count -gt 0) { $diskSignals += "Read-only chkdsk output contains problem text for a mapped dirty volume." }
  if (($diskReadOnlyChecks | Where-Object { $_.TimedOut -eq $true -or ($_.CompletedWithCleanVerdict -ne $true -and $_.ProblemLineCount -eq 0) }).Count -gt 0) { $diskSignals += "Read-only chkdsk did not reach a clean final verdict inside the bounded scan window." }
  if ($diskPhysicalPressure.Count -gt 0 -or $diskLogicalPressure.Count -gt 0) { $diskSignals += "High live queue/disk-time pressure appeared on this physical disk or its logical volume during the scan." }

  $storageRiskRows += [pscustomobject]@{
    DiskIndex = $diskIndex
    PhysicalDrive = $disk.DeviceID
    DiskModel = $disk.Model
    SerialNumber = (($disk.SerialNumber -as [string]).Trim())
    FirmwareRevision = $disk.FirmwareRevision
    InterfaceType = $disk.InterfaceType
    MediaType = $disk.MediaType
    SizeGB = if ($disk.Size) { [math]::Round(($disk.Size / 1GB), 2) } else { $null }
    GenericDiskStatus = $disk.Status
    ConfigManagerErrorCode = $disk.ConfigManagerErrorCode
    LogicalDisks = @($diskMappings | Where-Object { $_.LogicalDisk } | ForEach-Object { $_.LogicalDisk } | Select-Object -Unique)
    FileSystems = @($diskMappings | Where-Object { $_.FileSystem } | ForEach-Object { "$($_.LogicalDisk)=$($_.FileSystem)" } | Select-Object -Unique)
    DirtyVolumes = @($diskDirtyRows | ForEach-Object { "$($_.LogicalDisk) $($_.FileSystem) $($_.VolumeName) on $($_.Partition)" })
    ReadOnlyCheckResults = @($diskReadOnlyChecks | ForEach-Object { "$($_.DeviceID): timedOut=$($_.TimedOut), exit=$($_.ExitCode), cleanVerdict=$($_.CompletedWithCleanVerdict), problemLines=$($_.ProblemLineCount)" })
    BusyPhysicalCounters = @($diskPhysicalPressure | ForEach-Object { "$($_.CounterName): queue=$($_.CurrentQueueLength), avgQueue=$($_.AvgQueueLength), diskTime=$($_.PercentDiskTime)%, read=$($_.ReadMBPerSec) MB/s, write=$($_.WriteMBPerSec) MB/s, splitIO=$($_.SplitIOPerSec)" })
    BusyLogicalCounters = @($diskLogicalPressure | ForEach-Object { "volume=$($_.LogicalDisk), queue=$($_.CurrentQueueLength), avgQueue=$($_.AvgQueueLength), diskTime=$($_.PercentDiskTime)%, read=$($_.ReadMBPerSec) MB/s, write=$($_.WriteMBPerSec) MB/s, free=$($_.FreeGB) GB ($($_.PercentFreeSpace)%)" })
    SignalCount = $diskSignals.Count
    Signals = $diskSignals
  }
}

$storageRiskProblemRows = @($storageRiskRows | Where-Object { $_.SignalCount -gt 0 })
$storageRiskRecommendations = @()
if ($storageRiskProblemRows.Count -gt 0) {
  foreach ($row in @($storageRiskProblemRows | Select-Object -First 4)) {
    $targets = @($row.LogicalDisks) -join ", "
    if ([string]::IsNullOrWhiteSpace($targets)) { $targets = $row.PhysicalDrive }
    $storageRiskRecommendations += "Disk $($row.DiskIndex) $($row.DiskModel) ($targets): back up affected data first, avoid repair while heavy writes are active, rerun read-only filesystem and vendor SMART diagnostics, then inspect cable/port/dock/power path only if the warning repeats."
  }
} else {
  $storageRiskRecommendations += "No disk has a combined generic-status, dirty-bit, or live-pressure signal in this scan. Vendor SMART and symptom-time testing are still required for full physical certainty."
}
New-Component -Category "Storage Fix Summary" -Name "Per-physical-drive risk summary" -Status $(if ($storageRiskProblemRows.Count -gt 0) { "warning" } elseif ($storageRiskRows.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  DiskCount = $storageRiskRows.Count
  ProblemDiskCount = $storageRiskProblemRows.Count
  ProblemDisks = @($storageRiskProblemRows | Select-Object -First 20)
  AllDisks = @($storageRiskRows | Select-Object -First 20)
} -Signals $(if ($storageRiskProblemRows.Count -gt 0) { @("$($storageRiskProblemRows.Count) physical disk(s) have combined storage risk signals from disk status, dirty-bit mapping, or live pressure counters.") } elseif ($storageRiskRows.Count -eq 0) { @("Windows did not expose physical disk rows for the storage risk summary.") } else { @() }) -Recommendations $storageRiskRecommendations

if ($dirtyVolumes.Count -gt 0) {
  $dirtyEvidence = if ($dirtyStorageTargets.Count -gt 0) { "$($dirtyVolumes.Count) dirty volume(s): $((@($dirtyStorageTargets) | Select-Object -First 8) -join '; ')" } else { "$($dirtyVolumes.Count) dirty volume(s): $((@($dirtyVolumes | ForEach-Object { $_.DeviceID }) -join ', '))" }
  New-Finding -Severity "warning" -Component "Volume dirty bit" -Title "Filesystem dirty bit is set" -Detail "Windows reports at least one volume may need filesystem checking." -Evidence $dirtyEvidence -Recommendation "Back up first, then use read-only diagnostics or a planned repair window for the affected mapped volume and physical disk." -Confidence "medium"
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

$gpuDisplayRows = @()
foreach ($gpu in $videoControllers) {
  $nvidia = @($nvidiaRows | Where-Object { $gpu.Name -like "*$($_.Name)*" -or $_.Name -like "*$($gpu.Name)*" } | Select-Object -First 1)
  $gpuDisplayRows += [pscustomobject]@{
    Name = $gpu.Name
    Status = $gpu.Status
    PNPDeviceID = $gpu.PNPDeviceID
    AdapterCompatibility = $gpu.AdapterCompatibility
    VideoProcessor = $gpu.VideoProcessor
    DriverVersion = $gpu.DriverVersion
    DriverDate = $gpu.DriverDate
    InfFilename = $gpu.InfFilename
    CurrentResolution = if ($gpu.CurrentHorizontalResolution -and $gpu.CurrentVerticalResolution) { "$($gpu.CurrentHorizontalResolution)x$($gpu.CurrentVerticalResolution)" } else { $null }
    CurrentRefreshRateHz = $gpu.CurrentRefreshRate
    CurrentBitsPerPixel = $gpu.CurrentBitsPerPixel
    VideoModeDescription = $gpu.VideoModeDescription
    WmiAdapterRamGB = if ($gpu.AdapterRAM) { [math]::Round(($gpu.AdapterRAM / 1GB), 2) } else { $null }
    NvidiaMemoryTotalGB = if ($nvidia.Count -gt 0) { $nvidia[0].MemoryTotalGB } else { $null }
    NvidiaMemoryUsedGB = if ($nvidia.Count -gt 0) { $nvidia[0].MemoryUsedGB } else { $null }
    NvidiaMemoryFreeGB = if ($nvidia.Count -gt 0) { $nvidia[0].MemoryFreeGB } else { $null }
    NvidiaDisplayActive = if ($nvidia.Count -gt 0) { $nvidia[0].DisplayActive } else { $null }
    NvidiaPcieLink = if ($nvidia.Count -gt 0) { "Gen $($nvidia[0].PcieGen)/$($nvidia[0].PcieGenMax), x$($nvidia[0].PcieWidth)/x$($nvidia[0].PcieWidthMax)" } else { $null }
  }
}
$gpuDisplayProblemRows = @($gpuDisplayRows | Where-Object { $_.Status -and $_.Status -ne "OK" })
New-Component -Category "GPU Display Pipeline" -Name "Video modes, VRAM, driver, and link evidence" -Status $(if ($gpuDisplayProblemRows.Count -gt 0) { "warning" } elseif ($gpuDisplayRows.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  VideoControllerCount = $videoControllers.Count
  NvidiaTelemetryCount = $nvidiaRows.Count
  ProblemControllerCount = $gpuDisplayProblemRows.Count
  Rows = @($gpuDisplayRows)
} -Signals $(if ($gpuDisplayProblemRows.Count -gt 0) { @("$($gpuDisplayProblemRows.Count) video controller display pipeline row(s) have non-OK Windows status.") } elseif ($gpuDisplayRows.Count -eq 0) { @("Windows did not expose video-controller display pipeline rows to this scanner.") } else { @() }) -Recommendations $(if ($gpuDisplayProblemRows.Count -gt 0) { @("Fix the listed display adapter status before replacing GPU, cable, monitor, or slot hardware.") } elseif ($gpuDisplayRows.Count -eq 0) { @("Use Device Manager, GPU vendor tools, and monitor OSD diagnostics if display symptoms exist because video-controller rows were unavailable.") } else { @("Display modes, driver rows, and NVIDIA VRAM/link telemetry were captured without Windows video-controller status faults. Flicker, HDR/VRR, cable quality, dead pixels, and load-only GPU faults still require symptom-time visual/load testing.") })

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
  New-Component -Category "DirectX Diagnostic" -Name "dxdiag display/audio/input" -Status "unknown" -Confidence "low" -Evidence @{
    OutputLines = 0
    SkippedReason = $dxdiagSkippedReason
  } -Signals @("Live dxdiag did not run in the default safe scan path.") -Recommendations @("If graphics/audio/input symptoms persist and you accept the driver-probing risk, set HARDWARE_TRUTH_RUN_DXDIAG=1 before launching or run dxdiag manually.")
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

$networkCounterRows = @()
$networkCountersByKey = @{}
foreach ($counter in $networkInterfaceCounters) {
  $counterKey = ((($counter.Name -replace "_\d+$", "") -replace "\[[^\]]+\]|\([^\)]*\)", "") -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
  if ($counterKey -and -not $networkCountersByKey.ContainsKey($counterKey)) {
    $networkCountersByKey[$counterKey] = $counter
  }
}
foreach ($adapter in $networkAdapters) {
  $adapterKey = ((($adapter.Name -replace "_\d+$", "") -replace "\[[^\]]+\]|\([^\)]*\)", "") -replace "[^a-zA-Z0-9]", "").ToLowerInvariant()
  $counter = @()
  if ($adapterKey -and $networkCountersByKey.ContainsKey($adapterKey)) {
    $counter = @($networkCountersByKey[$adapterKey])
  }
  $rxErrors = if ($counter.Count -gt 0) { [int64]$counter[0].PacketsReceivedErrors } else { $null }
  $txErrors = if ($counter.Count -gt 0) { [int64]$counter[0].PacketsOutboundErrors } else { $null }
  $rxDiscards = if ($counter.Count -gt 0) { [int64]$counter[0].PacketsReceivedDiscarded } else { $null }
  $txDiscards = if ($counter.Count -gt 0) { [int64]$counter[0].PacketsOutboundDiscarded } else { $null }
  $counterValues = @($rxErrors, $txErrors, $rxDiscards, $txDiscards) | Where-Object { $null -ne $_ }
  $totalErrors = if ($counterValues.Count -gt 0) { ($counterValues | Measure-Object -Sum).Sum } else { $null }
  $speedMbps = if ($adapter.Speed -and [double]$adapter.Speed -lt 1000000000000) { [math]::Round(([double]$adapter.Speed / 1000000), 1) } else { $null }

  $networkCounterRows += [pscustomobject]@{
    AdapterName = $adapter.Name
    NetEnabled = $adapter.NetEnabled
    NetConnectionStatus = $adapter.NetConnectionStatus
    SpeedMbps = $speedMbps
    CounterName = if ($counter.Count -gt 0) { $counter[0].Name } else { $null }
    CurrentBandwidthMbps = if ($counter.Count -gt 0 -and $counter[0].CurrentBandwidth) { [math]::Round(([double]$counter[0].CurrentBandwidth / 1000000), 1) } else { $null }
    BytesReceivedPerSec = if ($counter.Count -gt 0) { [int64]$counter[0].BytesReceivedPersec } else { $null }
    BytesSentPerSec = if ($counter.Count -gt 0) { [int64]$counter[0].BytesSentPersec } else { $null }
    ReceivedPacketErrors = $rxErrors
    OutboundPacketErrors = $txErrors
    ReceivedPacketDiscards = $rxDiscards
    OutboundPacketDiscards = $txDiscards
    ErrorOrDiscardTotal = if ($null -ne $totalErrors) { [int64]$totalErrors } else { $null }
  }
}

$networkProblemCounters = @($networkCounterRows | Where-Object { $null -ne $_.ErrorOrDiscardTotal -and $_.ErrorOrDiscardTotal -gt 0 })
$enabledNetworkRows = @($networkCounterRows | Where-Object { $_.NetEnabled -eq $true })
New-Component -Category "Network Link Counters" -Name "Adapter link speed and packet error counters" -Status $(if ($networkProblemCounters.Count -gt 0) { "warning" } elseif ($networkCounterRows.Count -eq 0 -or $networkInterfaceCounters.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  AdapterCount = $networkAdapters.Count
  CounterRowCount = $networkInterfaceCounters.Count
  EnabledAdapterCount = $enabledNetworkRows.Count
  ProblemCounterCount = $networkProblemCounters.Count
  ProblemCounters = @($networkProblemCounters | Select-Object -First 20)
  Counters = @($networkCounterRows | Select-Object -First 30)
} -Signals $(if ($networkProblemCounters.Count -gt 0) { @("$($networkProblemCounters.Count) network adapter counter row(s) report packet errors or discards.") } elseif ($networkCounterRows.Count -eq 0 -or $networkInterfaceCounters.Count -eq 0) { @("Windows did not expose network interface performance counters to this scanner.") } else { @() }) -Recommendations $(if ($networkProblemCounters.Count -gt 0) { @("Inspect the affected cable, port, antenna, switch/router, and NIC driver before replacing hardware.") } elseif ($networkCounterRows.Count -eq 0 -or $networkInterfaceCounters.Count -eq 0) { @("Use Device Manager, vendor tools, or router/switch counters to validate link errors if network symptoms exist.") } else { @("No live packet error/discard counters were reported for enumerated physical adapters. Intermittent cable, port, antenna, or router issues still require symptom-time testing.") })

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

$activeMonitorIds = @($monitorIds | Where-Object { $_.Active -eq $true })
$monitorIdentityRows = @()
foreach ($monitorId in $activeMonitorIds) {
  $instanceName = $monitorId.InstanceName
  $displayParams = @($monitorDisplayParams | Where-Object { $_.InstanceName -eq $instanceName } | Select-Object -First 1)
  $connectionParams = @($monitorConnectionParams | Where-Object { $_.InstanceName -eq $instanceName } | Select-Object -First 1)
  $widthCm = if ($displayParams.Count -gt 0) { $displayParams[0].MaxHorizontalImageSize } else { $null }
  $heightCm = if ($displayParams.Count -gt 0) { $displayParams[0].MaxVerticalImageSize } else { $null }
  $diagonalInches = if ($widthCm -and $heightCm) { [math]::Round(([math]::Sqrt(([double]$widthCm * [double]$widthCm) + ([double]$heightCm * [double]$heightCm)) / 2.54), 1) } else { $null }
  $outputTechnology = if ($connectionParams.Count -gt 0) { Get-VideoOutputTechnologyName $connectionParams[0].VideoOutputTechnology } else { $null }

  $monitorIdentityRows += [pscustomobject]@{
    FriendlyName = Convert-EdidText $monitorId.UserFriendlyName
    Manufacturer = Convert-EdidText $monitorId.ManufacturerName
    ProductCode = Convert-EdidText $monitorId.ProductCodeID
    SerialNumber = Convert-EdidText $monitorId.SerialNumberID
    ManufacturedWeek = $monitorId.WeekOfManufacture
    ManufacturedYear = $monitorId.YearOfManufacture
    WidthCm = $widthCm
    HeightCm = $heightCm
    DiagonalInches = $diagonalInches
    VideoOutputTechnology = $outputTechnology
    InstanceName = $instanceName
  }
}

New-Component -Category "Display Identity" -Name "EDID monitor identity and connection metadata" -Status $(if ($monitorIdentityRows.Count -gt 0) { "ok" } else { "unknown" }) -Confidence "medium" -Evidence @{
  ActiveEdidDisplayCount = $monitorIdentityRows.Count
  Displays = @($monitorIdentityRows | Select-Object -First 12)
} -Signals $(if ($monitorIdentityRows.Count -eq 0) { @("Windows did not expose active EDID monitor identity rows to this scanner.") } else { @() }) -Recommendations $(if ($monitorIdentityRows.Count -gt 0) { @("Display EDID identity was captured. Cable flicker, dead pixels, HDR/VRR behavior, and intermittent port faults still require live visual testing.") } else { @("Check GPU/display driver and physical monitor connection if display identity is missing or generic.") })

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

$usbControllerById = @{}
foreach ($controller in $usbControllers) {
  foreach ($id in @($controller.DeviceID, $controller.PNPDeviceID)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$id) -and -not $usbControllerById.ContainsKey([string]$id)) {
      $usbControllerById[[string]$id] = $controller
    }
  }
}

$pnpDeviceById = @{}
foreach ($device in $pnpAll) {
  foreach ($id in @($device.DeviceID, $device.PNPDeviceID)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$id) -and -not $pnpDeviceById.ContainsKey([string]$id)) {
      $pnpDeviceById[[string]$id] = $device
    }
  }
}

$usbTopologyRows = @()
foreach ($association in $usbControllerDeviceAssociations) {
  $controllerId = Get-AssociationReferenceDeviceId $association.Antecedent
  $dependentId = Get-AssociationReferenceDeviceId $association.Dependent
  $controller = if ($controllerId -and $usbControllerById.ContainsKey($controllerId)) { $usbControllerById[$controllerId] } else { $null }
  $dependent = if ($dependentId -and $pnpDeviceById.ContainsKey($dependentId)) { $pnpDeviceById[$dependentId] } else { $null }
  $dependentName = if ($dependent) { $dependent.Name } else { $association.Dependent.Name }
  $dependentClass = if ($dependent) { $dependent.PNPClass } else { $association.Dependent.PNPClass }
  $dependentStatus = if ($dependent) { $dependent.Status } else { $association.Dependent.Status }
  $dependentProblemCode = if ($dependent) { $dependent.ConfigManagerErrorCode } else { $association.Dependent.ConfigManagerErrorCode }

  $usbTopologyRows += [pscustomobject]@{
    ControllerName = if ($controller) { $controller.Name } else { $association.Antecedent.Name }
    ControllerStatus = if ($controller) { $controller.Status } else { $association.Antecedent.Status }
    ControllerProblemCode = if ($controller) { $controller.ConfigManagerErrorCode } else { $association.Antecedent.ConfigManagerErrorCode }
    ControllerDeviceID = $controllerId
    DependentName = $dependentName
    DependentClass = $dependentClass
    DependentStatus = $dependentStatus
    DependentProblemCode = $dependentProblemCode
    DependentDeviceID = $dependentId
    IsHubOrRouter = [bool](($dependentName -match "hub|router|composite") -or ($dependentClass -eq "USB") -or ($dependentId -match "^USB4\\ROOT_DEVICE_ROUTER|^USB\\ROOT_HUB"))
    IsStoragePath = [bool](($dependentName -match "mass storage|attached scsi|UAS|disk") -or ($dependentClass -match "DiskDrive|SCSIAdapter") -or ($dependentId -match "^USBSTOR\\"))
  }
}

$usbTopologyProblemRows = @($usbTopologyRows | Where-Object {
  ($_.ControllerProblemCode -and $_.ControllerProblemCode -ne 0) -or
  ($_.DependentProblemCode -and $_.DependentProblemCode -ne 0) -or
  ($_.ControllerStatus -and $_.ControllerStatus -ne "OK") -or
  ($_.DependentStatus -and $_.DependentStatus -ne "OK")
})

$usbControllerPathSummaries = @(
  $usbTopologyRows |
    Group-Object ControllerDeviceID |
    ForEach-Object {
      $rows = @($_.Group)
      [pscustomobject]@{
        ControllerDeviceID = $_.Name
        ControllerName = @($rows | Where-Object { $_.ControllerName } | Select-Object -First 1 -ExpandProperty ControllerName)
        ControllerStatus = @($rows | Where-Object { $_.ControllerStatus } | Select-Object -First 1 -ExpandProperty ControllerStatus)
        DeviceCount = $rows.Count
        HubOrRouterCount = @($rows | Where-Object { $_.IsHubOrRouter }).Count
        StoragePathCount = @($rows | Where-Object { $_.IsStoragePath }).Count
        ProblemPathCount = @($rows | Where-Object {
          ($_.ControllerProblemCode -and $_.ControllerProblemCode -ne 0) -or
          ($_.DependentProblemCode -and $_.DependentProblemCode -ne 0) -or
          ($_.ControllerStatus -and $_.ControllerStatus -ne "OK") -or
          ($_.DependentStatus -and $_.DependentStatus -ne "OK")
        }).Count
      }
    } |
    Sort-Object ProblemPathCount, DeviceCount -Descending
)

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

New-Component -Category "USB Device Inventory" -Name "USB and USB storage PnP devices" -Status $(if ($usbProblemDevices.Count -gt 0) { "warning" } elseif ($usbPnpDevices.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  UsbDeviceCount = $usbPnpDevices.Count
  UsbStorageDeviceCount = $usbStorageDevices.Count
  UsbHubLikeDeviceCount = $usbHubDevices.Count
  ProblemDeviceCount = $usbProblemDevices.Count
  ProblemDevices = @($usbProblemDevices | Select-Object -First 30 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  StorageDevices = @($usbStorageDevices | Select-Object -First 20 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  SampleDevices = @($usbPnpDevices | Select-Object -First 40 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
} -Signals $(if ($usbProblemDevices.Count -gt 0) { @("$($usbProblemDevices.Count) USB/USBSTOR device(s) have Device Manager problem codes.") } elseif ($usbPnpDevices.Count -eq 0) { @("Windows did not expose USB/USBSTOR PnP device rows to this scanner.") } else { @() }) -Recommendations $(if ($usbProblemDevices.Count -gt 0) { @("Fix listed USB problem-code devices before replacing ports, cables, hubs, docks, or USB devices.") } elseif ($usbPnpDevices.Count -eq 0) { @("Use Device Manager or vendor tools if USB symptoms exist because Windows did not expose USB PnP rows.") } else { @("USB/USBSTOR devices are enumerated without Device Manager problem codes. Intermittent disconnects, weak ports, cables, hubs, and docks still require symptom-time physical testing.") })

New-Component -Category "USB Topology" -Name "Controller-to-device path map" -Status $(if ($usbTopologyProblemRows.Count -gt 0) { "warning" } elseif ($usbControllerDeviceAssociations.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  AssociationCount = $usbControllerDeviceAssociations.Count
  ControllerPathCount = $usbControllerPathSummaries.Count
  ProblemPathCount = $usbTopologyProblemRows.Count
  ControllerPaths = @($usbControllerPathSummaries | Select-Object -First 20)
  ProblemAssociations = @($usbTopologyProblemRows | Select-Object -First 30)
  SampleAssociations = @($usbTopologyRows | Select-Object -First 80)
} -Signals $(if ($usbTopologyProblemRows.Count -gt 0) { @("$($usbTopologyProblemRows.Count) USB controller/device association path(s) report a non-OK status or Device Manager problem code.") } elseif ($usbControllerDeviceAssociations.Count -eq 0) { @("Windows did not expose USB controller-to-device association rows to this scanner.") } else { @() }) -Recommendations $(if ($usbTopologyProblemRows.Count -gt 0) { @("Use the listed controller path to test the affected physical port, cable, hub, dock, or USB device before replacing hardware.") } elseif ($usbControllerDeviceAssociations.Count -eq 0) { @("Use Device Manager by connection view or vendor USB/Thunderbolt tools if USB symptoms exist because association rows were unavailable.") } else { @("USB controller-to-device paths are mapped without Windows problem codes. Intermittent port, cable, hub, dock, and power faults still require symptom-time physical testing.") })

New-PnpInventoryComponent -Name "HID-class controls and human interface devices" -Devices $hidPeripheralDevices -AbsentRecommendation "No HID-class peripheral inventory was exposed by Windows in this scan." -HealthyRecommendation "HID-class devices are detected without Device Manager problem codes. Button, stick, key, touch, and sensor accuracy still require physical testing." -ProblemRecommendation "Fix the listed HID Device Manager problem codes first, then test the affected control path with a known-good cable, dongle, or port."
New-PnpInventoryComponent -Name "Bluetooth radios and paired hardware" -Devices $bluetoothPeripheralDevices -AbsentRecommendation "No Bluetooth hardware was exposed by Windows in this scan." -HealthyRecommendation "Bluetooth-class devices are detected without Device Manager problem codes. Range, antenna, battery, and interference still require physical testing." -ProblemRecommendation "Fix the listed Bluetooth problem devices before replacing radios or paired hardware."
New-PnpInventoryComponent -Name "Camera and imaging devices" -Devices $cameraPeripheralDevices -AbsentRecommendation "No camera or imaging hardware was exposed by Windows in this scan." -HealthyRecommendation "Camera/imaging devices are detected without Device Manager problem codes. Lens, focus, flicker, and microphone quality require live app testing." -ProblemRecommendation "Fix the listed camera/imaging problem devices, then test with the Windows Camera app or vendor diagnostics."
New-PnpInventoryComponent -Name "Sensor-class devices" -Devices $sensorPeripheralDevices -AbsentRecommendation "No sensor-class hardware was exposed by Windows in this scan." -HealthyRecommendation "Sensor-class devices are detected without Device Manager problem codes. Calibration and intermittent behavior still require device-specific validation." -ProblemRecommendation "Fix the listed sensor problem devices and verify calibration with vendor or Windows sensor tools."
New-PnpInventoryComponent -Name "Printer and print-path devices" -Devices $printerPeripheralDevices -AbsentRecommendation "No printer-class hardware was exposed by Windows in this scan." -HealthyRecommendation "Printer-class devices are detected without Device Manager problem codes. Paper path, ink/toner, and mechanical feed issues require printer self-test pages." -ProblemRecommendation "Fix the listed printer problem devices before assuming printer hardware failure."

$pciProblems = @($pciDevices | Where-Object { $_.ConfigManagerErrorCode -ne 0 })
New-Component -Category "PCI and Expansion Bus" -Name "PCI/PCIe device inventory" -Status $(if ($pciProblems.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  DeviceCount = $pciDevices.Count
  ProblemDeviceCount = $pciProblems.Count
  ProblemDevices = @($pciProblems | Select-Object -First 20 Name, PNPClass, ConfigManagerErrorCode, Status)
  SampleDevices = @($pciDevices | Select-Object -First 25 Name, PNPClass, Status)
} -Signals $(if ($pciProblems.Count -gt 0) { @("$($pciProblems.Count) PCI/PCIe device(s) have Device Manager problem codes.") } else { @() }) -Recommendations $(if ($pciProblems.Count -gt 0) { @("Fix PCI/PCIe problem devices before reseating cards or replacing hardware.") } else { @("No PCI/PCIe Device Manager problem code was found. Link stability under load still needs symptom-driven testing.") })

$pciBridgeProblems = @($pciBridgeDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
$pciLaneSensitiveProblems = @($pciLaneSensitiveDevices | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 })
New-Component -Category "PCIe Topology" -Name "Root ports, switch ports, and lane-sensitive devices" -Status $(if ($pciBridgeProblems.Count -gt 0 -or $pciLaneSensitiveProblems.Count -gt 0) { "warning" } elseif ($pciBridgeDevices.Count -eq 0 -and $pciLaneSensitiveDevices.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  BridgeOrPortCount = $pciBridgeDevices.Count
  LaneSensitiveDeviceCount = $pciLaneSensitiveDevices.Count
  ProblemBridgeOrPortCount = $pciBridgeProblems.Count
  ProblemLaneSensitiveDeviceCount = $pciLaneSensitiveProblems.Count
  BridgeAndPortDevices = @($pciBridgeDevices | Select-Object -First 60 Name, PNPClass, Status, ConfigManagerErrorCode, Manufacturer, Service, DeviceID)
  LaneSensitiveDevices = @($pciLaneSensitiveDevices | Select-Object -First 60 Name, PNPClass, Status, ConfigManagerErrorCode, Manufacturer, Service, DeviceID)
} -Signals $(if ($pciBridgeProblems.Count -gt 0 -or $pciLaneSensitiveProblems.Count -gt 0) { @("$($pciBridgeProblems.Count) PCIe bridge/port problem device(s) and $($pciLaneSensitiveProblems.Count) lane-sensitive PCIe problem device(s) were found.") } elseif ($pciBridgeDevices.Count -eq 0 -and $pciLaneSensitiveDevices.Count -eq 0) { @("Windows did not expose PCIe bridge/root-port or lane-sensitive device rows to this scanner.") } else { @() }) -Recommendations $(if ($pciBridgeProblems.Count -gt 0 -or $pciLaneSensitiveProblems.Count -gt 0) { @("Fix the listed PCIe path device(s), then inspect seating, slot, riser, cable, dock, BIOS PCIe settings, and power delivery before replacing endpoint hardware.") } elseif ($pciBridgeDevices.Count -eq 0 -and $pciLaneSensitiveDevices.Count -eq 0) { @("Use Device Manager, BIOS/UEFI, motherboard tools, or vendor diagnostics if PCIe symptoms exist because topology rows were unavailable.") } else { @("PCIe root/switch ports and lane-sensitive devices are enumerated without Device Manager problem codes. Intermittent slot, riser, link-width, signal-integrity, and load-only faults still need symptom-time testing.") })

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

New-Component -Category "Audio Endpoint Inventory" -Name "Speaker, microphone, and media endpoint devices" -Status $(if ($audioProblemDevices.Count -gt 0) { "warning" } elseif ($audioInventoryDevices.Count -eq 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  EndpointCount = $audioEndpointDevices.Count
  MediaDeviceCount = $audioMediaDevices.Count
  InventoryDeviceCount = $audioInventoryDevices.Count
  ProblemDeviceCount = $audioProblemDevices.Count
  ProblemDevices = @($audioProblemDevices | Select-Object -First 30 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  Endpoints = @($audioEndpointDevices | Select-Object -First 30 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
  MediaDevices = @($audioMediaDevices | Select-Object -First 30 Name, PNPClass, Status, ConfigManagerErrorCode, DeviceID)
} -Signals $(if ($audioProblemDevices.Count -gt 0) { @("$($audioProblemDevices.Count) audio endpoint/media device(s) have Device Manager problem codes.") } elseif ($audioInventoryDevices.Count -eq 0) { @("Windows did not expose audio endpoint/media PnP rows to this scanner.") } else { @() }) -Recommendations $(if ($audioProblemDevices.Count -gt 0) { @("Fix listed audio Device Manager problem-code devices before replacing speakers, headsets, microphones, cables, ports, or Bluetooth/USB audio hardware.") } elseif ($audioInventoryDevices.Count -eq 0) { @("Use Sound settings, Device Manager, or vendor tools if audio symptoms exist because endpoint rows were unavailable.") } else { @("Audio endpoints and media devices are enumerated without Device Manager problem codes. Crackle, low volume, mic quality, speaker damage, cable noise, and Bluetooth range still require live symptom-time testing.") })

$driverPackages = @(Convert-PnpUtilDriverPackages $driverPackageText)
$driverPackageByPublishedName = @{}
foreach ($package in $driverPackages) {
  if ($package.PublishedName -and -not $driverPackageByPublishedName.ContainsKey($package.PublishedName)) {
    $driverPackageByPublishedName[$package.PublishedName] = $package
  }
}

$wmiUnsignedDrivers = @($signedDrivers | Where-Object { $_.IsSigned -eq $false })
$nullSignedDrivers = @($signedDrivers | Where-Object { $null -eq $_.IsSigned })
$driverSignatureRows = @()
foreach ($driver in $wmiUnsignedDrivers) {
  $package = if ($driver.InfName -and $driverPackageByPublishedName.ContainsKey($driver.InfName)) { $driverPackageByPublishedName[$driver.InfName] } else { $null }
  $packageSigner = if ($package) { [string]$package.SignerName } else { $null }
  $packageSigned = [bool](-not [string]::IsNullOrWhiteSpace($packageSigner))
  $packageMicrosoftSigned = [bool]($packageSigner -match "Microsoft Windows Hardware Compatibility Publisher|Microsoft Windows|Microsoft")
  $driverSignatureRows += [pscustomobject]@{
    DeviceName = $driver.DeviceName
    DeviceClass = $driver.DeviceClass
    DeviceID = $driver.DeviceID
    HardwareID = $driver.HardWareID
    InfName = $driver.InfName
    WmiIsSigned = $driver.IsSigned
    WmiSigner = $driver.Signer
    DriverProviderName = $driver.DriverProviderName
    DriverVersion = $driver.DriverVersion
    DriverDate = $driver.DriverDate
    PackageOriginalName = if ($package) { $package.OriginalName } else { $null }
    PackageSignerName = $packageSigner
    PackageCatalogFile = if ($package) { $package.CatalogFile } else { $null }
    PackageDriverFiles = if ($package) { @($package.Files | Select-Object -First 20) } else { @() }
    PackageSigned = $packageSigned
    PackageMicrosoftSigned = $packageMicrosoftSigned
    NeedsReview = -not $packageSigned
  }
}
$unresolvedUnsignedDriverRows = @($driverSignatureRows | Where-Object { $_.NeedsReview -eq $true })
$packageSignedWmiUnsignedRows = @($driverSignatureRows | Where-Object { $_.PackageSigned -eq $true })
$nullSignedDriverRows = @($nullSignedDrivers | Select-Object -First 30 DeviceName, DeviceClass, DeviceID, HardWareID, InfName, DriverProviderName)
New-Component -Category "Driver Integrity" -Name "PnP driver signature cross-check" -Status $(if ($unresolvedUnsignedDriverRows.Count -gt 0) { "warning" } elseif ($wmiUnsignedDrivers.Count -gt 0 -or $nullSignedDrivers.Count -gt 0) { "info" } else { "ok" }) -Confidence "medium" -Evidence @{
  DriverCount = $signedDrivers.Count
  DriverPackageCount = $driverPackages.Count
  WmiUnsignedDriverCount = $wmiUnsignedDrivers.Count
  PackageSignedWmiUnsignedCount = $packageSignedWmiUnsignedRows.Count
  UnresolvedUnsignedDriverCount = $unresolvedUnsignedDriverRows.Count
  NullSignedDriverCount = $nullSignedDrivers.Count
  UnresolvedUnsignedDrivers = @($unresolvedUnsignedDriverRows | Select-Object -First 30)
  WmiUnsignedDriversWithPackageSigners = @($packageSignedWmiUnsignedRows | Select-Object -First 30)
  NullSignedDrivers = $nullSignedDriverRows
} -Signals $(if ($unresolvedUnsignedDriverRows.Count -gt 0) { @("$($unresolvedUnsignedDriverRows.Count) PnP driver row(s) are WMI-unsigned and have no package signer in pnputil output.") } elseif ($wmiUnsignedDrivers.Count -gt 0) { @("$($wmiUnsignedDrivers.Count) WMI-unsigned PnP driver row(s) were cross-checked against pnputil; $($packageSignedWmiUnsignedRows.Count) have package-level catalog signers.") } elseif ($nullSignedDrivers.Count -gt 0) { @("$($nullSignedDrivers.Count) PnP driver row(s) did not expose a WMI IsSigned value.") } else { @() }) -Recommendations $(if ($unresolvedUnsignedDriverRows.Count -gt 0) { @("Review unresolved unsigned driver rows first; driver integrity issues can mimic hardware failures.") } elseif ($wmiUnsignedDrivers.Count -gt 0) { @("No unresolved unsigned driver package was found. Treat WMI unsigned rows with package-level Microsoft/WHCP signer as a Windows reporting mismatch unless device symptoms point to that driver.") } elseif ($nullSignedDrivers.Count -gt 0) { @("Rows without WMI signing metadata are listed for transparency; correlate only if the matching device has symptoms.") } else { @("All enumerated PnP drivers report signed status.") })

New-Component -Category "Power Capabilities" -Name "powercfg /a" -Status "info" -Confidence "medium" -Evidence @{
  Lines = @($powerCfgA | Select-Object -First 40)
} -Signals @() -Recommendations @("Power capability data was collected. PSU quality, wall power, and power-cable problems still require physical/load testing.")

$kernelPowerProblemEvents = @($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-Kernel-Power" -and ($_.Id -eq 41 -or $_.LevelDisplayName -match "Critical|Error") })
$powerStabilityProblemEvents = @($kernelPowerProblemEvents + $unexpectedShutdownEvents | Where-Object { $_ })
New-Component -Category "Power Stability" -Name "PSU, AC, battery, and unexpected shutdown evidence" -Status $(if ($powerStabilityProblemEvents.Count -gt 0) { "warning" } else { "ok" }) -Confidence "medium" -Evidence @{
  PowerSupplyRows = @($powerSupplies | Select-Object -First 20 Name, DeviceID, Status, Availability, PowerManagementSupported, PNPDeviceID)
  UpsRows = @($upsDevices | Select-Object -First 20 Name, DeviceID, Status, EstimatedChargeRemaining, TimeOnBackup)
  BatteryRows = @($batteries | Select-Object -First 20 Name, Status, BatteryStatus, EstimatedChargeRemaining, EstimatedRunTime)
  KernelPowerProblemEventCount = $kernelPowerProblemEvents.Count
  UnexpectedShutdownEventCount = $unexpectedShutdownEvents.Count
  ProblemEvents = @($powerStabilityProblemEvents | Select-Object -First 20 TimeCreated, Id, ProviderName, LevelDisplayName, @{ Name = "Message"; Expression = { Convert-ToBoundedText $_.Message 500 } })
} -Signals $(if ($powerStabilityProblemEvents.Count -gt 0) { @("$($powerStabilityProblemEvents.Count) recent power-loss or unexpected-shutdown event(s) were found.") } else { @() }) -Recommendations $(if ($powerStabilityProblemEvents.Count -gt 0) { @("Correlate these timestamps with outages, freezes, sleep/resume, GPU load, CPU load, wall power, PSU cables, and UPS behavior before replacing parts.") } else { @("No recent Kernel-Power 41 or EventLog 6008 unexpected-shutdown evidence was found in the scan window. PSU ripple, weak cables, wall power, and load-only failures still require controlled physical/load testing.") })

if ($powerStabilityProblemEvents.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Power stability" -Title "Recent power-loss or unexpected-shutdown evidence" -Detail "Windows logged Kernel-Power or unexpected-shutdown evidence in the recent scan window." -Evidence "$($kernelPowerProblemEvents.Count) Kernel-Power problem event(s); $($unexpectedShutdownEvents.Count) EventLog 6008 unexpected shutdown event(s) since $startTime." -Recommendation "Check wall power, UPS, PSU cables, GPU/CPU load correlation, sleep/resume timing, and PSU health before assuming a single component failure." -Confidence "medium"
}

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
$inaccessibleDumpRoots = @($dumpRootResults | Where-Object {
  $nonEmptyAccessErrors = @($_.AccessErrors | Where-Object { $_ })
  $isOptionalMissingMemoryDump = (-not $_.Exists) -and $_.Root -match "MEMORY\.DMP$"
  (-not $isOptionalMissingMemoryDump) -and ($nonEmptyAccessErrors.Count -gt 0 -or (-not $_.Exists))
})
$crashDumpHints = @($recentCrashDumps | Sort-Object LastWriteTime -Descending | Select-Object -First 12 | ForEach-Object { Get-DumpHint -File $_ })
$crashDumpHintValues = @($crashDumpHints | ForEach-Object { $_.Hints } | Where-Object { $_ } | Select-Object -Unique)
$crashDumpHintEvidence = @($crashDumpHints | ForEach-Object {
  [pscustomobject]@{
    Path = $_.Path
    LastWriteTime = $_.LastWriteTime
    SizeMB = $_.SizeMB
    ScannedBytes = $_.ScannedBytes
    ScanStatus = $_.ScanStatus
    HintText = ((@($_.Hints) | Select-Object -First 50) -join ", ")
  }
})
New-Component -Category "Crash Dump Artifacts" -Name "Recent Windows dump files" -Status $(if ($recentCrashDumps.Count -gt 0) { "warning" } elseif ($inaccessibleDumpRoots.Count -gt 0) { "unknown" } else { "ok" }) -Confidence "medium" -Evidence @{
  RecentDumpCount = $recentCrashDumps.Count
  LiveKernelDumpCount = $liveKernelDumps.Count
  DumpRoots = @($dumpRootResults)
  Dumps = @($recentCrashDumps | Sort-Object LastWriteTime -Descending | Select-Object -First 30 @{ Name = "Path"; Expression = { $_.FullName } }, LastWriteTime, @{ Name = "SizeMB"; Expression = { [math]::Round($_.Length / 1MB, 2) } })
  DumpHints = @($crashDumpHintEvidence)
  UniqueHintKeywords = @($crashDumpHintValues)
} -Signals $(if ($recentCrashDumps.Count -gt 0) { @("$($recentCrashDumps.Count) recent Windows crash dump artifact(s) were found.", "$($crashDumpHintValues.Count) unique bounded dump keyword hint(s) were extracted.") } elseif ($inaccessibleDumpRoots.Count -gt 0) { @("$($inaccessibleDumpRoots.Count) dump root(s) were not accessible or not present for this process.") } else { @() }) -Recommendations $(if ($recentCrashDumps.Count -gt 0) { @("Preserve these dumps before cleanup; analyze them with debugger tooling to confirm root cause. Bounded keyword hints are triage clues, not a full dump analysis.") } elseif ($inaccessibleDumpRoots.Count -gt 0) { @("Run the launcher as administrator to inspect protected Windows dump locations before concluding no dump evidence exists.") } else { @("No recent Windows crash dump artifacts were found in the checked dump locations.") })

if ($recentCrashDumps.Count -gt 0) {
  New-Finding -Severity "warning" -Component "Crash dump artifacts" -Title "Recent Windows crash dump files exist" -Detail "Crash dump files can contain the strongest evidence for intermittent hardware, driver, GPU, USB, RAM, storage, or power faults." -Evidence "$($recentCrashDumps.Count) dump file(s), including $($liveKernelDumps.Count) LiveKernelReports file(s), since $startTime. Hints: $((@($crashDumpHintValues | Select-Object -First 12) -join ', '))" -Recommendation "Do not delete the dump files until they are analyzed; correlate timestamps and hint keywords with crashes or hardware symptoms." -Confidence "medium"
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
New-Diagnostic -Name "USB device inventory and problem-code sweep" -Status $(if ($usbProblemDevices.Count -gt 0) { "warning" } elseif ($usbPnpDevices.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($usbPnpDevices.Count) USB/USBSTOR/USB4 PnP device row(s), $($usbStorageDevices.Count) USB storage-related row(s), $($usbHubDevices.Count) hub/router/composite row(s), $($usbProblemDevices.Count) USB problem device(s)." -NextStep $(if ($usbProblemDevices.Count -gt 0) { "Inspect listed USB devices, cables, ports, hubs, docks, and drivers before replacing hardware." } elseif ($usbPnpDevices.Count -eq 0) { "Use Device Manager/vendor tools if USB symptoms exist because USB PnP rows were unavailable." } else { "No USB Device Manager problem codes were found; retest during disconnect or performance symptoms for intermittent faults." })
New-Diagnostic -Name "USB controller topology and path sweep" -Status $(if ($usbTopologyProblemRows.Count -gt 0) { "warning" } elseif ($usbControllerDeviceAssociations.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($usbControllerDeviceAssociations.Count) USB controller/device association row(s), $($usbControllerPathSummaries.Count) controller path group(s), $($usbTopologyProblemRows.Count) problem path(s)." -NextStep $(if ($usbTopologyProblemRows.Count -gt 0) { "Use the listed controller-to-device paths to isolate the physical USB port, cable, hub, dock, or attached device." } elseif ($usbControllerDeviceAssociations.Count -eq 0) { "Use Device Manager by connection view or vendor tooling if USB symptoms exist because topology association rows were unavailable." } else { "No USB controller path problem codes were found; retest during disconnect or power/performance symptoms for intermittent USB faults." })
New-Diagnostic -Name "Peripheral inventory problem-code sweep" -Status $(if ($peripheralProblemDevices.Count -gt 0) { "warning" } else { "passed" }) -Evidence "HID=$($hidPeripheralDevices.Count), Bluetooth=$($bluetoothPeripheralDevices.Count), Camera/Imaging=$($cameraPeripheralDevices.Count), Sensors=$($sensorPeripheralDevices.Count), Printers=$($printerPeripheralDevices.Count); $($peripheralProblemDevices.Count) unique peripheral problem device(s)." -NextStep $(if ($peripheralProblemDevices.Count -gt 0) { "Fix listed peripheral Device Manager problem codes, then retest the physical device path with known-good cables, ports, dongles, or vendor tools." } else { "No peripheral Device Manager problem codes found in the explicit HID/Bluetooth/camera/sensor/printer sweep." })
New-Diagnostic -Name "Display EDID identity sweep" -Status $(if ($monitorIdentityRows.Count -gt 0) { "passed" } else { "limited" }) -Evidence "$($monitorIdentityRows.Count) active EDID display identity row(s), $($monitorDisplayParams.Count) display parameter row(s), $($monitorConnectionParams.Count) connection parameter row(s)." -NextStep $(if ($monitorIdentityRows.Count -gt 0) { "Use the display identity rows to match physical monitors before testing cables, ports, dead pixels, HDR, VRR, or flicker." } else { "Run with current GPU/display drivers and active monitors attached; visually test displays because EDID was not exposed." })
New-Diagnostic -Name "Network link and packet error counters" -Status $(if ($networkProblemCounters.Count -gt 0) { "warning" } elseif ($networkCounterRows.Count -eq 0 -or $networkInterfaceCounters.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($networkCounterRows.Count) physical adapter counter row(s), $($enabledNetworkRows.Count) enabled adapter(s), $($networkProblemCounters.Count) adapter row(s) with packet errors/discards." -NextStep $(if ($networkProblemCounters.Count -gt 0) { "Inspect cable, port, antenna, router/switch, and NIC driver for the listed adapter counters." } elseif ($networkCounterRows.Count -eq 0 -or $networkInterfaceCounters.Count -eq 0) { "Use vendor/router/switch counters if network symptoms exist because Windows counters were unavailable." } else { "No live packet error/discard counters were reported; retest during symptoms for intermittent link faults." })
New-Diagnostic -Name "Audio endpoint and media device sweep" -Status $(if ($audioProblemDevices.Count -gt 0) { "warning" } elseif ($audioInventoryDevices.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($audioEndpointDevices.Count) audio endpoint row(s), $($audioMediaDevices.Count) media/audio device row(s), $($audioProblemDevices.Count) audio problem device(s)." -NextStep $(if ($audioProblemDevices.Count -gt 0) { "Inspect listed audio endpoints/devices, cables, ports, Bluetooth/USB path, and drivers before replacing hardware." } elseif ($audioInventoryDevices.Count -eq 0) { "Use Sound settings or Device Manager if audio symptoms exist because audio endpoint rows were unavailable." } else { "No audio endpoint/media Device Manager problem codes were found; live playback/recording symptoms still need symptom-time testing." })
New-Diagnostic -Name "DirectX display/audio/input diagnostic" -Status $(if ($dxdiagText.Count -eq 0) { "limited" } elseif ($dxProblemLines.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$(if ($dxdiagText.Count -gt 0) { "$dxOkCount 'No problems found' line(s), $($dxProblemLines.Count) problem/error line(s)." } else { "dxdiag skipped in the default safe scan path." })" -NextStep $(if ($dxProblemLines.Count -gt 0) { "Review dxdiag problem lines in the raw report." } elseif ($dxdiagText.Count -eq 0) { "Use HARDWARE_TRUTH_RUN_DXDIAG=1 only if you explicitly want live dxdiag probing." } else { "No dxdiag problem lines found." })
New-Diagnostic -Name "Power source and unexpected shutdown sweep" -Status $(if ($powerStabilityProblemEvents.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$($powerSupplies.Count) power supply row(s), $($upsDevices.Count) UPS row(s), $($batteries.Count) battery row(s), $($kernelPowerProblemEvents.Count) Kernel-Power problem event(s), $($unexpectedShutdownEvents.Count) EventLog 6008 unexpected shutdown event(s)." -NextStep $(if ($powerStabilityProblemEvents.Count -gt 0) { "Correlate power-event timestamps with wall power, UPS, PSU, sleep/resume, GPU/CPU load, and cable seating." } else { "No recent Windows power-loss event evidence was found; PSU and wall-power quality still require physical/load testing if symptoms exist." })
New-Diagnostic -Name "Storage SMART and reliability telemetry" -Status $(if ($optionalProbeErrors | Where-Object { $_.Name -match "physicaldisks|storage counters|smart" }) { "limited" } elseif ($smartStatus | Where-Object { $_.PredictFailure -eq $true }) { "critical" } else { "passed" }) -Evidence "$(if ($optionalProbeErrors | Where-Object { $_.Name -match "physicaldisks|storage counters|smart" }) { "Windows advanced storage providers were unavailable; generic disk status and event logs were used." } else { "Windows advanced storage providers returned data." })" -NextStep "Use vendor SSD/HDD diagnostics or smartctl for full drive attribute verification."
New-Diagnostic -Name "Storage controller and adapter sweep" -Status $(if ($storageControllerProblemDevices.Count -gt 0) { "warning" } elseif ($storageControllerDevices.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($storageControllerDevices.Count) storage controller/adapter PnP row(s), $($storageControllerProblemDevices.Count) problem device(s)." -NextStep $(if ($storageControllerProblemDevices.Count -gt 0) { "Inspect listed controller/adapter devices, drivers, docks, slots, and cables before replacing disks." } elseif ($storageControllerDevices.Count -eq 0) { "Use Device Manager, BIOS/UEFI, or vendor controller tooling if storage symptoms exist because controller rows were unavailable." } else { "No storage controller/adapter Device Manager problem codes were found; retest during storage disconnect or performance symptoms for intermittent faults." })
New-Diagnostic -Name "Physical disk to volume correlation" -Status $(if ($dirtyStorageMapRows.Count -gt 0) { "warning" } elseif ($storageMapRows.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($storageMapRows.Count) disk/partition mapping row(s), $($mappedLogicalDisks.Count) mapped drive-letter volume(s), $($unmappedLogicalDisks.Count) unmapped drive-letter volume(s), $($dirtyStorageMapRows.Count) dirty mapped volume(s)." -NextStep $(if ($dirtyStorageMapRows.Count -gt 0) { "Use the mapped disk model/index before running repair or replacing storage: $((@($dirtyStorageTargets) | Select-Object -First 5) -join '; ')." } elseif ($storageMapRows.Count -eq 0) { "Use Disk Management or vendor tooling to map affected volumes to physical drives manually." } else { "Volume-to-physical-disk mapping is available for future storage warnings." })
New-Diagnostic -Name "Storage live performance counter sweep" -Status $(if ($busyLogicalDiskRows.Count -gt 0 -or $busyPhysicalDiskRows.Count -gt 0) { "warning" } elseif ($physicalDiskPerfRows.Count -eq 0 -and $logicalDiskPerfRows.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($physicalDiskPerfRows.Count) physical disk counter row(s), $($logicalDiskPerfRows.Count) logical disk counter row(s), $($busyPhysicalDiskRows.Count) busy physical row(s), $($busyLogicalDiskRows.Count) busy logical row(s)." -NextStep $(if ($busyLogicalDiskRows.Count -gt 0 -or $busyPhysicalDiskRows.Count -gt 0) { "Correlate busy disk rows with mapped physical drives, current workload, dirty-bit status, cable/controller path, and repeatability before repair or replacement." } elseif ($physicalDiskPerfRows.Count -eq 0 -and $logicalDiskPerfRows.Count -eq 0) { "Use Resource Monitor, Performance Monitor, or vendor tools if storage symptoms exist because live disk counters were unavailable." } else { "No live disk queue/disk-time pressure was visible; retest while storage symptoms are happening." })
New-Diagnostic -Name "WHEA and recent hardware event sweep" -Status $(if (($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-WHEA-Logger" }).Count -gt 0) { "warning" } else { "passed" }) -Evidence "$(($events | Where-Object { $_.ProviderName -eq "Microsoft-Windows-WHEA-Logger" }).Count) WHEA event(s) in the last $RecentDays day(s)." -NextStep "If WHEA events exist, correlate the listed component with CPU/RAM/GPU/PCIe/power hardware."
New-Diagnostic -Name "CPU topology and live counter sweep" -Status $(if ($processors.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($processors.Count) processor package row(s), $totalLogicalProcessors logical processor(s), $($processorTotalCounters.Count) total counter row(s), $($logicalProcessorCounters.Count) logical processor counter row(s), processor queue length=$cpuQueueLength." -NextStep "Use CPU load, clock, interrupt, queue, cache, and virtualization rows for correlation; run controlled thermal/load diagnostics only if symptoms require it."
New-Diagnostic -Name "NVIDIA GPU live telemetry" -Status $(if ($nvidiaCommand -and $nvidiaRows.Count -gt 0) { "passed" } elseif ($videoControllers | Where-Object { $_.Name -match "NVIDIA" }) { "limited" } else { "unavailable" }) -Evidence "$(if ($nvidiaRows.Count -gt 0) { ($nvidiaRows | ForEach-Object { "$($_.Name): $($_.TemperatureC)C, PState $($_.PState), driver $($_.DriverVersion)" }) -join "; " } else { "nvidia-smi telemetry not available or no NVIDIA GPU detected." })" -NextStep "Run vendor/load diagnostics only if symptoms happen under GPU load."
New-Diagnostic -Name "GPU display mode, VRAM, and link telemetry" -Status $(if ($gpuDisplayProblemRows.Count -gt 0) { "warning" } elseif ($gpuDisplayRows.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($gpuDisplayRows.Count) video controller row(s), $($nvidiaRows.Count) NVIDIA telemetry row(s), $($gpuDisplayProblemRows.Count) problem display pipeline row(s)." -NextStep $(if ($gpuDisplayProblemRows.Count -gt 0) { "Fix video-controller status before replacing GPU, cable, monitor, or PCIe slot hardware." } elseif ($gpuDisplayRows.Count -eq 0) { "Use Device Manager and GPU vendor tools if display symptoms exist because video-controller rows were unavailable." } else { "Use display mode, VRAM, driver, and PCIe link rows to correlate symptoms; visually retest flicker/HDR/VRR/cable issues during symptoms." })
New-Diagnostic -Name "Thermal and fan telemetry" -Status $(if ($hotThirdPartySensors.Count -gt 0) { "warning" } elseif ($thermalZones.Count -eq 0 -and $fans.Count -eq 0 -and $thirdPartySensors.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($thermalZones.Count) ACPI thermal zone(s), $($fans.Count) WMI fan sensor(s), $($thirdPartySensors.Count) third-party sensor row(s)." -NextStep "Use BIOS/vendor tools and physical inspection for definitive fan, pump, dust, and thermal-paste validation."
New-Diagnostic -Name "Memory slot topology and error-correction sweep" -Status $(if ($memoryArrays.Count -eq 0 -and $memoryModules.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($memoryArrays.Count) memory-array row(s), $populatedMemorySlotCount populated DIMM row(s), $declaredMemorySlotCount declared slot(s), $emptyMemorySlotCount empty slot(s)." -NextStep "Use the DIMM locator, bank, speed, voltage, part number, and error-correction rows to match physical sticks before reseating, upgrading, or isolating RAM faults."
New-Diagnostic -Name "Memory live pressure and paging counters" -Status $(if ($memoryPressureStatus -eq "warning") { "warning" } elseif ($memoryPressureStatus -eq "unknown") { "limited" } else { "passed" }) -Evidence "$($memoryPerfCounters.Count) memory counter row(s), $($pageFileUsage.Count) pagefile row(s), commit=$commitPercent%, available=$availableMemoryMb MB, pages output/sec=$pagesOutputPerSec." -NextStep $(if ($memoryPressureStatus -eq "warning") { "Investigate memory pressure/pagefile configuration before treating slowdowns or crashes as physical RAM failure; run boot-level RAM diagnostics if errors persist." } elseif ($memoryPressureStatus -eq "unknown") { "Use Performance Monitor/Resource Monitor and offline memory diagnostics because Windows did not expose live memory pressure rows." } else { "No live memory pressure/pagefile warning was visible; offline diagnostics are still required for physical RAM certainty." })
New-Diagnostic -Name "RAM live evidence and diagnostic history" -Status $(if ($memoryDiagnosticProblemEvents.Count -gt 0) { "warning" } elseif ($memoryDiagnosticOkEvents.Count -gt 0) { "passed" } else { "limited" }) -Evidence "$($memoryModules.Count) DIMM(s) inventoried; $($memoryDiagnosticResults.Count) Windows Memory Diagnostic result event(s) in the last $RecentDays day(s)." -NextStep "Run Windows Memory Diagnostic or MemTest86 from boot for current physical RAM fault testing."
New-Diagnostic -Name "PCIe topology and lane-sensitive device sweep" -Status $(if ($pciBridgeProblems.Count -gt 0 -or $pciLaneSensitiveProblems.Count -gt 0) { "warning" } elseif ($pciBridgeDevices.Count -eq 0 -and $pciLaneSensitiveDevices.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($pciBridgeDevices.Count) PCIe bridge/root/switch port row(s), $($pciLaneSensitiveDevices.Count) lane-sensitive PCIe device row(s), $($pciBridgeProblems.Count) bridge/port problem device(s), $($pciLaneSensitiveProblems.Count) lane-sensitive problem device(s)." -NextStep $(if ($pciBridgeProblems.Count -gt 0 -or $pciLaneSensitiveProblems.Count -gt 0) { "Fix listed PCIe path devices before replacing GPU, NVMe, NIC, USB controller, or motherboard hardware." } elseif ($pciBridgeDevices.Count -eq 0 -and $pciLaneSensitiveDevices.Count -eq 0) { "Use BIOS/UEFI or vendor topology tools if PCIe symptoms exist because Windows topology rows were unavailable." } else { "No PCIe topology Device Manager problem codes were found; retest during GPU, NVMe, USB, or NIC symptoms for intermittent slot or lane faults." })
New-Diagnostic -Name "PCI/PCIe and device setup reliability" -Status $(if ($pciProblems.Count -gt 0 -or $deviceReliabilityProblemEvents.Count -gt 0) { "warning" } else { "passed" }) -Evidence "$($pciDevices.Count) PCI/PCIe device(s), $($pciProblems.Count) PCI problem device(s), $($deviceReliabilityProblemEvents.Count) recent PnP/device setup warning or error event(s)." -NextStep "If warnings exist, fix the specific device/driver path before assuming motherboard, slot, or expansion-card failure."
New-Diagnostic -Name "Driver package signer cross-check" -Status $(if ($unresolvedUnsignedDriverRows.Count -gt 0) { "warning" } elseif ($driverPackages.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($signedDrivers.Count) PnP signed-driver row(s), $($driverPackages.Count) pnputil driver package row(s), $($wmiUnsignedDrivers.Count) WMI-unsigned row(s), $($packageSignedWmiUnsignedRows.Count) WMI-unsigned row(s) with package signer(s), $($unresolvedUnsignedDriverRows.Count) unresolved unsigned row(s)." -NextStep $(if ($unresolvedUnsignedDriverRows.Count -gt 0) { "Review unresolved unsigned packages before blaming hardware because driver faults can mimic hardware problems." } elseif ($driverPackages.Count -eq 0) { "Run pnputil manually or rerun elevated if driver package inventory was unavailable." } elseif ($wmiUnsignedDrivers.Count -gt 0) { "No unresolved unsigned package was found; correlate listed package-signed WMI mismatches only if matching hardware has symptoms." } else { "No unsigned PnP driver evidence was found." })
New-Diagnostic -Name "Reliability Monitor and WER crash sweep" -Status $(if ($crashSignalCount -gt 0) { "warning" } elseif ($reliabilityRecords.Count -eq 0 -and $werEvents.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($hardwareReliabilityRecords.Count) hardware-matching Reliability Monitor record(s), $($werHardwareEvents.Count) hardware-matching Windows Error Reporting event(s)." -NextStep "If records exist, inspect the crash bucket/message text and correlate repeated patterns before replacing hardware."
New-Diagnostic -Name "Crash dump artifact sweep" -Status $(if ($recentCrashDumps.Count -gt 0) { "warning" } elseif ($inaccessibleDumpRoots.Count -gt 0) { "limited" } else { "passed" }) -Evidence "$($recentCrashDumps.Count) recent dump file(s), $($liveKernelDumps.Count) LiveKernelReports file(s), $($crashDumpHintValues.Count) unique bounded keyword hint(s), $($inaccessibleDumpRoots.Count) inaccessible/missing dump root(s)." -NextStep "If dump files exist, preserve them and use debugger tooling for root-cause confirmation; if roots are inaccessible, rerun elevated."
New-Diagnostic -Name "Filesystem dirty-bit sweep" -Status $(if ($dirtyVolumes.Count -gt 0) { "warning" } elseif ($volumeDirtyResults.Count -eq 0) { "limited" } else { "passed" }) -Evidence "$($volumeDirtyResults.Count) volume(s) checked; $($dirtyVolumes.Count) dirty volume(s); $($unsupportedDirtyChecks.Count) unsupported/failed check(s)." -NextStep "If a volume is dirty, back up first and schedule filesystem diagnostics before repair."
New-Diagnostic -Name "Dirty-volume read-only filesystem check" -Status $(if ($dirtyVolumeReadOnlyProblemChecks.Count -gt 0) { "warning" } elseif ($dirtyVolumeReadOnlyIncompleteChecks.Count -gt 0) { "limited" } elseif ($dirtyVolumeReadOnlyChecks.Count -eq 0 -and $dirtyVolumes.Count -gt 0) { "limited" } else { "passed" }) -Evidence "$($dirtyVolumeReadOnlyChecks.Count) dirty-volume read-only chkdsk check(s), $($dirtyVolumeReadOnlyProblemChecks.Count) with problem text, $($dirtyVolumeReadOnlyIncompleteChecks.Count) incomplete or without clean final verdict." -NextStep $(if ($dirtyVolumeReadOnlyProblemChecks.Count -gt 0) { "Back up affected data and review read-only chkdsk output before any repair." } elseif ($dirtyVolumeReadOnlyIncompleteChecks.Count -gt 0) { "Rerun chkdsk manually during a quiet window; the app intentionally bounds read-only filesystem checks." } elseif ($dirtyVolumes.Count -gt 0) { "Dirty volume follow-up was captured; keep backups current and repair only in a planned window." } else { "No dirty volume needed read-only chkdsk follow-up." })
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
    CrashDumpRoots = @($dumpRootResults | ForEach-Object {
      "$(Convert-ToBoundedText $_.Root 500) | Exists=$($_.Exists) | RecentDumpCount=$($_.RecentDumpCount) | Errors=$((@($_.AccessErrors) | Select-Object -First 5) -join '; ')"
    })
    CrashDumpHints = @($crashDumpHints | ForEach-Object {
      "$(Convert-ToBoundedText $_.Path 500) | Status=$($_.ScanStatus) | Hints=$((@($_.Hints) | Select-Object -First 20) -join ', ')"
    })
    VolumeDirtyResults = @($volumeDirtyResults | ForEach-Object {
      "$($_.DeviceID) | Dirty=$($_.IsDirty) | Unsupported=$($_.IsUnsupported) | $(Convert-ToBoundedText (($_.Output) -join ' ') 500)"
    })
    ProbeErrors = @($probeErrors | ForEach-Object { "$(Convert-ToBoundedText $_.Name 120): $(Convert-ToBoundedText $_.Error 500)" })
    OptionalProbeErrors = @($optionalProbeErrors | ForEach-Object { "$(Convert-ToBoundedText $_.Name 120): $(Convert-ToBoundedText $_.Error 500)" })
  }
}

$report | ConvertTo-Json -Depth 8 -Compress:$false
