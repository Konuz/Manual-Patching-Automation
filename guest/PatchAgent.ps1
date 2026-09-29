[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Scan', 'Install', 'Reboot')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [Guid]$RunId,

    [Parameter(Mandatory = $true)]
    [Guid]$StepId,

    [string]$SelectionPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$runDirectory = Join-Path (Join-Path $env:ProgramData 'WindowsPatchWizard') $RunId.ToString()
$stepDirectory = Join-Path $runDirectory $StepId.ToString()
$script:LogPath = Join-Path $stepDirectory 'agent.log'
$script:StatusPath = Join-Path $stepDirectory 'status.json'
$script:Status = [ordered]@{
    runId = $RunId.ToString()
    stepId = $StepId.ToString()
    mode = $Mode
    status = 'Started'
    outcome = $null
    startedAt = (Get-Date).ToUniversalTime().ToString('o')
    finishedAt = $null
    updates = @()
}

function Save-Status {
    $temporaryPath = '{0}.{1}.tmp' -f $script:StatusPath, ([Guid]::NewGuid().ToString('N'))
    try {
        $json = $script:Status | ConvertTo-Json -Depth 12
        Set-Content -LiteralPath $temporaryPath -Value $json -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $script:StatusPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-AgentLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    Add-Content -LiteralPath $script:LogPath -Value ('{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message) -Encoding UTF8
}

function Set-TerminalStatus {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Completed', 'Failed')][string]$State,
        [Parameter(Mandatory = $true)][string]$Outcome
    )

    $script:Status.status = $State
    $script:Status.outcome = $Outcome
    $script:Status.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-Status
}

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            return $property.Value
        }
    }
    catch {
    }

    return $null
}

function Format-HResult {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $number = [int64]$Value
    if ($number -lt 0) {
        $number += 0x100000000
    }

    return '0x{0:X8}' -f ([uint32]$number)
}

function New-WuaResult {
    param($Result)

    if ($null -eq $Result) {
        return $null
    }

    $rebootRequired = Get-OptionalProperty -InputObject $Result -Name 'RebootRequired'
    return [ordered]@{
        resultCode = [int]$Result.ResultCode
        hResult = Format-HResult (Get-OptionalProperty -InputObject $Result -Name 'HResult')
        rebootRequired = if ($null -ne $rebootRequired) { [bool]$rebootRequired } else { $null }
    }
}

function Get-ClusterState {
    try {
        if (-not ('WindowsPatchWizard.ClusterNative' -as [type])) {
            Add-Type -Namespace 'WindowsPatchWizard' -Name 'ClusterNative' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("clusapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetNodeClusterState(string lpszNodeName, out uint pdwClusterState);
'@
        }

        [uint32]$state = 0
        $returnCode = [WindowsPatchWizard.ClusterNative]::GetNodeClusterState($null, [ref]$state)
        if ($returnCode -ne 0) {
            return [ordered]@{ membership = 'Unknown'; state = $null; nativeReturnCode = [int]$returnCode; reason = 'GetNodeClusterState returned a nonzero code.' }
        }

        $stateValue = [int]$state
        switch ($stateValue) {
            0 { $membership = 'NotMember' }
            1 { $membership = 'NotMember' }
            3 { $membership = 'Member' }
            19 { $membership = 'Member' }
            default { $membership = 'Unknown' }
        }

        return [ordered]@{
            membership = $membership
            state = $stateValue
            nativeReturnCode = 0
            reason = if ($membership -eq 'Unknown') { 'GetNodeClusterState returned an unrecognised state.' } else { $null }
        }
    }
    catch {
        return [ordered]@{ membership = 'Unknown'; state = $null; nativeReturnCode = $null; reason = 'The local cluster state could not be read.' }
    }
}

function Get-PendingReboot {
    # Windows servicing and Windows Update mark a required restart with these keys.
    $componentBasedServicing = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $windowsUpdate = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    return [ordered]@{
        isPending = ($componentBasedServicing -or $windowsUpdate)
        componentBasedServicing = $componentBasedServicing
        windowsUpdate = $windowsUpdate
    }
}

function Get-SystemSnapshot {
    return [ordered]@{
        osName = [string](Get-CimInstance -ClassName Win32_OperatingSystem).Caption
        pendingReboot = Get-PendingReboot
    }
}

function Convert-UpdateType {
    param($Update)

    try {
        $typeText = [string]$Update.Type
        if ($typeText -match 'Driver' -or $typeText -eq '2') {
            return 'Driver'
        }
        if ($typeText -match 'Software' -or $typeText -eq '1') {
            return 'Software'
        }
    }
    catch {
    }

    return 'Unknown'
}

function New-UpdateRecord {
    param(
        [Parameter(Mandatory = $true)]$Update,
        [Parameter(Mandatory = $true)][int]$Index
    )

    $identity = $Update.Identity
    $browseOnly = Get-OptionalProperty -InputObject $Update -Name 'BrowseOnly'
    if ($null -ne $browseOnly) {
        $browseOnly = [bool]$browseOnly
    }

    return [ordered]@{
        index = $Index
        updateId = [string]$identity.UpdateID
        revisionNumber = [int64]$identity.RevisionNumber
        title = [string]$Update.Title
        # WUA gives bare numbers ("5065432"); a KB can cover several updates, e.g. one per Defender version.
        kbArticleIds = @(@($Update.KBArticleIDs) | ForEach-Object { 'KB' + [string]$_ })
        type = Convert-UpdateType -Update $Update
        browseOnly = $browseOnly
        eulaAccepted = [bool]$Update.EulaAccepted
        selected = $false
        downloadResult = $null
        installResult = $null
        errors = @()
    }
}

function Search-Updates {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search('IsInstalled=0 and IsHidden=0')
    return [pscustomobject]@{
        session = $session
        result = $result
        updates = $result.Updates
    }
}

function Read-Selection {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The selection file was not found.'
    }

    # Selection shape: [{"updateId":"GUID","revisionNumber":123}]
    $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $selections = @()
    foreach ($item in @($document)) {
        $updateId = ([string]$item.updateId).Trim()
        if ([string]::IsNullOrWhiteSpace($updateId)) {
            throw 'A selection entry has no updateId.'
        }

        try {
            if ($null -eq $item.revisionNumber -or [string]::IsNullOrWhiteSpace([string]$item.revisionNumber)) {
                throw 'missing revisionNumber'
            }
            $revisionNumber = [int64]$item.revisionNumber
        }
        catch {
            throw 'A selection entry has an invalid revisionNumber.'
        }

        $selections += [pscustomobject]@{
            updateId = $updateId
            revisionNumber = $revisionNumber
        }
    }

    return @($selections)
}

function Get-UpdateKey {
    param(
        [Parameter(Mandatory = $true)][string]$UpdateId,
        [Parameter(Mandatory = $true)][int64]$RevisionNumber
    )

    return '{0}|{1}' -f $UpdateId.ToLowerInvariant(), $RevisionNumber
}

function Invoke-Scan {
    $script:Status.cluster = Get-ClusterState
    $script:Status.system = Get-SystemSnapshot
    $search = Search-Updates
    $script:Status.searchResult = New-WuaResult -Result $search.result
    if ([int]$search.result.ResultCode -ne 2) {
        $script:Status.outcome = 'SearchFailed'
        throw 'Windows Update search did not complete successfully.'
    }

    $records = @()
    for ($i = 0; $i -lt $search.updates.Count; $i++) {
        $records += New-UpdateRecord -Update $search.updates.Item($i) -Index $i
    }
    $script:Status.updates = $records
    $script:Status.outcome = 'ScanCompleted'
}

function Invoke-Install {
    if ([string]::IsNullOrWhiteSpace($SelectionPath)) {
        throw 'SelectionPath is required for Install mode.'
    }

    $requested = Read-Selection -Path $SelectionPath
    $script:Status.requestedSelections = @($requested | ForEach-Object {
            [ordered]@{ updateId = $_.updateId; revisionNumber = $_.revisionNumber }
        })

    $script:Status.cluster = Get-ClusterState
    if ($script:Status.cluster.membership -ne 'NotMember') {
        $script:Status.outcome = 'BlockedByCluster'
        throw 'Installation is blocked because cluster membership is Member or Unknown.'
    }

    $search = Search-Updates
    $script:Status.searchResult = New-WuaResult -Result $search.result
    if ([int]$search.result.ResultCode -ne 2) {
        $script:Status.outcome = 'SearchFailed'
        throw 'Windows Update search did not complete successfully.'
    }

    $offered = @()
    $recordsByKey = @{}
    $recordsById = @{}
    for ($i = 0; $i -lt $search.updates.Count; $i++) {
        $update = $search.updates.Item($i)
        $record = New-UpdateRecord -Update $update -Index $i
        $entry = [pscustomobject]@{ update = $update; record = $record }
        $offered += $entry
        $key = Get-UpdateKey -UpdateId $record.updateId -RevisionNumber $record.revisionNumber
        $recordsByKey[$key] = $entry
        if (-not $recordsById.ContainsKey($record.updateId.ToLowerInvariant())) {
            $recordsById[$record.updateId.ToLowerInvariant()] = @()
        }
        $recordsById[$record.updateId.ToLowerInvariant()] += $entry
        $script:Status.updates += $record
    }

    $selectedUpdates = New-Object -ComObject Microsoft.Update.UpdateColl
    $selectedIndexes = @()
    $seen = @{}
    $skipped = @()
    foreach ($selection in $requested) {
        $key = Get-UpdateKey -UpdateId $selection.updateId -RevisionNumber $selection.revisionNumber
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true

        if (-not $recordsByKey.ContainsKey($key)) {
            $idKey = $selection.updateId.ToLowerInvariant()
            $availableRevisions = @()
            if ($recordsById.ContainsKey($idKey)) {
                $availableRevisions = @($recordsById[$idKey] | ForEach-Object { $_.record.revisionNumber })
            }
            $skipped += [ordered]@{
                updateId = $selection.updateId
                revisionNumber = $selection.revisionNumber
                reason = if ($availableRevisions.Count -gt 0) { 'RevisionChanged' } else { 'Missing' }
                availableRevisions = $availableRevisions
            }
            continue
        }

        $entry = $recordsByKey[$key]
        $record = $entry.record
        $record.selected = $true
        try {
            if (-not [bool]$entry.update.EulaAccepted) {
                $entry.update.AcceptEula()
            }
            $record.eulaAccepted = [bool]$entry.update.EulaAccepted
            [void]$selectedUpdates.Add($entry.update)
            $selectedIndexes += $record.index
        }
        catch {
            $record.selected = $false
            $record.errors += [ordered]@{ stage = 'AcceptEula'; message = $_.Exception.Message }
        }
    }

    $script:Status.skipped = $skipped
    $script:Status.selectedUpdateCount = [int]$selectedUpdates.Count
    Save-Status

    if ($selectedUpdates.Count -eq 0) {
        if (@($script:Status.updates | Where-Object { @($_.errors).Count -gt 0 }).Count -gt 0) {
            $script:Status.outcome = 'SelectionFailed'
            throw 'One or more selected updates could not accept their EULA.'
        }
        $script:Status.outcome = 'NoSelectedUpdates'
        return
    }

    $downloader = $search.session.CreateUpdateDownloader()
    $downloader.Updates = $selectedUpdates
    $downloadResult = $downloader.Download()
    $script:Status.downloadResult = New-WuaResult -Result $downloadResult
    for ($i = 0; $i -lt $selectedIndexes.Count; $i++) {
        try {
            $script:Status.updates[$selectedIndexes[$i]].downloadResult = New-WuaResult -Result $downloadResult.GetUpdateResult($i)
        }
        catch {
            $script:Status.updates[$selectedIndexes[$i]].errors += [ordered]@{ stage = 'ReadDownloadResult'; message = $_.Exception.Message }
        }
    }
    Save-Status
    if ([int]$downloadResult.ResultCode -notin @(2, 3)) {
        $script:Status.outcome = 'DownloadFailed'
        throw 'Windows Update download failed.'
    }

    $installer = $search.session.CreateUpdateInstaller()
    $installer.Updates = $selectedUpdates
    $installResult = $installer.Install()
    $script:Status.installResult = New-WuaResult -Result $installResult
    for ($i = 0; $i -lt $selectedIndexes.Count; $i++) {
        try {
            $script:Status.updates[$selectedIndexes[$i]].installResult = New-WuaResult -Result $installResult.GetUpdateResult($i)
        }
        catch {
            $script:Status.updates[$selectedIndexes[$i]].errors += [ordered]@{ stage = 'ReadInstallResult'; message = $_.Exception.Message }
        }
    }
    $script:Status.system = Get-SystemSnapshot

    if ([int]$installResult.ResultCode -eq 2) {
        $script:Status.outcome = if (@($script:Status.updates | Where-Object { @($_.errors).Count -gt 0 }).Count -gt 0) { 'InstallSucceededWithErrors' } else { 'InstallSucceeded' }
    }
    elseif ([int]$installResult.ResultCode -eq 3) {
        $script:Status.outcome = 'InstallSucceededWithErrors'
    }
    else {
        $script:Status.outcome = 'InstallFailed'
        throw 'Windows Update installation failed.'
    }
}

function Invoke-Reboot {
    $script:Status.cluster = Get-ClusterState
    if ($script:Status.cluster.membership -ne 'NotMember') {
        $script:Status.outcome = 'BlockedByCluster'
        throw 'Reboot is blocked because cluster membership is Member or Unknown.'
    }

    # Final status first: after the restart the agent cannot write it. The controller confirms
    # the reboot by a newer boot time; the agent never restarts on its own in other modes.
    $script:Status.status = 'RebootRequested'
    $script:Status.outcome = 'RebootRequested'
    $script:Status.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-Status
    Write-AgentLog -Message 'Reboot requested with shutdown.exe /r /t 0.'

    $process = Start-Process -FilePath 'shutdown.exe' -ArgumentList @('/r', '/t', '0') -Wait -PassThru -WindowStyle Hidden
    # 1115 ERROR_SHUTDOWN_IN_PROGRESS, 1190 ERROR_SHUTDOWN_IS_SCHEDULED: the guest restarts anyway, so the step
    # stays RebootRequested and the controller waits for a newer boot time (the next batch waits too).
    if ($process.ExitCode -in @(1115, 1190)) {
        $script:Status.outcome = 'RebootAlreadyPending'
        Save-Status
        Write-AgentLog -Message ('shutdown.exe returned {0}: a restart is already in progress or scheduled.' -f $process.ExitCode)
        return
    }
    if ($process.ExitCode -ne 0) {
        $script:Status.outcome = 'RebootCommandFailed'
        throw ('shutdown.exe returned exit code {0}.' -f $process.ExitCode)
    }
}

try {
    if (-not (Test-Path -LiteralPath $stepDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $stepDirectory -Force | Out-Null
    }
    Save-Status
    Write-AgentLog -Message ('Agent started in {0} mode.' -f $Mode)

    if ($Mode -ne 'Install' -and -not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        throw 'SelectionPath is valid only for Install mode.'
    }

    switch ($Mode) {
        'Scan' { Invoke-Scan; Set-TerminalStatus -State 'Completed' -Outcome $script:Status.outcome }
        'Install' { Invoke-Install; Set-TerminalStatus -State 'Completed' -Outcome $script:Status.outcome }
        'Reboot' { Invoke-Reboot }
    }
}
catch {
    $message = $_.Exception.Message
    $script:Status.error = $message
    if ([string]::IsNullOrWhiteSpace([string]$script:Status.outcome)) {
        $script:Status.outcome = 'Failed'
    }
    Write-AgentLog -Message ('ERROR: {0}' -f $message)
    Set-TerminalStatus -State 'Failed' -Outcome $script:Status.outcome
    exit 1
}
exit 0
