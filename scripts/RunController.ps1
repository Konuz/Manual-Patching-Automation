# Windows PowerShell 5.1 patch-run controller.
# Public functions:
#   New-PatchRun(config, VM entries) creates runs/<runId>/run.json without credentials.
#   Read-PatchRun, Write-PatchRun, Write-PatchEvent, Write-PatchError persist run state and logs.
#   Get-PatchGuestAccountKey returns an opaque per-run account/VM skip key for GUI state.
#   Invoke-PatchAction(Action, RunPath, VCenterCredential, GuestCredential) runs one operator step.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PatchSensitiveValues = @()

function Get-PatchValue {
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string[]]$Names,
        $Default = $null
    )

    foreach ($name in @($Names)) {
        if ($null -eq $InputObject) {
            break
        }

        if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($name)) {
            return $InputObject[$name]
        }

        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    return $Default
}

function Set-PatchValue {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject[$Name] = $Value
        return
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $property.Value = $Value
    }
    else {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Get-PatchArray {
    param($Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value)
    }
    return @($Value)
}

function Get-PatchUtcNow {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function Get-PatchRunJsonPath {
    param([Parameter(Mandatory = $true)][string]$RunPath)

    if ([string]::IsNullOrWhiteSpace($RunPath)) {
        throw 'RunPath is required.'
    }

    if ($RunPath.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $RunPath
    }
    if (Test-Path -LiteralPath $RunPath -PathType Leaf) {
        return $RunPath
    }
    return (Join-Path $RunPath 'run.json')
}

function Get-PatchRunDirectory {
    param([Parameter(Mandatory = $true)][string]$RunPath)
    return (Split-Path -Parent (Get-PatchRunJsonPath -RunPath $RunPath))
}

function ConvertTo-PatchSafeValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string] -or $Value -is [ValueType]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safeDictionary = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $keyText = [string]$key
            if ($keyText -match '(?i)password|credential|secret|securestring|token') {
                continue
            }
            $safeDictionary[$keyText] = ConvertTo-PatchSafeValue -Value $Value[$key]
        }
        return $safeDictionary
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) {
            [void]$items.Add($item)
        }
        # ConvertTo-Json in Windows PowerShell 5.1 serializes an object[] nested
        # in an OrderedDictionary as a value/Count object. A generic List keeps
        # empty, singleton, and multi-item JSON arrays intact.
        $safeArray = New-Object 'System.Collections.Generic.List[object]'
        for ($index = 0; $index -lt $items.Count; $index++) {
            [void]$safeArray.Add((ConvertTo-PatchSafeValue -Value $items[$index]))
        }
        Write-Output -NoEnumerate $safeArray
        return
    }

    $safeObject = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($property.Name -match '(?i)password|credential|secret|securestring|token') {
            continue
        }
        $safeObject[$property.Name] = ConvertTo-PatchSafeValue -Value $property.Value
    }
    return $safeObject
}

function Write-PatchTextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporaryPath = '{0}.{1}.tmp' -f $Path, ([Guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Register-PatchCredential {
    param($Credential)

    if ($null -eq $Credential) {
        return
    }
    try {
        $userName = [string]$Credential.UserName
        if (-not [string]::IsNullOrWhiteSpace($userName)) {
            $script:PatchSensitiveValues += $userName
        }
    }
    catch {
    }
    try {
        $password = [string]$Credential.GetNetworkCredential().Password
        if (-not [string]::IsNullOrWhiteSpace($password)) {
            $script:PatchSensitiveValues += $password
        }
    }
    catch {
    }
}

function Protect-PatchText {
    param([string]$Text)

    $protected = [string]$Text
    foreach ($value in @($script:PatchSensitiveValues | Sort-Object Length -Descending -Unique)) {
        if (-not [string]::IsNullOrWhiteSpace($value) -and $value.Length -ge 2) {
            $protected = $protected.Replace($value, '<redacted>')
        }
    }
    return $protected
}

function Write-PatchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)]$RunState
    )

    $jsonPath = Get-PatchRunJsonPath -RunPath $RunPath
    Set-PatchValue -InputObject $RunState -Name 'updatedAt' -Value (Get-PatchUtcNow)
    $safeState = ConvertTo-PatchSafeValue -Value $RunState
    $json = $safeState | ConvertTo-Json -Depth 20
    Write-PatchTextAtomic -Path $jsonPath -Text $json
    return $RunState
}

function Read-PatchRun {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RunPath)

    $jsonPath = Get-PatchRunJsonPath -RunPath $RunPath
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        throw ('The patch run was not found: {0}' -f $jsonPath)
    }
    $content = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw ('The patch run is empty: {0}' -f $jsonPath)
    }
    return ($content | ConvertFrom-Json)
}

function New-PatchRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$VMEntries
    )

    $optionsSource = Get-PatchValue -InputObject $Config -Names @('Options', 'options') -Default $null
    $getConfigValue = {
        param([string[]]$Names, $Default)
        $value = Get-PatchValue -InputObject $optionsSource -Names $Names -Default $null
        if ($null -eq $value) {
            $value = Get-PatchValue -InputObject $Config -Names $Names -Default $Default
        }
        if ($null -eq $value) {
            return $Default
        }
        return $value
    }

    $runIdText = [string](Get-PatchValue -InputObject $Config -Names @('RunId', 'runId') -Default '')
    $runId = [Guid]::NewGuid()
    if (-not [string]::IsNullOrWhiteSpace($runIdText)) {
        try { $runId = [Guid]$runIdText } catch { throw 'Config.RunId is not a valid GUID.' }
    }

    $root = [string](Get-PatchValue -InputObject $Config -Names @('RunsRoot', 'RunRoot', 'OutputRoot', 'ResultsRoot', 'OutputDirectory') -Default '')
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'runs'
    }
    if ($root.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
        $root = Split-Path -Parent $root
    }
    $runDirectory = Join-Path $root $runId.ToString('D')
    $runJsonPath = Join-Path $runDirectory 'run.json'
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    }

    $vCenter = Get-PatchValue -InputObject $Config -Names @('VCenter', 'vCenter', 'VCenterServer', 'ServerName', 'Server') -Default ''
    if ($vCenter -isnot [string]) {
        $vCenter = Get-PatchValue -InputObject $vCenter -Names @('ServerName', 'Name', 'Address') -Default ([string]$vCenter)
    }

    $scanConcurrency = [int](& $getConfigValue @('ScanConcurrency', 'scanConcurrency') 3)
    $installConcurrency = [int](& $getConfigValue @('InstallConcurrency', 'installConcurrency') 3)
    $rebootBatch = [int](& $getConfigValue @('RebootBatchSize', 'rebootBatchSize') 1)
    $scanLimit = [int](& $getConfigValue @('ScanTimeoutMinutes', 'scanTimeoutMinutes') 30)
    $installLimit = [int](& $getConfigValue @('InstallTimeoutMinutes', 'installTimeoutMinutes') 180)
    $rebootLimit = [int](& $getConfigValue @('RebootConfirmationTimeoutMinutes', 'rebootConfirmationTimeoutMinutes') 30)

    if ($scanConcurrency -lt 1) { $scanConcurrency = 3 }
    if ($installConcurrency -lt 1) { $installConcurrency = 3 }
    if ($rebootBatch -lt 1) { $rebootBatch = 1 }
    if ($scanLimit -lt 1) { $scanLimit = 30 }
    if ($installLimit -lt 1) { $installLimit = 180 }
    if ($rebootLimit -lt 1) { $rebootLimit = 30 }

    $ignoreVCenter = [bool](& $getConfigValue @('IgnoreVCenterCertificate', 'ignoreVCenterCertificate') $false)
    $ignoreEsxi = [bool](& $getConfigValue @('IgnoreEsxiCertificatesForFileTransfers', 'ignoreEsxiCertificatesForFileTransfers', 'IgnoreEsxiCertificate') $false)

    $vmRecords = @()
    $seenVmNames = @{}
    foreach ($entry in @(Get-PatchArray -Value $VMEntries)) {
        $name = [string]$entry
        $expectedFqdn = ''
        $savedId = $null
        $entryVCenter = [string]$vCenter
        if ($entry -isnot [string]) {
            $name = [string](Get-PatchValue -InputObject $entry -Names @('VmName', 'VMName', 'Name') -Default '')
            $expectedFqdn = [string](Get-PatchValue -InputObject $entry -Names @('ExpectedFqdn', 'ExpectedFQDN', 'Fqdn', 'FQDN') -Default '')
            $savedId = [string](Get-PatchValue -InputObject $entry -Names @('SavedId', 'VmId', 'VMId', 'Id', 'Uid') -Default '')
            $entryVCenter = [string](Get-PatchValue -InputObject $entry -Names @('VCenter', 'vCenter', 'VCenterServer', 'ServerName') -Default $vCenter)
        }
        if ([string]::IsNullOrWhiteSpace($entryVCenter)) { $entryVCenter = [string]$vCenter }
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw 'Each VM entry requires a VM name.'
        }
        $duplicateKey = ([string]$entryVCenter).Trim().ToLowerInvariant() + '|' + $name.Trim().ToLowerInvariant()
        if ($seenVmNames.ContainsKey($duplicateKey)) {
            throw ('Duplicate VM name {0} was supplied for vCenter {1}.' -f $name, $entryVCenter)
        }
        $seenVmNames[$duplicateKey] = $true

        $vmRecords += [ordered]@{
            vmName = $name
            expectedFqdn = $expectedFqdn
            vmId = if ([string]::IsNullOrWhiteSpace($savedId)) { $null } else { $savedId }
            vCenter = $entryVCenter
            status = 'Pending'
            currentRound = 1
            currentAction = $null
            lastProcessedAction = $null
            availableUpdates = @()
            selectedUpdates = @()
            installedUpdates = @()
            skippedUpdates = @()
            pendingUpdates = @()
            reboot = [ordered]@{ status = 'NotRequested'; required = $false; baselineBootTime = $null; requestEvidence = $null; confirmedBootTime = $null }
            steps = @()
            agentStatus = $null
            rejectedGuestAccountKey = $null
            rejectedGuestAccountIsLocal = $null
            errors = @()
            errorLinks = @()
        }
    }

    $state = [ordered]@{
        schemaVersion = 'patch-run-v1'
        runId = $runId.ToString('D')
        createdAt = Get-PatchUtcNow
        updatedAt = Get-PatchUtcNow
        status = 'Created'
        vCenter = [string]$vCenter
        options = [ordered]@{
            ignoreVCenterCertificate = $ignoreVCenter
            ignoreEsxiCertificatesForFileTransfers = $ignoreEsxi
            scanConcurrency = $scanConcurrency
            installConcurrency = $installConcurrency
            rebootBatchSize = $rebootBatch
            limits = [ordered]@{
                scanTimeoutMinutes = $scanLimit
                installTimeoutMinutes = $installLimit
                rebootConfirmationTimeoutMinutes = $rebootLimit
            }
        }
        currentRound = 1
        currentAction = $null
        selectedUpdates = @()
        skippedGuestAccounts = @()
        vms = @($vmRecords)
        errors = @()
        errorLinks = @()
        runPath = $runJsonPath
    }

    Write-PatchRun -RunPath $runJsonPath -RunState $state | Out-Null
    return [pscustomobject]$state
}

function Write-PatchEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$VMName = '',
        [string]$Step = '',
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $logPath = Join-Path (Get-PatchRunDirectory -RunPath $RunPath) 'run.log'
    $line = '{0} [{1}]' -f (Get-PatchUtcNow), $Level
    if (-not [string]::IsNullOrWhiteSpace($VMName)) { $line += ' [' + $VMName + ']' }
    if (-not [string]::IsNullOrWhiteSpace($Step)) { $line += ' [' + $Step + ']' }
    $line += ' ' + (Protect-PatchText -Text $Message)
    $parent = Split-Path -Parent $logPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-PatchError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$VMName = '',
        [string]$Step = '',
        [string]$Code = 'PatchError',
        $Context = $null
    )

    $errorPath = Join-Path (Get-PatchRunDirectory -RunPath $RunPath) 'errors.log'
    $record = [ordered]@{
        time = Get-PatchUtcNow
        code = $Code
        vmName = $VMName
        step = $Step
        message = Protect-PatchText -Text $Message
        context = ConvertTo-PatchSafeValue -Value $Context
    }
    $parent = Split-Path -Parent $errorPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $json = ($record | ConvertTo-Json -Depth 12 -Compress)
    [System.IO.File]::AppendAllText($errorPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    return $record
}

function Write-PatchSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)]$RunState
    )

    $runDirectory = Get-PatchRunDirectory -RunPath $RunPath
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) { New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null }
    $options = Get-PatchValue -InputObject $RunState -Names @('options') -Default ([pscustomobject]@{})
    $limits = Get-PatchValue -InputObject $options -Names @('limits') -Default ([pscustomobject]@{})
    $ignoreVc = [bool](Get-PatchValue -InputObject $options -Names @('ignoreVCenterCertificate') -Default $false)
    $ignoreEsxi = [bool](Get-PatchValue -InputObject $options -Names @('ignoreEsxiCertificatesForFileTransfers') -Default $false)
    $vmRows = @()
    $markdown = New-Object System.Text.StringBuilder
    [void]$markdown.AppendLine('# Patch run summary')
    [void]$markdown.AppendLine('')
    [void]$markdown.AppendLine(('* Run ID: `{0}`' -f [string](Get-PatchValue $RunState @('runId') '')))
    [void]$markdown.AppendLine(('* Status: **{0}**' -f [string](Get-PatchValue $RunState @('status') 'Unknown')))
    [void]$markdown.AppendLine(('* Current round: {0}' -f [string](Get-PatchValue $RunState @('currentRound') 1)))
    [void]$markdown.AppendLine(('* Ignore vCenter certificate: `{0}`' -f $ignoreVc))
    [void]$markdown.AppendLine(('* Ignore ESXi certificates for file transfers: `{0}`' -f $ignoreEsxi))
    [void]$markdown.AppendLine(('* Limits (minutes): scan `{0}`, install `{1}`, reboot confirmation `{2}`' -f [string](Get-PatchValue $limits @('scanTimeoutMinutes') 30), [string](Get-PatchValue $limits @('installTimeoutMinutes') 180), [string](Get-PatchValue $limits @('rebootConfirmationTimeoutMinutes') 30)))
    [void]$markdown.AppendLine('')
    [void]$markdown.AppendLine('| VM | Expected FQDN | Status | Installed | Skipped | Pending | Reboot | Certificate choices | Errors |')
    [void]$markdown.AppendLine('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')

    foreach ($vm in @(Get-PatchArray -Value (Get-PatchValue $RunState @('vms') @()))) {
        $name = [string](Get-PatchValue $vm @('vmName') '')
        $fqdn = [string](Get-PatchValue $vm @('expectedFqdn') '')
        $status = [string](Get-PatchValue $vm @('status') 'Pending')
        $installed = @(Get-PatchArray -Value (Get-PatchValue $vm @('installedUpdates') @()))
        $skipped = @(Get-PatchArray -Value (Get-PatchValue $vm @('skippedUpdates') @()))
        $pending = @(Get-PatchArray -Value (Get-PatchValue $vm @('pendingUpdates') @()))
        $reboot = Get-PatchValue $vm @('reboot') ([pscustomobject]@{})
        $rebootStatus = [string](Get-PatchValue $reboot @('status') 'NotRequested')
        $vmErrors = @(Get-PatchArray -Value (Get-PatchValue $vm @('errors') @()))
        $errorLink = '[errors.log](errors.log)'
        $installedText = (@($installed | ForEach-Object { [string](Get-PatchValue $_ @('updateId', 'title') $_) }) -join ', ')
        $skippedText = (@($skipped | ForEach-Object { [string](Get-PatchValue $_ @('updateId', 'reason') $_) }) -join ', ')
        $pendingText = (@($pending | ForEach-Object { [string](Get-PatchValue $_ @('updateId', 'title') $_) }) -join ', ')
        $escape = { param([string]$Value) ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') }
        $rowValues = @((& $escape $name), (& $escape $fqdn), (& $escape $status), (& $escape $installedText), (& $escape $skippedText), (& $escape $pendingText), (& $escape $rebootStatus), [string]$ignoreVc, [string]$ignoreEsxi, $errorLink, [string]$vmErrors.Count)
        [void]$markdown.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | vCenter={7}; ESXi={8} | {9} ({10}) |' -f $rowValues))
        $vmRows += [pscustomobject]@{
            RunId = [string](Get-PatchValue $RunState @('runId') '')
            VMName = $name
            ExpectedFqdn = $fqdn
            VMId = [string](Get-PatchValue $vm @('vmId') '')
            Status = $status
            InstalledUpdates = $installedText
            SkippedUpdates = $skippedText
            PendingUpdates = $pendingText
            Reboot = $rebootStatus
            IgnoreVCenterCertificate = $ignoreVc
            IgnoreEsxiCertificatesForFileTransfers = $ignoreEsxi
            ErrorLink = $errorLink
        }
    }

    Write-PatchTextAtomic -Path (Join-Path $runDirectory 'summary.md') -Text $markdown.ToString()
    $csvTemporary = Join-Path $runDirectory ('summary.csv.{0}.tmp' -f ([Guid]::NewGuid().ToString('N')))
    try {
        $vmRows | Export-Csv -LiteralPath $csvTemporary -NoTypeInformation -Encoding UTF8
        Move-Item -LiteralPath $csvTemporary -Destination (Join-Path $runDirectory 'summary.csv') -Force
    }
    finally {
        if (Test-Path -LiteralPath $csvTemporary) { Remove-Item -LiteralPath $csvTemporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PatchOption {
    param($RunState, [string[]]$Names, $Default)
    $options = Get-PatchValue -InputObject $RunState -Names @('options') -Default $null
    return (Get-PatchValue -InputObject $options -Names $Names -Default $Default)
}

function Get-PatchLimit {
    param($RunState, [string]$Name, [int]$Default)
    $options = Get-PatchValue -InputObject $RunState -Names @('options') -Default $null
    $limits = Get-PatchValue -InputObject $options -Names @('limits') -Default $null
    return [int](Get-PatchValue -InputObject $limits -Names @($Name) -Default $Default)
}

function Get-PatchVmId {
    param($VM)
    $id = [string](Get-PatchValue -InputObject $VM -Names @('Id', 'VmId', 'Uid') -Default '')
    if ([string]::IsNullOrWhiteSpace($id)) {
        $extension = Get-PatchValue -InputObject $VM -Names @('ExtensionData') -Default $null
        $moref = Get-PatchValue -InputObject $extension -Names @('MoRef') -Default $null
        $id = [string](Get-PatchValue -InputObject $moref -Names @('Value') -Default '')
    }
    return $id
}

function Get-PatchGuestFqdn {
    param($VM, $Context)
    foreach ($candidate in @($Context, $VM, (Get-PatchValue $Context @('VM') $null), (Get-PatchValue $VM @('ExtensionData') $null))) {
        $fqdn = [string](Get-PatchValue -InputObject $candidate -Names @('Fqdn', 'FQDN', 'GuestFqdn', 'GuestFQDN', 'HostName') -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) { return $fqdn.Trim().TrimEnd('.') }
        $guest = Get-PatchValue -InputObject $candidate -Names @('Guest') -Default $null
        $fqdn = [string](Get-PatchValue -InputObject $guest -Names @('HostName') -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fqdn)) { return $fqdn.Trim().TrimEnd('.') }
    }
    return $null
}

function Get-PatchToolsRunning {
    param($Context)
    foreach ($candidate in @($Context, (Get-PatchValue $Context @('VM') $null), (Get-PatchValue (Get-PatchValue $Context @('VM') $null) @('ExtensionData') $null))) {
        $value = Get-PatchValue -InputObject $candidate -Names @('ToolsRunning', 'ToolsRunningStatus') -Default $null
        if ($null -ne $value) {
            return ([bool]$value -or [string]::Equals([string]$value, 'guestToolsRunning', [System.StringComparison]::OrdinalIgnoreCase))
        }
        $guest = Get-PatchValue -InputObject $candidate -Names @('Guest') -Default $null
        $value = Get-PatchValue -InputObject $guest -Names @('ToolsRunning', 'ToolsRunningStatus') -Default $null
        if ($null -ne $value) {
            return ([bool]$value -or [string]::Equals([string]$value, 'guestToolsRunning', [System.StringComparison]::OrdinalIgnoreCase))
        }
    }
    return $false
}

function Get-PatchClusterMembership {
    param($Context, $Status)
    foreach ($candidate in @($Context, $Status)) {
        $value = Get-PatchValue -InputObject $candidate -Names @('clusterMembership', 'ClusterMembership') -Default $null
        if ($null -ne $value) { return [string]$value }
        $cluster = Get-PatchValue -InputObject $candidate -Names @('cluster') -Default $null
        $value = Get-PatchValue -InputObject $cluster -Names @('membership') -Default $null
        if ($null -ne $value) { return [string]$value }
    }
    return $null
}

function Assert-PatchGuestIdentity {
    param($VMRecord, $VM, $Context)
    $expected = ([string](Get-PatchValue $VMRecord @('expectedFqdn') '')).Trim().TrimEnd('.')
    $actual = Get-PatchGuestFqdn -VM $VM -Context $Context
    if ([string]::IsNullOrWhiteSpace($expected)) {
        throw 'The run has no expected guest FQDN for this VM.'
    }
    if ([string]::IsNullOrWhiteSpace($actual) -or -not [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Guest FQDN mismatch. Expected {0}; observed {1}.' -f $expected, $actual)
    }
}

function New-PatchStep {
    param([string]$Action, [string]$AgentMode, [int]$Round)
    return [pscustomobject][ordered]@{
        action = $Action
        agentMode = $AgentMode
        round = $Round
        stepId = ([Guid]::NewGuid()).ToString('D')
        intent = $Action
        intentAt = Get-PatchUtcNow
        status = 'IntentPersisted'
        startAttempted = $false
        processId = $null
        startedAt = $null
        deadlineAt = $null
        finishedAt = $null
        baselineBootTime = $null
        confirmationDeadlineAt = $null
        requestEvidence = $null
        agentStatus = $null
        error = $null
    }
}

function Get-PatchStep {
    param($VMRecord, [string]$Action, [int]$Round)
    $steps = @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('steps') @()))
    for ($index = $steps.Count - 1; $index -ge 0; $index--) {
        $step = $steps[$index]
        if ([string]::Equals([string](Get-PatchValue $step @('action') ''), $Action, [System.StringComparison]::OrdinalIgnoreCase) -and [int](Get-PatchValue $step @('round') 0) -eq $Round) {
            return $step
        }
    }
    $newAgentMode = $Action
    if ($Action -eq 'Verify') { $newAgentMode = 'Scan' }
    $newStep = New-PatchStep -Action $Action -AgentMode $newAgentMode -Round $Round
    Set-PatchValue -InputObject $VMRecord -Name 'steps' -Value @($steps + $newStep)
    return $newStep
}

function Save-PatchDecision {
    param([string]$RunPath, $RunState)
    Write-PatchRun -RunPath $RunPath -RunState $RunState | Out-Null
}

function Get-PatchStatusFinishedAt {
    param($Status)
    $text = [string](Get-PatchValue $Status @('finishedAt') '')
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return ([datetime]::Parse($text)).ToUniversalTime() } catch { return $null }
}

function Test-PatchStatusIdentity {
    param($Status, [string]$RunId, [string]$StepId, [string]$Mode)
    if ($null -eq $Status) { return $false }
    if (-not [string]::Equals([string](Get-PatchValue $Status @('runId') ''), $RunId, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals([string](Get-PatchValue $Status @('stepId') ''), $StepId, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not [string]::Equals([string](Get-PatchValue $Status @('mode') ''), $Mode, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return ($null -ne (Get-PatchStatusFinishedAt -Status $Status))
}

function Test-PatchCompletedStatus {
    param($Status, [string]$RunId, [string]$StepId, [string]$Mode)
    if (-not (Test-PatchStatusIdentity -Status $Status -RunId $RunId -StepId $StepId -Mode $Mode)) { return $false }
    return [string]::Equals([string](Get-PatchValue $Status @('status') ''), 'Completed', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PatchFailedStatus {
    param($Status, [string]$RunId, [string]$StepId, [string]$Mode)
    if (-not (Test-PatchStatusIdentity -Status $Status -RunId $RunId -StepId $StepId -Mode $Mode)) { return $false }
    return [string]::Equals([string](Get-PatchValue $Status @('status') ''), 'Failed', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PatchRebootRequestStatus {
    param($Status, [string]$RunId, [string]$StepId)
    if (-not (Test-PatchStatusIdentity -Status $Status -RunId $RunId -StepId $StepId -Mode 'Reboot')) { return $false }
    return [string]::Equals([string](Get-PatchValue $Status @('status') ''), 'RebootRequested', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PatchRebootFailureResult {
    param($Step, [string]$RunId, [string]$StepId)

    $agentStatus = Get-PatchValue $Step @('agentStatus') $null
    if (-not (Test-PatchFailedStatus -Status $agentStatus -RunId $RunId -StepId $StepId -Mode 'Reboot')) { return $null }
    $errorMessage = [string](Get-PatchValue $Step @('error') '')
    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = [string](Get-PatchValue $agentStatus @('error', 'outcome') 'Guest agent failed.')
    }
    if ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = 'Guest agent failed.' }
    return [pscustomobject]@{ status = 'Failed'; step = $Step; agentStatus = $agentStatus; error = $errorMessage }
}

function Test-PatchMutatingStepReconciled {
    param($Step, [string]$RunId)

    if (-not [bool](Get-PatchValue $Step @('startAttempted') $false)) { return $true }
    $stepId = [string](Get-PatchValue $Step @('stepId') '')
    $action = [string](Get-PatchValue $Step @('action') '')
    $status = [string](Get-PatchValue $Step @('status') '')
    $agentStatus = Get-PatchValue $Step @('agentStatus') $null

    if ([string]::Equals($action, 'Reboot', [System.StringComparison]::OrdinalIgnoreCase)) {
        if (-not [string]::Equals($status, 'Confirmed', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        return (Test-PatchRebootRequestStatus -Status $agentStatus -RunId $RunId -StepId $stepId)
    }
    if (-not [string]::Equals($action, 'Install', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

    if ([string]::Equals($status, 'Completed', [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($status, 'CompletedWithErrors', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Test-PatchCompletedStatus -Status $agentStatus -RunId $RunId -StepId $stepId -Mode 'Install')
    }
    if ([string]::Equals($status, 'Failed', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Test-PatchFailedStatus -Status $agentStatus -RunId $RunId -StepId $stepId -Mode 'Install')
    }
    return $false
}

function Get-PatchMutatingStepBlocker {
    param($RunState, $VMRecord, $CurrentStep)

    $runId = [string](Get-PatchValue $RunState @('runId') '')
    $currentStepId = [string](Get-PatchValue $CurrentStep @('stepId') '')
    foreach ($step in @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('steps') @()))) {
        $action = [string](Get-PatchValue $step @('action') '')
        if (-not [string]::Equals($action, 'Install', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($action, 'Reboot', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($currentStepId) -and
            [string]::Equals([string](Get-PatchValue $step @('stepId') ''), $currentStepId, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not (Test-PatchMutatingStepReconciled -Step $step -RunId $runId)) { return $step }
    }
    return $null
}

function Get-PatchErrorCode {
    param([string]$Message)
    if ($Message -match '(?i)credential|authentication|unauthori[sz]ed|login|password|access.denied') { return 'GuestCredentialRejected' }
    if ($Message -match '(?i)fqdn|host.name|identity') { return 'GuestFqdnMismatch' }
    if ($Message -match '(?i)cluster') { return 'ClusterStateBlocked' }
    return 'PatchActionFailed'
}

function Get-PatchAgentLocalPaths {
    param([string]$RunPath, $VMRecord, $Step)
    $safeName = ([string](Get-PatchValue $VMRecord @('vmName') 'vm')) -replace '[^a-zA-Z0-9_.-]', '_'
    $directory = Get-PatchRunDirectory -RunPath $RunPath
    return [pscustomobject]@{
        status = Join-Path $directory ('status-{0}-{1}.json' -f $safeName, [string](Get-PatchValue $Step @('stepId') ''))
        selection = Join-Path $directory ('selection-{0}-{1}.json' -f $safeName, [string](Get-PatchValue $Step @('stepId') ''))
        agentLog = Join-Path $directory ('agent-{0}-{1}.log' -f $safeName, [string](Get-PatchValue $Step @('stepId') ''))
    }
}

function Get-PatchGuestPaths {
    param($Context, $RunState, $Step)
    $programData = [string](Get-PatchValue $Context @('ProgramData') 'C:\ProgramData')
    $stepDirectory = Join-Path (Join-Path (Join-Path $programData 'WindowsPatchWizard') ([string](Get-PatchValue $RunState @('runId') ''))) ([string](Get-PatchValue $Step @('stepId') ''))
    return [pscustomobject]@{
        directory = $stepDirectory
        agent = Join-Path $stepDirectory 'PatchAgent.ps1'
        selection = Join-Path $stepDirectory 'selection.json'
    }
}

function Test-PatchVmRequiresReboot {
    param($VMRecord)

    $reboot = Get-PatchValue -InputObject $VMRecord -Names @('reboot') -Default $null
    $rebootStatus = [string](Get-PatchValue -InputObject $reboot -Names @('status') -Default 'NotRequested')
    if ($rebootStatus -eq 'Confirmed') { return $false }
    $explicit = Get-PatchValue -InputObject $reboot -Names @('required', 'pending', 'needsReboot') -Default $null
    if ($null -ne $explicit -and [bool]$explicit) { return $true }

    $agentStatus = Get-PatchValue -InputObject $VMRecord -Names @('agentStatus') -Default $null
    $system = Get-PatchValue -InputObject $agentStatus -Names @('system') -Default $null
    $pending = Get-PatchValue -InputObject (Get-PatchValue -InputObject $system -Names @('pendingReboot') -Default $null) -Names @('isPending') -Default $null
    if ($null -ne $pending) { return [bool]$pending }
    foreach ($update in @(Get-PatchArray -Value (Get-PatchValue -InputObject $VMRecord -Names @('installedUpdates') -Default @()))) {
        $required = Get-PatchValue -InputObject $update -Names @('rebootRequired', 'requiresReboot') -Default $null
        if ($null -ne $required -and [bool]$required) { return $true }
    }
    return $false
}

function Get-PatchGuestAccountScope {
    param($VMRecord, $GuestCredential)

    $userName = ([string](Get-PatchValue $GuestCredential @('UserName') '')).Trim()
    $isLocal = $false
    if ($userName -match '(?i)^(?:\.\\[^\\/@]+|[^\\/@]+)$') {
        $isLocal = $true
    }
    elseif ($userName -match '^(?<machine>[^\\/@]+)\\[^\\/@]+$') {
        $machine = [string]$Matches['machine']
        $vmName = ([string](Get-PatchValue $VMRecord @('vmName') '')).Trim()
        $expectedFqdn = ([string](Get-PatchValue $VMRecord @('expectedFqdn') '')).Trim().TrimEnd('.')
        $shortExpectedFqdn = $expectedFqdn
        $dot = $shortExpectedFqdn.IndexOf('.')
        if ($dot -gt 0) { $shortExpectedFqdn = $shortExpectedFqdn.Substring(0, $dot) }
        $isLocal = [string]::Equals($machine, $vmName, [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($machine, $shortExpectedFqdn, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if ($isLocal) {
        $scope = ([string](Get-PatchValue $VMRecord @('vmId') '')).Trim()
        if ([string]::IsNullOrWhiteSpace($scope)) {
            $scope = ([string](Get-PatchValue $VMRecord @('vmName') '')).Trim()
        }
        return $scope.ToLowerInvariant()
    }
    return ''
}

function Get-PatchGuestAccountKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$GuestCredential,
        [Parameter(Mandatory = $true)]$VMRecord
    )

    $runIdText = ([string](Get-PatchValue $RunState @('runId') '')).Trim()
    if ([string]::IsNullOrWhiteSpace($runIdText)) { throw 'The run has no runId for guest account key generation.' }
    $runId = $null
    try { $runId = ([Guid]$runIdText).ToString('D') } catch { $runId = $runIdText.ToLowerInvariant() }
    $userName = ([string](Get-PatchValue $GuestCredential @('UserName') '')).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($userName)) { throw 'The guest credential has no user name for account key generation.' }
    $scope = Get-PatchGuestAccountScope -VMRecord $VMRecord -GuestCredential $GuestCredential
    $material = 'patch-guest-account-v1|' + $runId + '|' + $userName + '|' + $scope
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    }
    finally {
        $sha.Dispose()
    }
    $hex = New-Object System.Text.StringBuilder
    foreach ($byte in $digest) { [void]$hex.Append($byte.ToString('x2')) }
    return 'sha256:' + $hex.ToString()
}

function Test-PatchGuestAccountSkipped {
    param($RunState, $VMRecord, $GuestCredential)

    $key = Get-PatchGuestAccountKey -RunState $RunState -GuestCredential $GuestCredential -VMRecord $VMRecord
    $rejectedKey = [string](Get-PatchValue $VMRecord @('rejectedGuestAccountKey') '')
    foreach ($entry in @(Get-PatchArray -Value (Get-PatchValue $RunState @('skippedGuestAccounts') @()))) {
        $entryText = [string]$entry
        if ([string]::Equals($entryText, $key, [System.StringComparison]::Ordinal) -or
            (-not [string]::IsNullOrWhiteSpace($rejectedKey) -and [string]::Equals($entryText, $rejectedKey, [System.StringComparison]::Ordinal))) {
            return $true
        }
    }
    return $false
}

function Write-PatchSelectionFile {
    param([string]$Path, $VMRecord)
    $selection = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('selectedUpdates') @()))) {
        $id = [string](Get-PatchValue $item @('updateId', 'UpdateId', 'id') '')
        $revision = Get-PatchValue $item @('revisionNumber', 'RevisionNumber', 'revision') $null
        if ([string]::IsNullOrWhiteSpace($id) -or $null -eq $revision) { continue }
        [void]$selection.Add([ordered]@{ updateId = $id; revisionNumber = [int64]$revision })
    }
    if ($selection.Count -eq 0) { return @() }
    Write-PatchTextAtomic -Path $Path -Text (ConvertTo-Json -InputObject $selection -Depth 5) | Out-Null
    Write-Output -NoEnumerate $selection
}

function Update-PatchVmFromAgentStatus {
    param([string]$Action, $VMRecord, $Status)

    if ($null -eq $Status) { return }
    Set-PatchValue -InputObject $VMRecord -Name 'agentStatus' -Value $Status
    $updates = @(Get-PatchArray -Value (Get-PatchValue -InputObject $Status -Names @('updates') -Default @()))
    if ($Action -eq 'Scan' -or $Action -eq 'Verify') {
        Set-PatchValue -InputObject $VMRecord -Name 'availableUpdates' -Value $updates
        Set-PatchValue -InputObject $VMRecord -Name 'pendingUpdates' -Value $updates
        $system = Get-PatchValue -InputObject $Status -Names @('system') -Default $null
        $pendingReboot = Get-PatchValue -InputObject (Get-PatchValue -InputObject $system -Names @('pendingReboot') -Default $null) -Names @('isPending') -Default $null
        if ($null -ne $pendingReboot) {
            $reboot = Get-PatchValue -InputObject $VMRecord -Names @('reboot') -Default ([pscustomobject]@{})
            $rebootRequired = [bool]$pendingReboot
            $rebootStatus = [string](Get-PatchValue $reboot @('status') 'NotRequested')
            Set-PatchValue -InputObject $reboot -Name 'required' -Value $rebootRequired
            if ($rebootRequired) {
                if ($rebootStatus -eq 'NotRequested' -or $rebootStatus -eq 'SkippedNoReboot' -or $rebootStatus -eq 'Confirmed') {
                    Set-PatchValue -InputObject $reboot -Name 'status' -Value 'Pending'
                }
            }
            elseif ($rebootStatus -ne 'Confirmed') {
                Set-PatchValue -InputObject $reboot -Name 'status' -Value 'NotRequested'
            }
            Set-PatchValue -InputObject $VMRecord -Name 'reboot' -Value $reboot
        }
    }
    if ($Action -eq 'Install') {
        $installedNow = @($updates | Where-Object {
                $result = Get-PatchValue -InputObject (Get-PatchValue -InputObject $_ -Names @('installResult') -Default $null) -Names @('resultCode') -Default $null
                $null -ne $result -and [int]$result -eq 2
        })
        $skipped = @(Get-PatchArray -Value (Get-PatchValue -InputObject $Status -Names @('skipped') -Default @()))
        $installed = @()
        $installedCandidates = @()
        $installedCandidates += @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('installedUpdates') @()))
        $installedCandidates += $installedNow
        foreach ($candidate in $installedCandidates) {
            $candidateId = [string](Get-PatchValue $candidate @('updateId', 'UpdateId', 'id') '')
            $candidateRevision = [string](Get-PatchValue $candidate @('revisionNumber', 'RevisionNumber', 'revision') '')
            $alreadyInstalled = $false
            if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
                foreach ($existing in @($installed)) {
                    if ([string]::Equals([string](Get-PatchValue $existing @('updateId', 'UpdateId', 'id') ''), $candidateId, [System.StringComparison]::OrdinalIgnoreCase) -and
                        [string]::Equals([string](Get-PatchValue $existing @('revisionNumber', 'RevisionNumber', 'revision') ''), $candidateRevision, [System.StringComparison]::Ordinal)) {
                        $alreadyInstalled = $true
                        break
                    }
                }
            }
            if (-not $alreadyInstalled) { $installed += $candidate }
        }
        $mergedSkipped = @()
        $skippedCandidates = @()
        $skippedCandidates += @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('skippedUpdates') @()))
        $skippedCandidates += $skipped
        foreach ($candidate in $skippedCandidates) {
            $candidateId = [string](Get-PatchValue $candidate @('updateId', 'UpdateId', 'id') '')
            $candidateRevision = [string](Get-PatchValue $candidate @('revisionNumber', 'RevisionNumber', 'revision') '')
            $alreadySkipped = $false
            if (-not [string]::IsNullOrWhiteSpace($candidateId)) {
                foreach ($existing in @($mergedSkipped)) {
                    if ([string]::Equals([string](Get-PatchValue $existing @('updateId', 'UpdateId', 'id') ''), $candidateId, [System.StringComparison]::OrdinalIgnoreCase) -and
                        [string]::Equals([string](Get-PatchValue $existing @('revisionNumber', 'RevisionNumber', 'revision') ''), $candidateRevision, [System.StringComparison]::Ordinal)) {
                        $alreadySkipped = $true
                        break
                    }
                }
            }
            if (-not $alreadySkipped) { $mergedSkipped += $candidate }
        }
        Set-PatchValue -InputObject $VMRecord -Name 'installedUpdates' -Value $installed
        Set-PatchValue -InputObject $VMRecord -Name 'skippedUpdates' -Value $mergedSkipped
        Set-PatchValue -InputObject $VMRecord -Name 'pendingUpdates' -Value @($updates | Where-Object {
                $result = Get-PatchValue -InputObject (Get-PatchValue -InputObject $_ -Names @('installResult') -Default $null) -Names @('resultCode') -Default $null
                $null -eq $result -or [int]$result -ne 2
        })
        $aggregateInstall = Get-PatchValue -InputObject $Status -Names @('installResult') -Default $null
        $rebootRequired = [bool](Get-PatchValue -InputObject $aggregateInstall -Names @('rebootRequired') -Default $false)
        $rebootRequired = $rebootRequired -or (@($updates | Where-Object {
                $result = Get-PatchValue -InputObject $_ -Names @('installResult') -Default $null
                [bool](Get-PatchValue -InputObject $result -Names @('rebootRequired') -Default $false)
            }).Count -gt 0)
        if ($rebootRequired) {
            $reboot = Get-PatchValue -InputObject $VMRecord -Names @('reboot') -Default ([pscustomobject]@{})
            Set-PatchValue -InputObject $reboot -Name 'required' -Value $true
            if ([string](Get-PatchValue $reboot @('status') 'NotRequested') -eq 'NotRequested') { Set-PatchValue -InputObject $reboot -Name 'status' -Value 'Pending' }
            Set-PatchValue -InputObject $VMRecord -Name 'reboot' -Value $reboot
        }
    }
}

function Wait-PatchAgent {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$RunState,
        [Parameter(Mandatory = $true)]$Step,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][int]$TimeoutMinutes
    )

    $runId = [Guid](Get-PatchValue $RunState @('runId') '')
    $stepId = [Guid](Get-PatchValue $Step @('stepId') '')
    $mode = [string](Get-PatchValue $Step @('agentMode') '')
    $paths = Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord ([pscustomobject]@{ vmName = 'agent' }) -Step $Step
    $vmName = [string](Get-PatchValue (Get-PatchValue $Context @('VM') $null) @('Name') 'vm')
    $paths = [pscustomobject]@{ status = Join-Path (Get-PatchRunDirectory $RunPath) ('status-{0}-{1}.json' -f (($vmName -replace '[^a-zA-Z0-9_.-]', '_')), $stepId.ToString('D')); selection = $paths.selection; agentLog = Join-Path (Get-PatchRunDirectory $RunPath) ('agent-{0}-{1}.log' -f (($vmName -replace '[^a-zA-Z0-9_.-]', '_')), $stepId.ToString('D')) }
    $deadlineText = [string](Get-PatchValue $Step @('deadlineAt') '')
    $deadline = $null
    if (-not [string]::IsNullOrWhiteSpace($deadlineText)) {
        try { $deadline = [datetime]::Parse($deadlineText).ToUniversalTime() } catch { $deadline = $null }
    }
    if ($null -eq $deadline) {
        $startedText = [string](Get-PatchValue $Step @('startedAt') '')
        $startedAt = $null
        if (-not [string]::IsNullOrWhiteSpace($startedText)) {
            try { $startedAt = [datetime]::Parse($startedText).ToUniversalTime() } catch { $startedAt = $null }
        }
        if ($null -eq $startedAt) { $startedAt = (Get-Date).ToUniversalTime() }
        $deadline = $startedAt.AddMinutes([math]::Max(1, $TimeoutMinutes))
        Set-PatchValue -InputObject $Step -Name 'deadlineAt' -Value $deadline.ToString('o')
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }
    $lastError = $null
    $firstPoll = $true
    while ($firstPoll -or (Get-Date).ToUniversalTime() -lt $deadline) {
        $firstPoll = $false
        $status = $null
        try {
            $statusParameters = @{
                Context = $Context
                RunId = $runId
                StepId = $stepId
                LocalPath = $paths.status
                IgnoreEsxiCertificate = [bool](Get-PatchOption -RunState $RunState -Names @('ignoreEsxiCertificatesForFileTransfers') -Default $false)
            }
            $statusCommand = Get-Command -Name 'Read-GuestStatus' -ErrorAction Stop
            if ($statusCommand.Parameters.ContainsKey('ExpectedMode')) { $statusParameters.ExpectedMode = $mode }
            $status = Read-GuestStatus @statusParameters
        }
        catch {
            $lastError = $_.Exception.Message
        }

        if (Test-PatchCompletedStatus -Status $status -RunId $runId.ToString('D') -StepId $stepId.ToString('D') -Mode $mode) {
            $outcome = [string](Get-PatchValue $status @('outcome') '')
            if ($mode -eq 'Install' -and [string]::Equals($outcome, 'InstallSucceededWithErrors', [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ status = 'CompletedWithErrors'; agentStatus = $status; error = 'The guest agent completed installation with per-update errors.' }
            }
            return [pscustomobject]@{ status = 'Completed'; agentStatus = $status; error = $null }
        }
        if (Test-PatchFailedStatus -Status $status -RunId $runId.ToString('D') -StepId $stepId.ToString('D') -Mode $mode) {
            return [pscustomobject]@{ status = 'Failed'; agentStatus = $status; error = [string](Get-PatchValue $status @('error', 'outcome') 'Guest agent failed.') }
        }
        if ($mode -eq 'Reboot' -and (Test-PatchRebootRequestStatus -Status $status -RunId $runId.ToString('D') -StepId $stepId.ToString('D'))) {
            return [pscustomobject]@{ status = 'RebootRequested'; agentStatus = $status; error = $null }
        }

        $process = @()
        $pidValue = Get-PatchValue $Step @('processId') $null
        if ($null -ne $pidValue) {
            try { $process = @(Get-GuestProcess -Context $Context -Pid ([long]$pidValue)) } catch { $lastError = $_.Exception.Message }
        }
        $terminalProcess = @($process | Where-Object { $null -ne (Get-PatchValue $_ @('ExitCode') $null) -or $null -ne (Get-PatchValue $_ @('EndTime') $null) })
        if ($terminalProcess.Count -gt 0 -and $null -eq $status) {
            return [pscustomobject]@{ status = 'NeedsReview'; agentStatus = $null; error = 'The guest process ended without matching terminal status.json evidence.' }
        }

        if ((Get-Date).ToUniversalTime() -ge $deadline) { break }
        Start-Sleep -Seconds 1
    }
    $timeoutMessage = 'The guest agent did not produce matching terminal status evidence before the timeout.'
    if (-not [string]::IsNullOrWhiteSpace([string]$lastError)) { $timeoutMessage += ' Last read error: ' + (Protect-PatchText $lastError) }
    return [pscustomobject]@{ status = 'NeedsReview'; agentStatus = $null; error = $timeoutMessage }
}

function Invoke-PatchAgentStep {
    param(
        [string]$Action,
        [string]$RunPath,
        $RunState,
        $VMRecord,
        $VM,
        $Context,
        [int]$TimeoutMinutes,
        [switch]$StartOnly
    )

    $round = [int](Get-PatchValue $VMRecord @('currentRound') (Get-PatchValue $RunState @('currentRound') 1))
    $step = Get-PatchStep -VMRecord $VMRecord -Action $Action -Round $round
    $defaultAgentMode = $Action
    if ($Action -eq 'Verify') { $defaultAgentMode = 'Scan' }
    $readOnlyAction = $Action -eq 'Scan' -or $Action -eq 'Verify'
    $agentMode = [string](Get-PatchValue $step @('agentMode') $defaultAgentMode)
    $terminalStatus = [string](Get-PatchValue $step @('status') '')
    $terminal = $terminalStatus -eq 'Completed' -or $terminalStatus -eq 'CompletedWithErrors' -or ($readOnlyAction -and $terminalStatus -eq 'Failed')
    $stepReconciled = Test-PatchMutatingStepReconciled -Step $step -RunId ([string](Get-PatchValue $RunState @('runId') ''))
    if ($terminal -and $stepReconciled) {
        $hasTerminalAgentEvidence = Test-PatchStatusIdentity -Status (Get-PatchValue $step @('agentStatus') $null) -RunId ([string](Get-PatchValue $RunState @('runId') '')) -StepId ([string](Get-PatchValue $step @('stepId') '')) -Mode $agentMode
        if ($readOnlyAction -and $hasTerminalAgentEvidence) {
            $steps = @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('steps') @()))
            $newStep = New-PatchStep -Action $Action -AgentMode $defaultAgentMode -Round $round
            Set-PatchValue -InputObject $VMRecord -Name 'steps' -Value @($steps + $newStep)
            $step = $newStep
            $agentMode = $defaultAgentMode
            $terminalStatus = ''
            $terminal = $false
            $stepReconciled = $false
        }
        elseif (-not ($readOnlyAction -and $terminalStatus -eq 'Failed')) {
            $terminalError = if ($terminalStatus -eq 'CompletedWithErrors') { [string](Get-PatchValue $step @('error') 'The guest agent completed with errors.') } else { $null }
            return [pscustomobject]@{ status = $terminalStatus; step = $step; agentStatus = Get-PatchValue $step @('agentStatus') $null; error = $terminalError }
        }
    }
    if ($terminal -and -not [bool](Get-PatchValue $step @('startAttempted') $false)) {
        return [pscustomobject]@{
            status = 'NeedsReview'
            step = $step
            agentStatus = Get-PatchValue $step @('agentStatus') $null
            error = 'The persisted mutating step has a terminal status without matching terminal agent evidence.'
        }
    }

    if (-not [bool](Get-PatchValue $step @('startAttempted') $false)) {
        $blocker = Get-PatchMutatingStepBlocker -RunState $RunState -VMRecord $VMRecord -CurrentStep $step
        if ($null -ne $blocker) {
            $blockerAction = [string](Get-PatchValue $blocker @('action') 'mutating')
            $blockerRound = [string](Get-PatchValue $blocker @('round') '?')
            return [pscustomobject]@{
                status = 'NeedsReview'
                step = $step
                agentStatus = $null
                error = ('The previous {0} step in round {1} has no matching terminal evidence. Resolve it before starting another mutating action.' -f $blockerAction, $blockerRound)
            }
        }
    }

    $guestPaths = Get-PatchGuestPaths -Context $Context -RunState $RunState -Step $step
    $localPaths = Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $step
    $agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\PatchAgent.ps1'
    if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) { throw ('The guest agent was not found: {0}' -f $agentPath) }

    if (-not [bool](Get-PatchValue $step @('startAttempted') $false)) {
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
        if ($null -ne (Get-Command -Name 'Test-GuestTransferEndpoint' -ErrorAction SilentlyContinue)) {
            Test-GuestTransferEndpoint -Context $Context -IgnoreEsxiCertificate:([bool](Get-PatchOption $RunState @('ignoreEsxiCertificatesForFileTransfers') $false)) | Out-Null
        }
        Send-GuestFile -Context $Context -LocalPath $agentPath -GuestPath $guestPaths.agent -IgnoreEsxiCertificate:([bool](Get-PatchOption $RunState @('ignoreEsxiCertificatesForFileTransfers') $false)) | Out-Null
        $selectionPath = $null
        if ($Action -eq 'Install') {
            $selection = Write-PatchSelectionFile -Path $localPaths.selection -VMRecord $VMRecord
            Send-GuestFile -Context $Context -LocalPath $localPaths.selection -GuestPath $guestPaths.selection -IgnoreEsxiCertificate:([bool](Get-PatchOption $RunState @('ignoreEsxiCertificatesForFileTransfers') $false)) | Out-Null
            $selectionPath = $guestPaths.selection
            Set-PatchValue -InputObject $step -Name 'selection' -Value $selection
        }

        # Persist before Start-GuestAgent. A lost start response must never cause a second install or reboot.
        Set-PatchValue -InputObject $step -Name 'startAttempted' -Value ([bool]$true)
        Set-PatchValue -InputObject $step -Name 'status' -Value 'StartPending'
        Set-PatchValue -InputObject $step -Name 'startedAt' -Value (Get-PatchUtcNow)
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
        try {
            $pidValue = Start-GuestAgent -Context $Context -GuestAgentPath $guestPaths.agent -Mode $agentMode -RunId ([Guid](Get-PatchValue $RunState @('runId') '')) -StepId ([Guid](Get-PatchValue $step @('stepId') '')) -SelectionPath $selectionPath
            Set-PatchValue -InputObject $step -Name 'processId' -Value ([int64]$pidValue)
            Set-PatchValue -InputObject $step -Name 'status' -Value 'Started'
            Save-PatchDecision -RunPath $RunPath -RunState $RunState
        }
        catch {
            Set-PatchValue -InputObject $step -Name 'status' -Value 'NeedsReview'
            Set-PatchValue -InputObject $step -Name 'error' -Value (Protect-PatchText $_.Exception.Message)
            Save-PatchDecision -RunPath $RunPath -RunState $RunState
            return [pscustomobject]@{ status = 'NeedsReview'; step = $step; agentStatus = $null; error = $_.Exception.Message }
        }
    }

    if ($StartOnly) {
        return [pscustomobject]@{ status = 'Started'; step = $step; agentStatus = Get-PatchValue $step @('agentStatus') $null; error = $null }
    }

    $waitResult = Wait-PatchAgent -Context $Context -RunState $RunState -Step $step -RunPath $RunPath -TimeoutMinutes $TimeoutMinutes
    try {
        $guestLogPath = Join-Path (Get-PatchGuestPaths -Context $Context -RunState $RunState -Step $step).directory 'agent.log'
        $agentLogLocalPath = (Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $step).agentLog
        Receive-GuestFile -Context $Context -GuestPath $guestLogPath -LocalPath $agentLogLocalPath -IgnoreEsxiCertificate:([bool](Get-PatchOption $RunState @('ignoreEsxiCertificatesForFileTransfers') $false)) | Out-Null
    }
    catch {
        # Terminal status remains authoritative if an agent log cannot be downloaded.
    }
    Set-PatchValue -InputObject $step -Name 'status' -Value $waitResult.status
    Set-PatchValue -InputObject $step -Name 'agentStatus' -Value $waitResult.agentStatus
    Update-PatchVmFromAgentStatus -Action $Action -VMRecord $VMRecord -Status $waitResult.agentStatus
    if ($null -ne $waitResult.error) { Set-PatchValue -InputObject $step -Name 'error' -Value (Protect-PatchText $waitResult.error) }
    if ($waitResult.status -eq 'Completed' -or $waitResult.status -eq 'CompletedWithErrors' -or $waitResult.status -eq 'Failed') { Set-PatchValue -InputObject $step -Name 'finishedAt' -Value (Get-PatchUtcNow) }
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    return [pscustomobject]@{ status = $waitResult.status; step = $step; agentStatus = $waitResult.agentStatus; error = $waitResult.error }
}

function Invoke-PatchRebootConfirmation {
    param(
        [string]$RunPath,
        $RunState,
        $VMRecord,
        $Server,
        $GuestCredential,
        $Step,
        $InitialVM,
        $InitialContext,
        [int]$TimeoutMinutes
    )

    $vmName = [string](Get-PatchValue $VMRecord @('vmName') '')
    $expectedFqdn = [string](Get-PatchValue $VMRecord @('expectedFqdn') '')
    $savedId = [string](Get-PatchValue $VMRecord @('vmId') '')
    $baseline = [string](Get-PatchValue $Step @('baselineBootTime') '')
    $baselineDate = $null
    try { $baselineDate = [datetime]::Parse($baseline).ToUniversalTime() } catch { }

    $deadlineText = [string](Get-PatchValue $Step @('confirmationDeadlineAt') '')
    $deadline = $null
    if (-not [string]::IsNullOrWhiteSpace($deadlineText)) {
        try { $deadline = [datetime]::Parse($deadlineText).ToUniversalTime() } catch { $deadline = $null }
    }
    if ($null -eq $deadline) {
        $deadline = (Get-Date).ToUniversalTime().AddMinutes([math]::Max(1, $TimeoutMinutes))
        Set-PatchValue -InputObject $Step -Name 'confirmationDeadlineAt' -Value $deadline.ToString('o')
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }

    $lastError = $null
    $runIdText = [string](Get-PatchValue $RunState @('runId') '')
    $stepIdText = [string](Get-PatchValue $Step @('stepId') '')
    $failedResult = Get-PatchRebootFailureResult -Step $Step -RunId $runIdText -StepId $stepIdText
    if ($null -ne $failedResult) { return $failedResult }
    $hasRebootEvidence = Test-PatchRebootRequestStatus -Status (Get-PatchValue $Step @('agentStatus') $null) -RunId $runIdText -StepId $stepIdText
    $firstAttempt = $true
    $firstPoll = $true
    while ($firstPoll -or (Get-Date).ToUniversalTime() -lt $deadline) {
        $firstPoll = $false
        $vm = $null
        $context = $null
        try {
            if ($firstAttempt -and $null -ne $InitialVM) {
                $vm = $InitialVM
            }
            else {
                $vm = Get-PatchVM -Server $Server -Name $vmName -ExpectedFqdn $expectedFqdn -SavedId $savedId
            }
            if ($firstAttempt -and $null -ne $InitialContext) {
                $context = $InitialContext
            }
            else {
                $context = Get-GuestContext -VM $vm -GuestCredential $GuestCredential
            }
            Assert-PatchGuestIdentity -VMRecord $VMRecord -VM $vm -Context $context
            [void](Read-PatchRebootEvidence -RunPath $RunPath -RunState $RunState -Step $Step -Context $context)
            $failedResult = Get-PatchRebootFailureResult -Step $Step -RunId $runIdText -StepId $stepIdText
            if ($null -ne $failedResult) { return $failedResult }
            $hasRebootEvidence = $hasRebootEvidence -or (Test-PatchRebootRequestStatus -Status (Get-PatchValue $Step @('agentStatus') $null) -RunId $runIdText -StepId $stepIdText)
            if ($hasRebootEvidence -and (Get-PatchToolsRunning -Context $context)) {
                $currentBoot = [string](Read-GuestBootTime -Context $context)
                $currentDate = $null
                try { $currentDate = [datetime]::Parse($currentBoot).ToUniversalTime() } catch { }
                if ($null -ne $baselineDate -and $null -ne $currentDate -and $currentDate -gt $baselineDate) {
                    Set-PatchValue -InputObject $Step -Name 'status' -Value 'Confirmed'
                    Set-PatchValue -InputObject $Step -Name 'finishedAt' -Value (Get-PatchUtcNow)
                    Set-PatchValue -InputObject $Step -Name 'confirmedBootTime' -Value $currentBoot
                    Save-PatchDecision -RunPath $RunPath -RunState $RunState
                    return [pscustomobject]@{
                        status = 'Confirmed'
                        step = $Step
                        agentStatus = Get-PatchValue $Step @('agentStatus') $null
                        error = $null
                    }
                }
            }
        }
        catch {
            $lastError = Protect-PatchText $_.Exception.Message
        }

        $firstAttempt = $false
        if ((Get-Date).ToUniversalTime() -ge $deadline) { break }
        Start-Sleep -Seconds 5
    }

    $timeoutMessage = 'Matching RebootRequested status evidence, VMware Tools, and a strictly newer guest boot time were not observed before the reboot confirmation deadline.'
    if (-not [string]::IsNullOrWhiteSpace([string]$lastError)) { $timeoutMessage += ' Last read error: ' + $lastError }
    Set-PatchValue -InputObject $Step -Name 'status' -Value 'PendingRebootConfirmation'
    Set-PatchValue -InputObject $Step -Name 'error' -Value $timeoutMessage
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    return [pscustomobject]@{
        status = 'PendingRebootConfirmation'
        step = $Step
        agentStatus = Get-PatchValue $Step @('agentStatus') $null
        error = $timeoutMessage
    }
}

function Read-PatchRebootEvidence {
    param([string]$RunPath, $RunState, $Step, $Context)

    $runId = [Guid](Get-PatchValue $RunState @('runId') '')
    $stepId = [Guid](Get-PatchValue $Step @('stepId') '')
    $mode = 'Reboot'
    $vmName = [string](Get-PatchValue (Get-PatchValue $Context @('VM') $null) @('Name') 'vm')
    $safeName = $vmName -replace '[^a-zA-Z0-9_.-]', '_'
    $localPath = Join-Path (Get-PatchRunDirectory $RunPath) ('status-{0}-{1}.json' -f $safeName, $stepId.ToString('D'))
    try {
        $statusParameters = @{
            Context = $Context
            RunId = $runId
            StepId = $stepId
            LocalPath = $localPath
            IgnoreEsxiCertificate = [bool](Get-PatchOption -RunState $RunState -Names @('ignoreEsxiCertificatesForFileTransfers') -Default $false)
        }
        $statusCommand = Get-Command -Name 'Read-GuestStatus' -ErrorAction Stop
        if ($statusCommand.Parameters.ContainsKey('ExpectedMode')) { $statusParameters.ExpectedMode = $mode }
        $status = Read-GuestStatus @statusParameters
        if (Test-PatchFailedStatus -Status $status -RunId $runId.ToString('D') -StepId $stepId.ToString('D') -Mode $mode) {
            $errorMessage = [string](Get-PatchValue $status @('error', 'outcome') 'Guest agent failed.')
            if ([string]::IsNullOrWhiteSpace($errorMessage)) { $errorMessage = 'Guest agent failed.' }
            Set-PatchValue -InputObject $Step -Name 'agentStatus' -Value $status
            Set-PatchValue -InputObject $Step -Name 'status' -Value 'Failed'
            Set-PatchValue -InputObject $Step -Name 'error' -Value (Protect-PatchText $errorMessage)
            Set-PatchValue -InputObject $Step -Name 'finishedAt' -Value (Get-PatchUtcNow)
            Save-PatchDecision -RunPath $RunPath -RunState $RunState
            return $true
        }
        if (Test-PatchRebootRequestStatus -Status $status -RunId $runId.ToString('D') -StepId $stepId.ToString('D')) {
            Set-PatchValue -InputObject $Step -Name 'agentStatus' -Value $status
            Set-PatchValue -InputObject $Step -Name 'requestEvidence' -Value $status
            Set-PatchValue -InputObject $Step -Name 'status' -Value 'PendingRebootConfirmation'
            Save-PatchDecision -RunPath $RunPath -RunState $RunState
            return $true
        }
    }
    catch {
        # A missing or transient status read does not authorize a resend. Boot and
        # VMware Tools observation remains the confirmation gate.
    }
    return $false
}

function Invoke-PatchRebootStep {
    param(
        [string]$RunPath,
        $RunState,
        $VMRecord,
        $VM,
        $Context,
        $Server,
        $GuestCredential,
        [int]$TimeoutMinutes,
        [switch]$StartOnly
    )

    $round = [int](Get-PatchValue $VMRecord @('currentRound') (Get-PatchValue $RunState @('currentRound') 1))
    $step = Get-PatchStep -VMRecord $VMRecord -Action 'Reboot' -Round $round
    $baseline = [string](Get-PatchValue $step @('baselineBootTime') '')
    if ([string]::IsNullOrWhiteSpace($baseline)) {
        $baseline = [string](Read-GuestBootTime -Context $Context)
        if ([string]::IsNullOrWhiteSpace($baseline)) { throw 'A baseline guest boot time could not be read.' }
        Set-PatchValue -InputObject $step -Name 'baselineBootTime' -Value $baseline
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }

    if (-not [bool](Get-PatchValue $step @('startAttempted') $false)) {
        $agentResult = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -VM $VM -Context $Context -TimeoutMinutes $TimeoutMinutes -StartOnly:$StartOnly
        if ($agentResult.status -eq 'NeedsReview' -or $agentResult.status -eq 'Failed') {
            return $agentResult
        }
        $step = $agentResult.step
    }
    if ($StartOnly) {
        return [pscustomobject]@{ status = 'Started'; step = $step; agentStatus = Get-PatchValue $step @('agentStatus') $null; error = $null }
    }

    $runIdText = [string](Get-PatchValue $RunState @('runId') '')
    $stepIdText = [string](Get-PatchValue $step @('stepId') '')
    $hasRebootEvidence = Test-PatchRebootRequestStatus -Status (Get-PatchValue $step @('agentStatus') $null) -RunId $runIdText -StepId $stepIdText
    if (-not $hasRebootEvidence) {
        [void](Read-PatchRebootEvidence -RunPath $RunPath -RunState $RunState -Step $step -Context $Context)
        $failedResult = Get-PatchRebootFailureResult -Step $step -RunId $runIdText -StepId $stepIdText
        if ($null -ne $failedResult) { return $failedResult }
        $hasRebootEvidence = Test-PatchRebootRequestStatus -Status (Get-PatchValue $step @('agentStatus') $null) -RunId $runIdText -StepId $stepIdText
    }
    if ($hasRebootEvidence -and [string]::Equals([string](Get-PatchValue $step @('status') ''), 'RebootRequested', [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-PatchValue -InputObject $step -Name 'requestEvidence' -Value (Get-PatchValue $step @('agentStatus') $null)
        Set-PatchValue -InputObject $step -Name 'status' -Value 'PendingRebootConfirmation'
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }
    elseif (-not $hasRebootEvidence -and -not [string]::Equals([string](Get-PatchValue $step @('status') ''), 'Confirmed', [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-PatchValue -InputObject $step -Name 'status' -Value 'PendingRebootConfirmation'
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }
    return (Invoke-PatchRebootConfirmation -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Server $Server -GuestCredential $GuestCredential -Step $step -InitialVM $VM -InitialContext $Context -TimeoutMinutes $TimeoutMinutes)
}

function Invoke-PatchVmAction {
    param(
        [string]$Action,
        [string]$RunPath,
        $RunState,
        $VMRecord,
        $Server,
        $GuestCredential,
        [switch]$StartOnly
    )

    $vmName = [string](Get-PatchValue $VMRecord @('vmName') '')
    $expectedFqdn = [string](Get-PatchValue $VMRecord @('expectedFqdn') '')
    $savedId = [string](Get-PatchValue $VMRecord @('vmId') '')
    $rebootStep = $null
    $rebootInFlight = $false
    if ($Action -eq 'Reboot') {
        $rebootStep = Get-PatchStep -VMRecord $VMRecord -Action 'Reboot' -Round ([int](Get-PatchValue $VMRecord @('currentRound') 1))
        $rebootInFlight = [bool](Get-PatchValue $rebootStep @('startAttempted') $false) -and [string](Get-PatchValue $rebootStep @('status') '') -ne 'Confirmed'
    }
    try {
        $vm = Get-PatchVM -Server $Server -Name $vmName -ExpectedFqdn $expectedFqdn -SavedId $savedId
    }
    catch {
        if ($rebootInFlight) {
            if ($StartOnly) {
                return [pscustomobject]@{ status = 'Started'; error = $null; step = $rebootStep; agentStatus = Get-PatchValue $VMRecord @('agentStatus') $null }
            }
            return (Invoke-PatchRebootConfirmation -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Server $Server -GuestCredential $GuestCredential -Step $rebootStep -InitialVM $null -InitialContext $null -TimeoutMinutes (Get-PatchLimit $RunState 'rebootConfirmationTimeoutMinutes' 30))
        }
        throw
    }
    $actualId = Get-PatchVmId -VM $vm
    if (-not [string]::IsNullOrWhiteSpace($savedId) -and -not [string]::IsNullOrWhiteSpace($actualId) -and $savedId -ne $actualId) {
        throw ('Saved VM ID {0} resolved to {1}.' -f $savedId, $actualId)
    }
    if ([string]::IsNullOrWhiteSpace($savedId) -and -not [string]::IsNullOrWhiteSpace($actualId)) {
        Set-PatchValue -InputObject $VMRecord -Name 'vmId' -Value $actualId
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }

    $context = $null
    try {
        $context = Get-GuestContext -VM $vm -GuestCredential $GuestCredential
    }
    catch {
        if ($Action -eq 'Reboot' -and [bool](Get-PatchValue (Get-PatchStep -VMRecord $VMRecord -Action 'Reboot' -Round ([int](Get-PatchValue $VMRecord @('currentRound') 1))) @('startAttempted') $false)) {
            if ($StartOnly) {
                return [pscustomobject]@{ status = 'Started'; error = $null; step = $rebootStep; agentStatus = Get-PatchValue $VMRecord @('agentStatus') $null }
            }
            return (Invoke-PatchRebootConfirmation -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Server $Server -GuestCredential $GuestCredential -Step $rebootStep -InitialVM $vm -InitialContext $null -TimeoutMinutes (Get-PatchLimit $RunState 'rebootConfirmationTimeoutMinutes' 30))
        }
        throw
    }
    Assert-PatchGuestIdentity -VMRecord $VMRecord -VM $vm -Context $context

    $agentStatus = Get-PatchValue $VMRecord @('agentStatus') $null
    if ($Action -eq 'Install' -or $Action -eq 'Reboot') {
        $membership = Get-PatchClusterMembership -Context $context -Status $agentStatus
        if ([string]::IsNullOrWhiteSpace($membership)) { throw 'Cluster membership is unknown; the action is blocked.' }
        if (-not [string]::Equals($membership, 'NotMember', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('The action is blocked because cluster membership is {0}.' -f $membership)
        }
    }

    if ($Action -eq 'Reboot') {
        return (Invoke-PatchRebootStep -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -VM $vm -Context $context -Server $Server -GuestCredential $GuestCredential -TimeoutMinutes (Get-PatchLimit $RunState 'rebootConfirmationTimeoutMinutes' 30) -StartOnly:$StartOnly)
    }
    $timeoutMinutes = Get-PatchLimit $RunState 'scanTimeoutMinutes' 30
    if ($Action -eq 'Install') { $timeoutMinutes = Get-PatchLimit $RunState 'installTimeoutMinutes' 180 }
    return (Invoke-PatchAgentStep -Action $Action -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -VM $vm -Context $context -TimeoutMinutes $timeoutMinutes -StartOnly:$StartOnly)
}

function Add-PatchVmResult {
    param(
        [string]$RunPath,
        $RunState,
        $VMRecord,
        [string]$VMName,
        [string]$Action,
        $VmResult,
        [ref]$RebootBarrier
    )

    $vmStatus = [string](Get-PatchValue $VmResult @('status') 'NeedsReview')
    Set-PatchValue -InputObject $VMRecord -Name 'status' -Value $vmStatus
    if ($null -ne (Get-PatchValue $VmResult @('agentStatus') $null)) {
        Set-PatchValue -InputObject $VMRecord -Name 'agentStatus' -Value (Get-PatchValue $VmResult @('agentStatus') $null)
    }
    if ($Action -eq 'Reboot') {
        $reboot = Get-PatchValue $VMRecord @('reboot') ([pscustomobject]@{})
        Set-PatchValue -InputObject $reboot -Name 'status' -Value $vmStatus
        if ($vmStatus -eq 'Confirmed') {
            Set-PatchValue -InputObject $reboot -Name 'confirmedBootTime' -Value (Get-PatchValue (Get-PatchValue $VmResult @('step') $null) @('confirmedBootTime') $null)
        }
        else {
            # An unconfirmed reboot stops the next reboot batches (plan: step 5).
            $RebootBarrier.Value = $true
        }
    }
    if ($vmStatus -eq 'Failed' -or $vmStatus -eq 'NeedsReview' -or $vmStatus -eq 'CompletedWithErrors') {
        $errorMessage = [string](Get-PatchValue $VmResult @('error') '')
        if (-not [string]::IsNullOrWhiteSpace($errorMessage)) {
            $errorMessage = Protect-PatchText $errorMessage
            $errorCode = if ($vmStatus -eq 'Failed') { 'PatchActionFailed' } elseif ($vmStatus -eq 'CompletedWithErrors') { 'PatchActionPartialFailure' } else { 'PatchActionNeedsReview' }
            $vmErrors = @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('errors') @()))
            $duplicateError = @($vmErrors | Where-Object {
                    [string]::Equals([string](Get-PatchValue $_ @('code') ''), $errorCode, [System.StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string](Get-PatchValue $_ @('message') ''), $errorMessage, [System.StringComparison]::Ordinal)
                }).Count -gt 0
            if (-not $duplicateError) {
                $vmErrors += [pscustomobject]@{ code = $errorCode; message = $errorMessage; step = $Action }
                Set-PatchValue -InputObject $VMRecord -Name 'errors' -Value $vmErrors
                Set-PatchValue -InputObject $VMRecord -Name 'errorLinks' -Value @('errors.log')
                $errorRecord = Write-PatchError -RunPath $RunPath -Message $errorMessage -VMName $VMName -Step $Action -Code $errorCode
                $runErrors = @(Get-PatchArray -Value (Get-PatchValue $RunState @('errors') @()))
                $runErrors += $errorRecord
                Set-PatchValue -InputObject $RunState -Name 'errors' -Value $runErrors
            }
        }
    }
    Set-PatchValue -InputObject $VMRecord -Name 'lastProcessedAction' -Value $Action
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    $eventLevel = 'WARN'
    if ($vmStatus -eq 'Completed' -or $vmStatus -eq 'Confirmed') { $eventLevel = 'INFO' }
    Write-PatchEvent -RunPath $RunPath -Message ('Action result: {0}' -f $vmStatus) -VMName $VMName -Step $Action -Level $eventLevel
    return [pscustomobject]@{ vmName = $VMName; status = $vmStatus; error = Get-PatchValue $VmResult @('error') $null }
}

function Add-PatchVmFailure {
    param(
        [string]$RunPath,
        $RunState,
        $VMRecord,
        [string]$VMName,
        [string]$Action,
        [string]$ExceptionMessage,
        $GuestCredential,
        [ref]$RebootBarrier
    )

    $message = Protect-PatchText $ExceptionMessage
    $code = Get-PatchErrorCode -Message $message
    Set-PatchValue -InputObject $VMRecord -Name 'status' -Value $code
    if ($code -eq 'GuestCredentialRejected' -and $null -ne $GuestCredential) {
        $rejectedKey = Get-PatchGuestAccountKey -RunState $RunState -GuestCredential $GuestCredential -VMRecord $VMRecord
        $rejectedScope = Get-PatchGuestAccountScope -VMRecord $VMRecord -GuestCredential $GuestCredential
        Set-PatchValue -InputObject $VMRecord -Name 'rejectedGuestAccountKey' -Value $rejectedKey
        Set-PatchValue -InputObject $VMRecord -Name 'rejectedGuestAccountIsLocal' -Value ([bool](-not [string]::IsNullOrWhiteSpace([string]$rejectedScope)))
    }
    if ($Action -eq 'Reboot') { $RebootBarrier.Value = $true }
    $vmErrors = @(Get-PatchArray -Value (Get-PatchValue $VMRecord @('errors') @()))
    $vmErrors += [pscustomobject]@{ code = $code; message = $message; step = $Action }
    Set-PatchValue -InputObject $VMRecord -Name 'errors' -Value $vmErrors
    Set-PatchValue -InputObject $VMRecord -Name 'errorLinks' -Value @('errors.log')
    $errorRecord = Write-PatchError -RunPath $RunPath -Message $message -VMName $VMName -Step $Action -Code $code
    $runErrors = @(Get-PatchArray -Value (Get-PatchValue $RunState @('errors') @()))
    $runErrors += $errorRecord
    Set-PatchValue -InputObject $RunState -Name 'errors' -Value $runErrors
    Set-PatchValue -InputObject $VMRecord -Name 'lastProcessedAction' -Value $Action
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    Write-PatchEvent -RunPath $RunPath -Message $message -VMName $VMName -Step $Action -Level 'ERROR'
    return [pscustomobject]@{ vmName = $VMName; status = $code; error = $message }
}

function Invoke-PatchAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install', 'Reboot', 'Verify')][string]$Action,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$VCenterCredential,
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$GuestCredential
    )

    Register-PatchCredential -Credential $VCenterCredential
    Register-PatchCredential -Credential $GuestCredential
    $run = $null
    $resultRows = @()
    try {
        $run = Read-PatchRun -RunPath $RunPath
        if ($null -eq (Get-Command -Name 'Connect-PatchVCenter' -ErrorAction SilentlyContinue)) {
            $adapterPath = Join-Path $PSScriptRoot 'GuestOps.ps1'
            if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
                throw ('The Guest Operations adapter was not found: {0}' -f $adapterPath)
            }
            . $adapterPath
        }
        $runFile = Get-PatchRunJsonPath -RunPath $RunPath
        $runDirectory = Get-PatchRunDirectory -RunPath $RunPath
        $wasResumed = -not [string]::Equals([string](Get-PatchValue $run @('status') 'Created'), 'Created', [System.StringComparison]::OrdinalIgnoreCase)
        $startMessage = 'Patch action started.'
        if ($wasResumed) { $startMessage = 'Patch action resumed.' }
        Write-PatchEvent -RunPath $runFile -Message $startMessage -Step $Action
        Set-PatchValue -InputObject $run -Name 'status' -Value 'Running'
        Set-PatchValue -InputObject $run -Name 'currentAction' -Value $Action
        $vmRecords = @(Get-PatchArray -Value (Get-PatchValue $run @('vms') @()))
        foreach ($vmRecord in $vmRecords) {
            Set-PatchValue -InputObject $vmRecord -Name 'currentAction' -Value $null
            Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $null
        }
        Save-PatchDecision -RunPath $runFile -RunState $run
        Write-PatchSummary -RunPath $runFile -RunState $run

        $serverName = [string](Get-PatchValue $run @('vCenter') '')
        if ([string]::IsNullOrWhiteSpace($serverName)) { throw 'The run has no vCenter server name.' }
        $server = Connect-PatchVCenter -ServerName $serverName -Credential $VCenterCredential -IgnoreVCenterCertificate:([bool](Get-PatchOption $run @('ignoreVCenterCertificate') $false))

        $rebootBarrier = $false
        $rejectedAccountKeys = @{}
        $workLimit = 1
        if ($Action -eq 'Scan' -or $Action -eq 'Verify') {
            $workLimit = [int](Get-PatchOption $run @('scanConcurrency') 3)
        }
        elseif ($Action -eq 'Install') {
            $workLimit = [int](Get-PatchOption $run @('installConcurrency') 3)
        }
        elseif ($Action -eq 'Reboot') {
            $workLimit = [int](Get-PatchOption $run @('rebootBatchSize') 1)
        }
        if ($workLimit -lt 1) { $workLimit = 1 }
        for ($batchStart = 0; $batchStart -lt $vmRecords.Count; $batchStart += $workLimit) {
            $batchEnd = [Math]::Min($vmRecords.Count, $batchStart + $workLimit)

            # Start every VM in this bounded batch first. The second pass waits for
            # terminal evidence, so at most workLimit guest processes are active.
            $batchWork = @()
            for ($recordIndex = $batchStart; $recordIndex -lt $batchEnd; $recordIndex++) {
                $vmRecord = $vmRecords[$recordIndex]
                if ($Action -eq 'Reboot' -and $rebootBarrier) {
                    $barrierStatus = 'PendingRebootBarrier'
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value $barrierStatus
                    Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $Action
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    $resultRows += [pscustomobject]@{ vmName = [string](Get-PatchValue $vmRecord @('vmName') ''); status = $barrierStatus; error = $null }
                    continue
                }

                $vmName = [string](Get-PatchValue $vmRecord @('vmName') '')
                if (Test-PatchGuestAccountSkipped -RunState $run -VMRecord $vmRecord -GuestCredential $GuestCredential) {
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value 'SkippedGuestAccount'
                    Set-PatchValue -InputObject $vmRecord -Name 'errorLinks' -Value @('errors.log')
                    Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $Action
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    Write-PatchEvent -RunPath $runFile -Message 'Skipped because this guest account is recorded as skipped for this VM.' -VMName $vmName -Step $Action -Level 'WARN'
                    $resultRows += [pscustomobject]@{ vmName = $vmName; status = 'SkippedGuestAccount'; error = 'GuestCredentialSkipped' }
                    continue
                }
                $priorStatus = [string](Get-PatchValue $vmRecord @('status') '')
                $currentAccountKey = Get-PatchGuestAccountKey -RunState $run -GuestCredential $GuestCredential -VMRecord $vmRecord
                $rejectedInThisAction = $rejectedAccountKeys.ContainsKey($currentAccountKey)
                if ($priorStatus -eq 'GuestCredentialRejected' -or $priorStatus -eq 'GuestCredentialRejectedPendingDecision' -or $priorStatus -eq 'SkippedAccountPendingDecision' -or $rejectedInThisAction) {
                    $pendingStatus = 'GuestCredentialRejectedPendingDecision'
                    if ($priorStatus -eq 'SkippedAccountPendingDecision') { $pendingStatus = $priorStatus }
                    if ($rejectedInThisAction) {
                        Set-PatchValue -InputObject $vmRecord -Name 'rejectedGuestAccountKey' -Value $currentAccountKey
                        $scope = Get-PatchGuestAccountScope -VMRecord $vmRecord -GuestCredential $GuestCredential
                        Set-PatchValue -InputObject $vmRecord -Name 'rejectedGuestAccountIsLocal' -Value ([bool](-not [string]::IsNullOrWhiteSpace([string]$scope)))
                        $pendingStatus = 'SkippedAccountPendingDecision'
                    }
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value $pendingStatus
                    Set-PatchValue -InputObject $vmRecord -Name 'errorLinks' -Value @('errors.log')
                    Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $Action
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    Write-PatchEvent -RunPath $runFile -Message 'Paused until the operator chooses Retry, Skip account, or Stop for the rejected guest account.' -VMName $vmName -Step $Action -Level 'WARN'
                    $resultRows += [pscustomobject]@{ vmName = $vmName; status = $pendingStatus; error = 'GuestCredentialRejected' }
                    continue
                }
                if ($Action -eq 'Install' -and @(Get-PatchArray -Value (Get-PatchValue $vmRecord @('selectedUpdates') @())).Count -eq 0) {
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value 'SkippedNoSelection'
                    $skipRound = [int](Get-PatchValue $vmRecord @('currentRound') (Get-PatchValue $run @('currentRound') 1))
                    $skippedHistory = @(Get-PatchArray -Value (Get-PatchValue $vmRecord @('skippedUpdates') @()))
                    $hasRoundSkip = @($skippedHistory | Where-Object {
                            [string]::Equals([string](Get-PatchValue $_ @('reason') ''), 'No updates selected.', [System.StringComparison]::Ordinal) -and
                            [int](Get-PatchValue $_ @('round') 0) -eq $skipRound
                        }).Count -gt 0
                    if (-not $hasRoundSkip) {
                        $skippedHistory += [pscustomobject]@{ reason = 'No updates selected.'; round = $skipRound }
                    }
                    Set-PatchValue -InputObject $vmRecord -Name 'skippedUpdates' -Value $skippedHistory
                    Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $Action
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    Write-PatchEvent -RunPath $runFile -Message 'Installation skipped because no updates were selected for this VM.' -VMName $vmName -Step $Action
                    $resultRows += [pscustomobject]@{ vmName = $vmName; status = 'SkippedNoSelection'; error = $null }
                    continue
                }
                if ($Action -eq 'Reboot' -and -not (Test-PatchVmRequiresReboot -VMRecord $vmRecord)) {
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value 'SkippedNoReboot'
                    Set-PatchValue -InputObject $vmRecord -Name 'reboot' -Value ([pscustomobject]@{ status = 'SkippedNoReboot'; required = $false; baselineBootTime = $null; requestEvidence = $null; confirmedBootTime = $null })
                    Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $Action
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    Write-PatchEvent -RunPath $runFile -Message 'Reboot skipped because no pending reboot was recorded.' -VMName $vmName -Step $Action
                    $resultRows += [pscustomobject]@{ vmName = $vmName; status = 'SkippedNoReboot'; error = $null }
                    continue
                }
                Set-PatchValue -InputObject $vmRecord -Name 'currentAction' -Value $Action
                Save-PatchDecision -RunPath $runFile -RunState $run
                try {
                    $startResult = Invoke-PatchVmAction -Action $Action -RunPath $runFile -RunState $run -VMRecord $vmRecord -Server $server -GuestCredential $GuestCredential -StartOnly
                    $startStatus = [string](Get-PatchValue $startResult @('status') 'NeedsReview')
                    if ($startStatus -eq 'NeedsReview' -or $startStatus -eq 'Failed' -or $startStatus -eq 'CompletedWithErrors' -or $startStatus -eq 'PendingRebootConfirmation') {
                        $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -VMName $vmName -Action $Action -VmResult $startResult -RebootBarrier ([ref]$rebootBarrier)
                    }
                    else {
                        Set-PatchValue -InputObject $vmRecord -Name 'status' -Value 'Started'
                        Save-PatchDecision -RunPath $runFile -RunState $run
                        $batchWork += [pscustomobject]@{ vmRecord = $vmRecord; vmName = $vmName }
                    }
                }
                catch {
                    $failureResult = Add-PatchVmFailure -RunPath $runFile -RunState $run -VMRecord $vmRecord -VMName $vmName -Action $Action -ExceptionMessage $_.Exception.Message -GuestCredential $GuestCredential -RebootBarrier ([ref]$rebootBarrier)
                    if ([string]::Equals([string](Get-PatchValue $failureResult @('status') ''), 'GuestCredentialRejected', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rejectedKey = [string](Get-PatchValue $vmRecord @('rejectedGuestAccountKey') '')
                        if (-not [string]::IsNullOrWhiteSpace($rejectedKey)) { $rejectedAccountKeys[$rejectedKey] = $true }
                    }
                    $resultRows += $failureResult
                }
            }

            # Wait for every started VM in this batch before opening another batch.
            foreach ($work in @($batchWork)) {
                $vmRecord = $work.vmRecord
                $vmName = [string](Get-PatchValue $work @('vmName') '')
                try {
                    $vmResult = Invoke-PatchVmAction -Action $Action -RunPath $runFile -RunState $run -VMRecord $vmRecord -Server $server -GuestCredential $GuestCredential
                    $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -VMName $vmName -Action $Action -VmResult $vmResult -RebootBarrier ([ref]$rebootBarrier)
                }
                catch {
                    $failureResult = Add-PatchVmFailure -RunPath $runFile -RunState $run -VMRecord $vmRecord -VMName $vmName -Action $Action -ExceptionMessage $_.Exception.Message -GuestCredential $GuestCredential -RebootBarrier ([ref]$rebootBarrier)
                    if ([string]::Equals([string](Get-PatchValue $failureResult @('status') ''), 'GuestCredentialRejected', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $rejectedKey = [string](Get-PatchValue $vmRecord @('rejectedGuestAccountKey') '')
                        if (-not [string]::IsNullOrWhiteSpace($rejectedKey)) { $rejectedAccountKeys[$rejectedKey] = $true }
                    }
                    $resultRows += $failureResult
                }
            }
        }

        $needsReview = @($resultRows | Where-Object { $_.status -eq 'NeedsReview' -or $_.status -eq 'PendingRebootConfirmation' -or $_.status -eq 'PendingRebootBarrier' -or $_.status -eq 'GuestCredentialRejectedPendingDecision' -or $_.status -eq 'SkippedAccountPendingDecision' }).Count -gt 0
        $hasErrors = @($resultRows | Where-Object { $_.status -match 'Rejected|Failed|Blocked|Error|Mismatch' -or $_.status -eq 'PatchActionFailed' }).Count -gt 0
        if ($needsReview) { Set-PatchValue -InputObject $run -Name 'status' -Value 'NeedsReview' }
        elseif ($hasErrors) { Set-PatchValue -InputObject $run -Name 'status' -Value 'CompletedWithErrors' }
        else { Set-PatchValue -InputObject $run -Name 'status' -Value 'Completed' }
        Save-PatchDecision -RunPath $runFile -RunState $run
        Write-PatchSummary -RunPath $runFile -RunState $run
        return [pscustomobject]@{ status = [string](Get-PatchValue $run @('status') 'Completed'); action = $Action; runId = [string](Get-PatchValue $run @('runId') ''); runPath = $runFile; vmResults = @($resultRows) }
    }
    catch {
        $message = Protect-PatchText $_.Exception.Message
        if ($null -ne $run) {
            $runFile = Get-PatchRunJsonPath -RunPath $RunPath
            $errorRecord = Write-PatchError -RunPath $runFile -Message $message -Step $Action -Code 'ControllerError'
            Set-PatchValue -InputObject $run -Name 'status' -Value 'Stopped'
            Set-PatchValue -InputObject $run -Name 'stopReason' -Value $message
            $runErrors = @(Get-PatchArray -Value (Get-PatchValue $run @('errors') @()))
            $runErrors += $errorRecord
            Set-PatchValue -InputObject $run -Name 'errors' -Value $runErrors
            Save-PatchDecision -RunPath $runFile -RunState $run
            Write-PatchEvent -RunPath $runFile -Message $message -Step $Action -Level 'ERROR'
            Write-PatchSummary -RunPath $runFile -RunState $run
            return [pscustomobject]@{ status = 'Stopped'; action = $Action; runId = [string](Get-PatchValue $run @('runId') ''); runPath = $runFile; vmResults = @($resultRows); error = $message }
        }
        throw
    }
}
