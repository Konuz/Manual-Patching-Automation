# Windows PowerShell 5.1 patch-run controller.
# Public functions:
#   New-PatchRun(config, VM entries) creates runs/<runId>/run.json without credentials.
#   Read-PatchRun, Write-PatchRun, Write-PatchEvent, Write-PatchError persist run state and logs.
#   Resolve-PatchVms(RunPath, VCenterCredentials) finds each VM on one of the vCenters and groups it for guest credentials.
#   Invoke-PatchAction(Action, RunPath, VCenterCredentials, GuestCredentials) runs one operator step.
#   VCenterCredentials: vCenter name -> PSCredential; the key '*' is used for every vCenter without its own.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GuestOps.ps1')

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
    if ($null -eq $Value) { return @() }
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
        # The window reads run.json every 500 ms during an action; while it has the file open the
        # replace fails with an IOException, so it is retried for up to about two seconds.
        for ($attempt = 1; ; $attempt++) {
            try { Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop; break }
            catch [System.IO.IOException] { if ($attempt -ge 20) { throw }; Start-Sleep -Milliseconds 100 }
        }
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
    # Compact JSON: run.json is re-read every 500 ms during an action, and indentation made it several times larger.
    # Serialized directly (a recursive copy took seconds for a large run). Windows PowerShell 5.1 writes an array
    # wrapped in a PSObject (e.g. returned with Write-Output -NoEnumerate) as {"value":[...],"Count":n}, so arrays
    # are put into the state as plain @(...) arrays.
    $json = $RunState | ConvertTo-Json -Depth 20 -Compress
    # Credentials live in memory only: a state field named like one is a programming error, never written.
    if ($json -match '"[^"]*(?i:password|credential|secret|securestring|token)[^"]*":') { throw 'The run state must not contain a credential field.' }
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

    # Config comes from the GUI: VCenter, OutputRoot and Options (missing options use the plan defaults).
    $options = Get-PatchValue $Config @('Options') $null
    $option = { param([string]$Name, $Default) $value = Get-PatchValue $options @($Name) $null; if ($null -eq $value) { $Default } else { $value } }
    # One or more vCenters, separated by commas, semicolons or spaces.
    $vCenters = @(([string](Get-PatchValue $Config @('VCenter') '')) -split '[,;\s]+' | Where-Object { $_ })
    $root = [string](Get-PatchValue $Config @('OutputRoot') '')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'runs' }
    $runId = [Guid]::NewGuid().ToString('D')
    $runDirectory = Join-Path $root $runId
    $runJsonPath = Join-Path $runDirectory 'run.json'
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null

    $vmRecords = @()
    $seenVmNames = @{}
    foreach ($entry in @($VMEntries)) {
        $name = [string]$entry.VmName
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Each VM entry requires a VM name.' }
        if ($seenVmNames.ContainsKey($name)) { throw ('Duplicate VM name {0}.' -f $name) }
        $seenVmNames[$name] = $true
        $expectedFqdn = [string]$entry.ExpectedFqdn

        $vmRecords += [pscustomobject]@{
            vmName = $name
            expectedFqdn = $expectedFqdn
            vCenter = $null
            vmId = $null
            guestHostName = $null
            accountGroup = $null
            status = 'Pending'
            currentRound = 1
            currentAction = $null
            lastProcessedAction = $null
            availableUpdates = @()
            selectedUpdates = @()
            installedUpdates = @()
            skippedUpdates = @()
            pendingUpdates = @()
            reboot = [pscustomobject]@{ status = 'NotRequested'; required = $false; confirmedBootTime = $null }
            steps = @()
            agentStatus = $null
            errors = @()
        }
    }

    $state = [pscustomobject]@{
        schemaVersion = 'patch-run-v1'
        runId = $runId
        createdAt = Get-PatchUtcNow
        updatedAt = Get-PatchUtcNow
        status = 'Created'
        vCenters = $vCenters
        options = [pscustomobject]@{
            ignoreVCenterCertificate = [bool](& $option 'IgnoreVCenterCertificate' $false)
            ignoreEsxiCertificatesForFileTransfers = [bool](& $option 'IgnoreEsxiCertificatesForFileTransfers' $false)
            scanConcurrency = [int](& $option 'ScanConcurrency' 3)
            installConcurrency = [int](& $option 'InstallConcurrency' 3)
            rebootBatchSize = [int](& $option 'RebootBatchSize' 1)
            limits = [pscustomobject]@{
                scanTimeoutMinutes = [int](& $option 'ScanTimeoutMinutes' 30)
                installTimeoutMinutes = [int](& $option 'InstallTimeoutMinutes' 180)
                rebootConfirmationTimeoutMinutes = [int](& $option 'RebootConfirmationTimeoutMinutes' 30)
            }
        }
        currentRound = 1
        currentAction = $null
        vms = @($vmRecords)
        errors = @()
        runPath = $runJsonPath
    }

    Write-PatchRun -RunPath $runJsonPath -RunState $state | Out-Null
    # Read back, so a new run has the same shape as a resumed one.
    return (Read-PatchRun -RunPath $runJsonPath)
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
        context = $Context
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
    [void]$markdown.AppendLine(('* Run ID: `{0}`' -f [string]$RunState.runId))
    [void]$markdown.AppendLine(('* Status: **{0}**' -f [string]$RunState.status))
    [void]$markdown.AppendLine(('* Current round: {0}' -f [string]$RunState.currentRound))
    [void]$markdown.AppendLine(('* Ignore vCenter certificate: `{0}`' -f $ignoreVc))
    [void]$markdown.AppendLine(('* Ignore ESXi certificates for file transfers: `{0}`' -f $ignoreEsxi))
    [void]$markdown.AppendLine(('* Limits (minutes): scan `{0}`, install `{1}`, reboot confirmation `{2}`' -f [string](Get-PatchValue $limits @('scanTimeoutMinutes') 30), [string](Get-PatchValue $limits @('installTimeoutMinutes') 180), [string](Get-PatchValue $limits @('rebootConfirmationTimeoutMinutes') 30)))
    [void]$markdown.AppendLine('')
    [void]$markdown.AppendLine('| VM | Expected FQDN | Status | Installed | Skipped | Pending | Reboot | Errors |')
    [void]$markdown.AppendLine('| --- | --- | --- | --- | --- | --- | --- | --- |')

    foreach ($vm in @(Get-PatchArray $RunState.vms)) {
        $name = [string]$vm.vmName
        $fqdn = [string]$vm.expectedFqdn
        $status = [string]$vm.status
        $installed = @(Get-PatchArray $vm.installedUpdates)
        $skipped = @(Get-PatchArray $vm.skippedUpdates)
        $pending = @(Get-PatchArray $vm.pendingUpdates)
        $reboot = Get-PatchValue $vm @('reboot') ([pscustomobject]@{})
        $rebootStatus = [string](Get-PatchValue $reboot @('status') 'NotRequested')
        # Earlier confirmed reboots stay visible when a later scan reports a new pending reboot.
        $confirmedReboots = @(Get-PatchArray $vm.steps | Where-Object { [string]$_.action -eq 'Reboot' -and [string]$_.status -eq 'Confirmed' }).Count
        if ($confirmedReboots -gt 0 -and $rebootStatus -ne 'Confirmed') { $rebootStatus = '{0} (confirmed reboots: {1})' -f $rebootStatus, $confirmedReboots }
        $vmErrors = @(Get-PatchArray $vm.errors)
        $errorLink = '[errors.log](errors.log)'
        # Updates are listed by title (e.g. "... KB5034439 ..."); a skipped selection has no title of its own.
        $titles = @{}
        foreach ($update in @(Get-PatchArray $vm.availableUpdates) + $installed + $pending) {
            $id = [string](Get-PatchValue $update @('updateId') '')
            $title = [string](Get-PatchValue $update @('title') '')
            if ($id -and $title) { $titles[$id.ToLowerInvariant()] = $title }
        }
        $describe = {
            param($Update)
            $id = [string](Get-PatchValue $Update @('updateId') '')
            $title = [string](Get-PatchValue $Update @('title') '')
            if (-not $title -and $titles.ContainsKey($id.ToLowerInvariant())) { $title = $titles[$id.ToLowerInvariant()] }
            if ($title) { $title } else { '{0} rev {1}' -f $id, [string](Get-PatchValue $Update @('revisionNumber') '') }
        }
        $installedText = (@($installed | ForEach-Object { & $describe $_ }) -join '; ')
        $skippedText = (@($skipped | ForEach-Object { '{0} ({1})' -f (& $describe $_), [string](Get-PatchValue $_ @('reason') '') }) -join '; ')
        $pendingText = (@($pending | ForEach-Object { & $describe $_ }) -join '; ')
        $escape = { param([string]$Value) ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') }
        $rowValues = @((& $escape $name), (& $escape $fqdn), (& $escape $status), (& $escape $installedText), (& $escape $skippedText), (& $escape $pendingText), (& $escape $rebootStatus), $errorLink, [string]$vmErrors.Count)
        [void]$markdown.AppendLine(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} ({8}) |' -f $rowValues))
        $vmRows += [pscustomobject]@{
            RunId = [string]$RunState.runId
            VMName = $name
            ExpectedFqdn = $fqdn
            VCenter = [string]$vm.vCenter
            VMId = [string]$vm.vmId
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
    $options = $RunState.options
    return (Get-PatchValue -InputObject $options -Names $Names -Default $Default)
}

function Test-PatchIgnoreEsxi {
    # The run's "Ignore ESXi certificates for file transfers" choice (curl.exe --insecure only).
    param($RunState)
    return [bool](Get-PatchOption $RunState @('ignoreEsxiCertificatesForFileTransfers') $false)
}

function Get-PatchLimit {
    param($RunState, [string]$Name, [int]$Default)
    $options = $RunState.options
    $limits = Get-PatchValue -InputObject $options -Names @('limits') -Default $null
    return [int](Get-PatchValue -InputObject $limits -Names @($Name) -Default $Default)
}

function New-PatchStep {
    param([string]$Action, [string]$AgentMode, [int]$Round)
    return [pscustomobject][ordered]@{
        action = $Action
        agentMode = $AgentMode
        round = $Round
        stepId = ([Guid]::NewGuid()).ToString('D')
        status = 'IntentPersisted'
        startAttempted = $false
        processId = $null
        startedAt = $null
        deadlineAt = $null
        finishedAt = $null
        baselineBootTime = $null
        error = $null
    }
}

function Get-PatchStep {
    param($VMRecord, [string]$Action, [int]$Round)
    $steps = @(Get-PatchArray $VMRecord.steps)
    for ($index = $steps.Count - 1; $index -ge 0; $index--) {
        $step = $steps[$index]
        if ([string]::Equals([string]$step.action, $Action, [System.StringComparison]::OrdinalIgnoreCase) -and [int]$step.round -eq $Round) {
            # A confirmed, reviewed or failed reboot is finished; another pending reboot in the same round needs a new step.
            if ($Action -eq 'Reboot' -and [string]$step.status -in @('Confirmed', 'Reviewed', 'Failed')) { break }
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

function Test-PatchMutatingStepReconciled {
    # A started install or reboot is settled only by its final result or by the operator's review
    # (plan: an unclear result needs manual reconciliation before the next installation).
    param($Step)
    if (-not [bool]$Step.startAttempted) { return $true }
    $status = [string]$Step.status
    # A failed reboot is the agent's final answer: it did not restart the guest (cluster member or shutdown.exe error).
    if ([string]$Step.action -eq 'Reboot') { return ($status -in @('Confirmed', 'Reviewed', 'Failed')) }
    return ($status -in @('Completed', 'CompletedWithErrors', 'Failed', 'Reviewed'))
}

function Get-PatchMutatingStepBlocker {
    param($RunState, $VMRecord, $CurrentStep)

    $runId = [string]$RunState.runId
    $currentStepId = [string](Get-PatchValue $CurrentStep @('stepId') '')
    foreach ($step in @(Get-PatchArray $VMRecord.steps)) {
        $action = [string]$step.action
        if (-not [string]::Equals($action, 'Install', [System.StringComparison]::OrdinalIgnoreCase) -and
            -not [string]::Equals($action, 'Reboot', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($currentStepId) -and
            [string]::Equals([string]$step.stepId, $currentStepId, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not (Test-PatchMutatingStepReconciled -Step $step)) { return $step }
    }
    return $null
}

function Get-PatchAgentLocalPaths {
    param([string]$RunPath, $VMRecord, $Step)
    $safeName = ([string]$VMRecord.vmName) -replace '[^a-zA-Z0-9_.-]', '_'
    $directory = Get-PatchRunDirectory -RunPath $RunPath
    return [pscustomobject]@{
        status = Join-Path $directory ('status-{0}-{1}.json' -f $safeName, [string]$Step.stepId)
        selection = Join-Path $directory ('selection-{0}-{1}.json' -f $safeName, [string]$Step.stepId)
        agentLog = Join-Path $directory ('agent-{0}-{1}.log' -f $safeName, [string]$Step.stepId)
    }
}

function Get-PatchGuestPaths {
    param($Context, $RunState, $Step)
    $programData = [string](Get-PatchValue $Context @('ProgramData') 'C:\ProgramData')
    $stepDirectory = Join-Path (Join-Path (Join-Path $programData 'WindowsPatchWizard') ([string]$RunState.runId)) ([string]$Step.stepId)
    return [pscustomobject]@{
        directory = $stepDirectory
        agent = Join-Path $stepDirectory 'PatchAgent.ps1'
        selection = Join-Path $stepDirectory 'selection.json'
    }
}

function Get-PatchLatestStep {
    # The latest step of this action in the VM's current round, or $null.
    param($VMRecord, [string]$Action)
    $round = [int]$VMRecord.currentRound
    $steps = @(Get-PatchArray $VMRecord.steps | Where-Object { [string]$_.action -eq $Action -and [int]$_.round -eq $round })
    if ($steps.Count -eq 0) { return $null }
    return $steps[-1]
}

function Test-PatchStepStarted {
    # True when the latest install or reboot step in the VM's current round was started and is not settled
    # yet (no final result, no review): only such a step is observed again. A settled step (e.g. a failed
    # install, a confirmed reboot) followed by another install or reboot needs a new step and a new approval.
    param($VMRecord, [string]$Action)
    $step = Get-PatchLatestStep -VMRecord $VMRecord -Action $Action
    if ($null -eq $step) { return $false }
    return (-not (Test-PatchMutatingStepReconciled -Step $step))
}

function Test-PatchInstallDone {
    # Plan: one installation per round; updates found later (e.g. by Verify) need a new round and selection.
    # A failed install (the agent reported it, e.g. Windows Update search or download failed) may be approved again.
    param($VMRecord)
    $step = Get-PatchLatestStep -VMRecord $VMRecord -Action 'Install'
    return ($null -ne $step -and [string]$step.status -in @('Completed', 'CompletedWithErrors', 'Reviewed'))
}

function Get-PatchClusterMembership {
    # From the VM's last agent status (NotMember, Member or Unknown); Unknown when there is none.
    param($VMRecord)
    $cluster = Get-PatchValue $VMRecord.agentStatus @('cluster') $null
    return [string](Get-PatchValue $cluster @('membership') 'Unknown')
}

function Test-PatchVmRequiresReboot {
    param($VMRecord)
    $reboot = $VMRecord.reboot
    return ([bool](Get-PatchValue $reboot @('required') $false) -and [string](Get-PatchValue $reboot @('status') '') -ne 'Confirmed')
}

function Write-PatchSelectionFile {
    param([string]$Path, $VMRecord)
    $selection = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(Get-PatchArray $VMRecord.selectedUpdates)) {
        $id = [string](Get-PatchValue $item @('updateId') '')
        $revision = Get-PatchValue $item @('revisionNumber') $null
        if ([string]::IsNullOrWhiteSpace($id) -or $null -eq $revision) { continue }
        [void]$selection.Add([ordered]@{ updateId = $id; revisionNumber = [int64]$revision })
    }
    # Always a JSON array, also when empty (the agent then reports NoSelectedUpdates).
    Write-PatchTextAtomic -Path $Path -Text (ConvertTo-Json -InputObject $selection -Depth 5) | Out-Null
    Write-Output -NoEnumerate $selection
}

function Update-PatchVmFromAgentStatus {
    param([string]$Action, $VMRecord, $Status)

    if ($null -eq $Status) { return }
    # The VM keeps the last agent status without its update list (that is in availableUpdates and pendingUpdates,
    # and every step's full status is in the run folder as status-<vm>-<stepId>.json).
    Set-PatchValue -InputObject $VMRecord -Name 'agentStatus' -Value ($Status | Select-Object -Property * -ExcludeProperty updates)
    $updates = @(Get-PatchArray (Get-PatchValue $Status @('updates') @()))
    $system = Get-PatchValue $Status @('system') $null
    $pendingReboot = [bool](Get-PatchValue (Get-PatchValue $system @('pendingReboot') $null) @('isPending') $false)
    $reboot = $VMRecord.reboot
    # Only a successful Windows Update search (WUA result 2) is a new truth about the offered updates;
    # after a blocked or failed search the previous lists stay.
    $searchSucceeded = [int](Get-PatchValue (Get-PatchValue $Status @('searchResult') $null) @('resultCode') 0) -eq 2

    if ($Action -eq 'Scan' -or $Action -eq 'Verify') {
        if ($searchSucceeded) {
            Set-PatchValue -InputObject $VMRecord -Name 'availableUpdates' -Value $updates
            Set-PatchValue -InputObject $VMRecord -Name 'pendingUpdates' -Value $updates
        }
        # A fresh scan is the current truth about a pending reboot; without one, a confirmed reboot stays Confirmed.
        # A sent reboot that is not confirmed yet stays offered, so approving Reboot again can confirm it.
        if ($pendingReboot) {
            Set-PatchValue -InputObject $reboot -Name 'required' -Value $true
            Set-PatchValue -InputObject $reboot -Name 'status' -Value 'Pending'
        }
        elseif (-not (Test-PatchStepStarted -VMRecord $VMRecord -Action 'Reboot')) {
            Set-PatchValue -InputObject $reboot -Name 'required' -Value $false
            if ([string]$reboot.status -ne 'Confirmed') { Set-PatchValue -InputObject $reboot -Name 'status' -Value 'NotRequested' }
        }
        return
    }

    if ($Action -eq 'Install') {
        # WUA result code 2 = succeeded.
        $isInstalled = { [int](Get-PatchValue (Get-PatchValue $args[0] @('installResult') $null) @('resultCode') 0) -eq 2 }
        $installedNow = @($updates | Where-Object { & $isInstalled $_ })
        Set-PatchValue -InputObject $VMRecord -Name 'installedUpdates' -Value @(@(Get-PatchArray $VMRecord.installedUpdates) + $installedNow)
        Set-PatchValue -InputObject $VMRecord -Name 'skippedUpdates' -Value @(@(Get-PatchArray $VMRecord.skippedUpdates) + @(Get-PatchArray (Get-PatchValue $Status @('skipped') @())))
        if ($searchSucceeded) {
            Set-PatchValue -InputObject $VMRecord -Name 'pendingUpdates' -Value @($updates | Where-Object { -not (& $isInstalled $_) })
        }
        $installReboot = [bool](Get-PatchValue (Get-PatchValue $Status @('installResult') $null) @('rebootRequired') $false)
        if ($installReboot -or $pendingReboot) {
            Set-PatchValue -InputObject $reboot -Name 'required' -Value $true
            Set-PatchValue -InputObject $reboot -Name 'status' -Value 'Pending'
        }
    }
}

function Wait-PatchAgent {
    # Waits for the agent's final status.json. Read-GuestStatus accepts a final status only when its
    # runId, stepId and mode match this step and finishedAt is set; a missing process alone is not enough.
    param($Context, $RunState, $VMRecord, $Step, [string]$RunPath, [int]$TimeoutMinutes)

    $mode = [string]$Step.agentMode
    $localStatusPath = (Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $Step).status
    $ignoreEsxi = Test-PatchIgnoreEsxi $RunState
    # The deadline is saved with the step, so a resumed run keeps the original limit.
    if ([string]::IsNullOrWhiteSpace([string]$Step.deadlineAt)) {
        $startedAt = [datetime]::Parse([string](Get-PatchValue $Step @('startedAt') (Get-PatchUtcNow))).ToUniversalTime()
        Set-PatchValue -InputObject $Step -Name 'deadlineAt' -Value $startedAt.AddMinutes($TimeoutMinutes).ToString('o')
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
    }
    $deadline = [datetime]::Parse([string]$Step.deadlineAt).ToUniversalTime()

    $lastError = $null
    $agentEnded = $false
    while ($true) {
        try {
            $status = Read-GuestStatus -Context $Context -RunId $RunState.runId -StepId $Step.stepId -ExpectedMode $mode -LocalPath $localStatusPath -IgnoreEsxiCertificate $ignoreEsxi
            $state = [string](Get-PatchValue $status @('status') '')
            if ($state -eq 'Completed') {
                if ([string](Get-PatchValue $status @('outcome') '') -eq 'InstallSucceededWithErrors') {
                    return [pscustomobject]@{ status = 'CompletedWithErrors'; agentStatus = $status; error = 'The guest agent completed installation with per-update errors.' }
                }
                return [pscustomobject]@{ status = 'Completed'; agentStatus = $status; error = $null }
            }
            if ($state -eq 'Failed') {
                return [pscustomobject]@{ status = 'Failed'; agentStatus = $status; error = [string](Get-PatchValue $status @('error') 'The guest agent failed.') }
            }
            # The agent process is gone (ended, or the guest restarted) without a final status.json. The status
            # was read once more after that, since the agent may have written it just before it ended.
            if ($agentEnded) {
                return [pscustomobject]@{ status = 'NeedsReview'; agentStatus = $null; error = 'The guest agent process ended without writing a final status.json.' }
            }
            $processId = $Step.processId
            if ($null -ne $processId) {
                $process = @(Get-GuestProcess -Context $Context -ProcessId ([long]$processId))[0]
                if ($null -eq $process -or $null -ne $process.EndTime) {
                    $agentEnded = $true
                    continue
                }
            }
        }
        catch {
            $lastError = Protect-PatchText $_.Exception.Message
        }
        if ((Get-Date).ToUniversalTime() -ge $deadline) { break }
        Start-Sleep -Seconds 10
    }
    $message = 'The guest agent did not report a final result before the time limit.'
    if ($null -ne $lastError) { $message += ' Last read error: ' + $lastError }
    return [pscustomobject]@{ status = 'NeedsReview'; agentStatus = $null; error = $message }
}

function Receive-PatchAgentLog {
    # Copies the step's agent.log into the run folder. The final status stays authoritative when it cannot be copied.
    param($Context, $RunState, $VMRecord, $Step, [string]$RunPath)
    try {
        $guestLogPath = Join-Path (Get-PatchGuestPaths -Context $Context -RunState $RunState -Step $Step).directory 'agent.log'
        $localLogPath = (Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $Step).agentLog
        Receive-GuestFile -Context $Context -GuestPath $guestLogPath -LocalPath $localLogPath -IgnoreEsxiCertificate:(Test-PatchIgnoreEsxi $RunState) | Out-Null
    }
    catch {
    }
}

function Invoke-PatchAgentStep {
    param(
        [string]$Action,
        [string]$RunPath,
        $RunState,
        $VMRecord,
        $Context,
        [int]$TimeoutMinutes,
        [switch]$StartOnly
    )

    $round = [int]$VMRecord.currentRound
    $step = Get-PatchStep -VMRecord $VMRecord -Action $Action -Round $round
    $agentMode = [string]$step.agentMode
    $stepStatus = [string]$step.status
    $readOnly = $Action -in @('Scan', 'Verify')
    if ($stepStatus -in @('Completed', 'CompletedWithErrors', 'Failed', 'Reviewed') -or ($readOnly -and $stepStatus -eq 'NeedsReview')) {
        # A finished install is never repeated in the same round; a new round starts a new step. After a failed
        # install a new approval starts a new step.
        if ($Action -eq 'Install' -and $stepStatus -ne 'Failed') {
            # Invoke-PatchAction already skips such a VM (Test-PatchInstallDone); this keeps the rule at the step itself.
            return [pscustomobject]@{ status = $stepStatus; step = $step; agentStatus = $null; error = $step.error }
        }
        # Scan and Verify are read-only: repeating them, also after a scan without a final result, runs a fresh scan.
        $step = New-PatchStep -Action $Action -AgentMode $agentMode -Round $round
        Set-PatchValue -InputObject $VMRecord -Name 'steps' -Value @(@(Get-PatchArray $VMRecord.steps) + $step)
    }

    if (($Action -eq 'Install' -or $Action -eq 'Reboot') -and -not [bool]$step.startAttempted) {
        $blocker = Get-PatchMutatingStepBlocker -RunState $RunState -VMRecord $VMRecord -CurrentStep $step
        if ($null -ne $blocker) {
            return [pscustomobject]@{
                status = 'NeedsReview'
                step = $step
                agentStatus = $null
                error = ('The {0} step of round {1} has no final result. Check the guest and use Mark steps reviewed.' -f $blocker.action, $blocker.round)
            }
        }
    }

    $guestPaths = Get-PatchGuestPaths -Context $Context -RunState $RunState -Step $step
    $localPaths = Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $step
    $agentPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'guest\PatchAgent.ps1'
    if (-not (Test-Path -LiteralPath $agentPath -PathType Leaf)) { throw ('The guest agent was not found: {0}' -f $agentPath) }

    if (-not [bool]$step.startAttempted) {
        Save-PatchDecision -RunPath $RunPath -RunState $RunState
        Send-GuestFile -Context $Context -LocalPath $agentPath -GuestPath $guestPaths.agent -IgnoreEsxiCertificate:(Test-PatchIgnoreEsxi $RunState) | Out-Null
        $selectionPath = $null
        if ($Action -eq 'Install') {
            $selection = Write-PatchSelectionFile -Path $localPaths.selection -VMRecord $VMRecord
            Send-GuestFile -Context $Context -LocalPath $localPaths.selection -GuestPath $guestPaths.selection -IgnoreEsxiCertificate:(Test-PatchIgnoreEsxi $RunState) | Out-Null
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
        return [pscustomobject]@{ status = 'Started'; step = $step; agentStatus = $null; error = $null }
    }

    $waitResult = Wait-PatchAgent -Context $Context -RunState $RunState -VMRecord $VMRecord -Step $step -RunPath $RunPath -TimeoutMinutes $TimeoutMinutes
    if ($Action -in @('Scan', 'Verify') -and $waitResult.status -eq 'Completed') {
        # Plan: an unrecognised cluster state blocks the VM and goes to the errors at once.
        $cluster = Get-PatchValue $waitResult.agentStatus @('cluster') $null
        if ([string](Get-PatchValue $cluster @('membership') 'Unknown') -eq 'Unknown') {
            $waitResult.error = 'The cluster state is unknown ({0}); install and reboot are blocked for this VM.' -f [string](Get-PatchValue $cluster @('reason') 'no reason reported')
        }
    }
    Receive-PatchAgentLog -Context $Context -RunState $RunState -VMRecord $VMRecord -Step $step -RunPath $RunPath
    Set-PatchValue -InputObject $step -Name 'status' -Value $waitResult.status
    Update-PatchVmFromAgentStatus -Action $Action -VMRecord $VMRecord -Status $waitResult.agentStatus
    if ($null -ne $waitResult.error) { Set-PatchValue -InputObject $step -Name 'error' -Value (Protect-PatchText $waitResult.error) }
    if ($waitResult.status -eq 'Completed' -or $waitResult.status -eq 'CompletedWithErrors' -or $waitResult.status -eq 'Failed') { Set-PatchValue -InputObject $step -Name 'finishedAt' -Value (Get-PatchUtcNow) }
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    return [pscustomobject]@{ status = $waitResult.status; step = $step; agentStatus = $waitResult.agentStatus; error = $waitResult.error }
}

function Wait-PatchReboot {
    # Plan step 5: a reboot is confirmed only by a guest boot time newer than the baseline saved
    # before the reboot was sent. This function never sends a reboot.
    param([string]$RunPath, $RunState, $VMRecord, $Step, $Server, $GuestCredential, [int]$TimeoutMinutes)

    $baseline = [datetime]::Parse([string]$Step.baselineBootTime).ToUniversalTime()
    $ignoreEsxi = Test-PatchIgnoreEsxi $RunState
    $localStatusPath = (Get-PatchAgentLocalPaths -RunPath $RunPath -VMRecord $VMRecord -Step $Step).status
    # Every observation waits the full limit: approving Reboot again for an unconfirmed reboot (e.g. a long
    # cumulative update) only waits again for a newer boot time; the reboot itself is never sent twice.
    $deadline = (Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes)

    $lastError = $null
    while ($true) {
        try {
            # Get-PatchVM also requires the VM to be powered on with VMware Tools running.
            $vm = Get-PatchVM -Server $Server -Name $VMRecord.vmName -ExpectedFqdn $VMRecord.expectedFqdn -SavedId $VMRecord.vmId
            $context = Get-GuestContext -VM $vm -GuestCredential $GuestCredential
            $status = Read-GuestStatus -Context $context -RunId $RunState.runId -StepId $Step.stepId -ExpectedMode 'Reboot' -LocalPath $localStatusPath -IgnoreEsxiCertificate $ignoreEsxi
            if ([string](Get-PatchValue $status @('status') '') -eq 'Failed') {
                $result = [pscustomobject]@{ status = 'Failed'; step = $Step; agentStatus = $status; error = [string](Get-PatchValue $status @('error') 'The reboot command failed.') }
                Receive-PatchAgentLog -Context $context -RunState $RunState -VMRecord $VMRecord -Step $Step -RunPath $RunPath
                break
            }
            $bootTime = Read-GuestBootTime -Context $context -IgnoreEsxiCertificate $ignoreEsxi
            # At least a minute newer: a guest clock correction can shift LastBootUpTime by seconds, which must not
            # confirm a reboot that has not happened. A real reboot comes minutes after the baseline boot.
            if ([datetime]::Parse($bootTime).ToUniversalTime() -gt $baseline.AddMinutes(1)) {
                Set-PatchValue -InputObject $Step -Name 'confirmedBootTime' -Value $bootTime
                $result = [pscustomobject]@{ status = 'Confirmed'; step = $Step; agentStatus = $status; error = $null }
                Receive-PatchAgentLog -Context $context -RunState $RunState -VMRecord $VMRecord -Step $Step -RunPath $RunPath
                break
            }
        }
        catch {
            # A rejected guest credential goes to the operator's Retry / Skip / Stop choice at once.
            if ($_.Exception -is [System.Security.Authentication.InvalidCredentialException]) { throw }
            # Other errors are expected while the guest restarts.
            $lastError = Protect-PatchText $_.Exception.Message
        }
        if ((Get-Date).ToUniversalTime() -ge $deadline) {
            $message = 'A newer guest boot time was not observed before the reboot confirmation limit.'
            if ($null -ne $lastError) { $message += ' Last error: ' + $lastError }
            $result = [pscustomobject]@{ status = 'PendingRebootConfirmation'; step = $Step; agentStatus = $null; error = $message }
            break
        }
        Start-Sleep -Seconds 10
    }

    Set-PatchValue -InputObject $Step -Name 'status' -Value $result.status
    Set-PatchValue -InputObject $Step -Name 'error' -Value $result.error
    if ($result.status -ne 'PendingRebootConfirmation') { Set-PatchValue -InputObject $Step -Name 'finishedAt' -Value (Get-PatchUtcNow) }
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    return $result
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

    $round = [int]$VMRecord.currentRound
    if ($Action -eq 'Reboot') {
        $rebootStep = Get-PatchStep -VMRecord $VMRecord -Action 'Reboot' -Round $round
        if ([bool](Get-PatchValue $rebootStep @('startAttempted') $false)) {
            # The reboot was already sent (possibly before the GUI was closed): only observe it.
            if ($StartOnly) { return [pscustomobject]@{ status = 'Started'; step = $rebootStep; agentStatus = $null; error = $null } }
            return (Wait-PatchReboot -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Step $rebootStep -Server $Server -GuestCredential $GuestCredential -TimeoutMinutes (Get-PatchLimit $RunState 'rebootConfirmationTimeoutMinutes' 30))
        }
    }

    # Get-PatchVM checks the name or saved ID, the FQDN when one is expected, power state and VMware Tools.
    $vm = Get-PatchVM -Server $Server -Name $VMRecord.vmName -ExpectedFqdn $VMRecord.expectedFqdn -SavedId $VMRecord.vmId
    Set-PatchVmBinding -VMRecord $VMRecord -VM $vm -VCenter $VMRecord.vCenter
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    $context = Get-GuestContext -VM $vm -GuestCredential $GuestCredential

    if ($Action -eq 'Install' -or $Action -eq 'Reboot') {
        # Last scan result; the agent checks the cluster state again in the guest before acting.
        $membership = Get-PatchClusterMembership -VMRecord $VMRecord
        if ($membership -ne 'NotMember') { throw ('The action is blocked because cluster membership is {0}.' -f $membership) }
    }

    if ($Action -eq 'Reboot') {
        # The baseline is saved before the reboot is sent; without it the reboot could never be confirmed.
        if ([string]::IsNullOrWhiteSpace([string](Get-PatchValue $rebootStep @('baselineBootTime') ''))) {
            Set-PatchValue -InputObject $rebootStep -Name 'baselineBootTime' -Value (Read-GuestBootTime -Context $context -IgnoreEsxiCertificate (Test-PatchIgnoreEsxi $RunState))
            Save-PatchDecision -RunPath $RunPath -RunState $RunState
        }
        $started = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Context $context -StartOnly
        if ($StartOnly -or $started.status -ne 'Started') { return $started }
        return (Wait-PatchReboot -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Step $started.step -Server $Server -GuestCredential $GuestCredential -TimeoutMinutes (Get-PatchLimit $RunState 'rebootConfirmationTimeoutMinutes' 30))
    }
    $timeoutMinutes = Get-PatchLimit $RunState 'scanTimeoutMinutes' 30
    if ($Action -eq 'Install') { $timeoutMinutes = Get-PatchLimit $RunState 'installTimeoutMinutes' 180 }
    return (Invoke-PatchAgentStep -Action $Action -RunPath $RunPath -RunState $RunState -VMRecord $VMRecord -Context $context -TimeoutMinutes $timeoutMinutes -StartOnly:$StartOnly)
}

function Add-PatchVmResult {
    # Records one VM's result in run.json and run.log; problems also go to errors.log at once.
    param([string]$RunPath, $RunState, $VMRecord, [string]$Action, $Result, [ref]$RebootBarrier)

    $vmName = [string]$VMRecord.vmName
    $status = [string]$Result.status
    # A skip that only means "nothing to do in this step" keeps the VM's last real result as its status.
    if ($status -notin @('SkippedNoSelection', 'SkippedNoReboot', 'SkippedInstalledThisRound')) { Set-PatchValue -InputObject $VMRecord -Name 'status' -Value $status }
    Set-PatchValue -InputObject $VMRecord -Name 'lastProcessedAction' -Value $Action
    Set-PatchValue -InputObject $VMRecord -Name 'lastResult' -Value $status
    $agentStatus = Get-PatchValue $Result @('agentStatus') $null
    if ($null -ne $agentStatus) { Set-PatchValue -InputObject $VMRecord -Name 'agentStatus' -Value ($agentStatus | Select-Object -Property * -ExcludeProperty updates) }

    if ($Action -eq 'Reboot' -and $status -notlike 'Skipped*' -and $status -notin @('PendingRebootBarrier', 'ExcludedCluster')) {
        Set-PatchValue -InputObject $VMRecord.reboot -Name 'status' -Value $status
        if ($status -eq 'Confirmed') {
            Set-PatchValue -InputObject $VMRecord.reboot -Name 'confirmedBootTime' -Value $Result.step.confirmedBootTime
        }
        # A reboot that may have been sent but is not confirmed stops the next reboot batches (plan: step 5),
        # whatever the result says (e.g. a rejected credential while observing). A VM that failed before its
        # reboot was sent, or whose agent reported that it did not restart, affects only itself.
        if ($status -ne 'Confirmed' -and (Test-PatchStepStarted -VMRecord $VMRecord -Action 'Reboot')) {
            $RebootBarrier.Value = $true
        }
    }

    $message = [string](Get-PatchValue $Result @('error') '')
    $level = 'INFO'
    # A reboot held back by the barrier is not a fault of this VM: its reason goes to run.log as a warning only.
    if ($status -eq 'PendingRebootBarrier' -and -not [string]::IsNullOrWhiteSpace($message)) { $level = 'WARN' }
    elseif (-not [string]::IsNullOrWhiteSpace($message)) {
        $message = Protect-PatchText $message
        $level = 'ERROR'
        # The agent's outcome (e.g. SearchFailed, InstallFailed) is the more specific error code.
        $outcome = [string](Get-PatchValue $agentStatus @('outcome') '')
        $code = if ($outcome) { $outcome } else { $status }
        $hResult = $null
        foreach ($name in @('installResult', 'downloadResult', 'searchResult')) {
            if ($null -eq $hResult) { $hResult = Get-PatchValue (Get-PatchValue $agentStatus @($name) $null) @('hResult') $null }
        }
        $context = [ordered]@{
            status = $status
            round = [int]$VMRecord.currentRound
            stepId = [string](Get-PatchValue (Get-PatchValue $Result @('step') $null) @('stepId') '')
            hResult = $hResult
        }
        Set-PatchValue -InputObject $VMRecord -Name 'errors' -Value @(@(Get-PatchArray $VMRecord.errors) + [pscustomobject]@{ code = $code; message = $message; step = $Action })
        $errorRecord = Write-PatchError -RunPath $RunPath -Message $message -VMName $vmName -Step $Action -Code $code -Context $context
        Set-PatchValue -InputObject $RunState -Name 'errors' -Value @(@(Get-PatchArray $RunState.errors) + $errorRecord)
    }
    Save-PatchDecision -RunPath $RunPath -RunState $RunState
    Write-PatchEvent -RunPath $RunPath -Message (('Result: {0}. {1}' -f $status, $message).Trim()) -VMName $vmName -Step $Action -Level $level
    return [pscustomobject]@{ vmName = $vmName; status = $status; error = $message }
}

function Get-PatchAccountGroup {
    # VMs sharing a DNS suffix (e.g. corp.local) share one guest credential. A VM without a suffix,
    # typically a DMZ server with its own local administrator, gets a credential of its own.
    param([string]$HostName, [string]$VmName)
    $dot = $HostName.IndexOf('.')
    if ($dot -gt 0) { return $HostName.Substring($dot + 1).ToLowerInvariant() }
    return 'vm:' + $VmName
}

function Set-PatchVmBinding {
    # Binds the run entry to the vCenter VM found for it and records its credential group.
    param($VMRecord, $VM, [string]$VCenter)
    if ([string]::IsNullOrWhiteSpace([string]$VMRecord.vmId)) {
        Set-PatchValue -InputObject $VMRecord -Name 'vCenter' -Value $VCenter
        if ($VMRecord.vmName -ne [string]$VM.Name) {
            # An FQDN-shaped entry found by its short name: the entry becomes the expected FQDN.
            if ([string]::IsNullOrWhiteSpace([string]$VMRecord.expectedFqdn)) { Set-PatchValue -InputObject $VMRecord -Name 'expectedFqdn' -Value $VMRecord.vmName }
            Set-PatchValue -InputObject $VMRecord -Name 'vmName' -Value ([string]$VM.Name)
        }
        Set-PatchValue -InputObject $VMRecord -Name 'vmId' -Value ([string]$VM.Id)
    }
    $hostName = ([string]$VM.ExtensionData.Guest.HostName).Trim().TrimEnd('.')
    Set-PatchValue -InputObject $VMRecord -Name 'guestHostName' -Value $hostName
    if ([string]::IsNullOrWhiteSpace([string]$VMRecord.accountGroup)) {
        Set-PatchValue -InputObject $VMRecord -Name 'accountGroup' -Value (Get-PatchAccountGroup -HostName $hostName -VmName $VMRecord.vmName)
    }
}

function Connect-PatchVCenters {
    # Connects to the given vCenters. A vCenter that rejects its credential is reported instead of
    # stopping the run, so the GUI can ask for a separate credential for it.
    param([string[]]$Names, [hashtable]$Credentials, [bool]$IgnoreCertificate)
    $servers = @{}
    $rejected = @()
    foreach ($name in $Names) {
        $credential = if ($Credentials.ContainsKey($name)) { $Credentials[$name] } else { $Credentials['*'] }
        try { $servers[$name] = Connect-PatchVCenter -ServerName $name -Credential $credential -IgnoreVCenterCertificate $IgnoreCertificate }
        catch { if (Test-PatchLoginRejected $_.Exception) { $rejected += $name } else { throw } }
    }
    return [pscustomobject]@{ Servers = $servers; Rejected = $rejected }
}

function Resolve-PatchVms {
    # Before the first guest action: find each VM on the listed vCenters and group it for guest
    # credentials. A name found on more than one vCenter is ambiguous and blocks the VM (plan).
    # Only vCenter credentials are needed. A VM that cannot be found yet is tried again next time.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][hashtable]$VCenterCredentials
    )

    foreach ($credential in $VCenterCredentials.Values) { Register-PatchCredential -Credential $credential }
    $run = Read-PatchRun -RunPath $RunPath
    $connection = $null
    try {
        $connection = Connect-PatchVCenters -Names $run.vCenters -Credentials $VCenterCredentials -IgnoreCertificate ([bool]$run.options.ignoreVCenterCertificate)
        if ($connection.Rejected.Count -gt 0) {
            return [pscustomobject]@{ status = 'Stopped'; action = 'Resolve'; rejectedVCenters = $connection.Rejected; error = ('The credential was rejected by: {0}' -f ($connection.Rejected -join ', ')) }
        }
        foreach ($vmRecord in @(Get-PatchArray $run.vms)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$vmRecord.accountGroup) -or $vmRecord.status -eq 'SkippedGuestAccount') { continue }
            $found = @()
            $lastError = $null
            foreach ($name in $run.vCenters) {
                try { $found += [pscustomobject]@{ VCenter = $name; VM = (Get-PatchVM -Server $connection.Servers[$name] -Name $vmRecord.vmName -ExpectedFqdn $vmRecord.expectedFqdn -SavedId $vmRecord.vmId) } }
                catch { if ($_.Exception.Message -notmatch 'found 0\.$' -or $null -eq $lastError) { $lastError = $_.Exception.Message } }
            }
            if ($found.Count -eq 1) {
                Set-PatchVmBinding -VMRecord $vmRecord -VM $found[0].VM -VCenter $found[0].VCenter
                Write-PatchEvent -RunPath $RunPath -Message ('Found on {0}. Guest host name: {1}. Account group: {2}.' -f $vmRecord.vCenter, $vmRecord.guestHostName, $vmRecord.accountGroup) -VMName $vmRecord.vmName -Step 'Resolve'
                continue
            }
            $message = if ($found.Count -gt 1) { 'The VM name was found on several vCenters: {0}.' -f (($found | ForEach-Object { $_.VCenter }) -join ', ') } else { $lastError }
            [void](Add-PatchVmResult -RunPath $RunPath -RunState $run -VMRecord $vmRecord -Action 'Resolve' -Result ([pscustomobject]@{ status = 'Failed'; error = $message }))
        }
        Save-PatchDecision -RunPath $RunPath -RunState $run
        Write-PatchSummary -RunPath $RunPath -RunState $run
        return [pscustomobject]@{ status = 'Completed'; action = 'Resolve' }
    }
    catch {
        $message = Protect-PatchText $_.Exception.Message
        [void](Write-PatchError -RunPath $RunPath -Message $message -Step 'Resolve' -Code 'ControllerError')
        Write-PatchEvent -RunPath $RunPath -Message $message -Step 'Resolve' -Level 'ERROR'
        return [pscustomobject]@{ status = 'Stopped'; action = 'Resolve'; error = $message }
    }
    finally {
        if ($null -ne $connection) { foreach ($server in $connection.Servers.Values) { Disconnect-PatchVCenter -Server $server } }
    }
}

function Invoke-PatchAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install', 'Reboot', 'Verify')][string]$Action,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][hashtable]$VCenterCredentials,
        # Guest credentials by credential group (see Get-PatchAccountGroup); kept in memory only.
        [Parameter(Mandatory = $true)][hashtable]$GuestCredentials,
        # Resume run: observe the installs and reboots already started; start no new ones (plan: Resume run).
        [switch]$ObserveOnly,
        # Retry after a rejected guest credential: only these VMs; the others keep their results.
        [string[]]$VmNames = @()
    )

    foreach ($credential in @($VCenterCredentials.Values) + @($GuestCredentials.Values)) { Register-PatchCredential -Credential $credential }
    $run = $null
    $connection = $null
    $resultRows = @()
    try {
        $run = Read-PatchRun -RunPath $RunPath
        $runFile = Get-PatchRunJsonPath -RunPath $RunPath
        Write-PatchEvent -RunPath $runFile -Message ('{0} started.' -f $Action) -Step $Action
        Set-PatchValue -InputObject $run -Name 'status' -Value 'Running'
        Set-PatchValue -InputObject $run -Name 'currentAction' -Value $Action
        $vmRecords = @(Get-PatchArray $run.vms | Where-Object { $VmNames.Count -eq 0 -or $_.vmName -in $VmNames })
        foreach ($vmRecord in $vmRecords) {
            Set-PatchValue -InputObject $vmRecord -Name 'currentAction' -Value $null
            Set-PatchValue -InputObject $vmRecord -Name 'lastProcessedAction' -Value $null
        }
        Save-PatchDecision -RunPath $runFile -RunState $run
        Write-PatchSummary -RunPath $runFile -RunState $run

        # Only the vCenters that hold VMs of this run.
        $connection = Connect-PatchVCenters -Names @($vmRecords | ForEach-Object { [string]$_.vCenter } | Where-Object { $_ } | Sort-Object -Unique) -Credentials $VCenterCredentials -IgnoreCertificate ([bool](Get-PatchOption $run @('ignoreVCenterCertificate') $false))
        if ($connection.Rejected.Count -gt 0) {
            Set-PatchValue -InputObject $run -Name 'status' -Value 'Stopped'
            Save-PatchDecision -RunPath $runFile -RunState $run
            return [pscustomobject]@{ status = 'Stopped'; action = $Action; rejectedVCenters = $connection.Rejected; error = ('The credential was rejected by: {0}' -f ($connection.Rejected -join ', ')); vmResults = @() }
        }

        $rebootBarrier = $false
        $workLimit = switch ($Action) {
            'Install' { [int](Get-PatchOption $run @('installConcurrency') 3) }
            'Reboot' { [int](Get-PatchOption $run @('rebootBatchSize') 1) }
            default { [int](Get-PatchOption $run @('scanConcurrency') 3) }
        }
        # Each rejected guest login of a domain account counts toward its lockout threshold. A credential rejected
        # on two VMs of its group and accepted by none in this step is not tried on the group's other VMs; they
        # get the same Retry / Skip / Stop choice. (One rejection alone may be a DMZ VM with its own account.)
        $credentialState = @{}
        $invokeVm = {
            param($VMRecord, [bool]$StartOnly)
            $group = [string]$VMRecord.accountGroup
            $guestCredential = $GuestCredentials[$group]
            if ([string]::IsNullOrWhiteSpace($group)) {
                return [pscustomobject]@{ status = 'Failed'; error = 'The VM was not found in vCenter; see the earlier Resolve error.' }
            }
            if ($null -eq $guestCredential) {
                return [pscustomobject]@{ status = 'Failed'; error = ('No guest credential was entered for {0}.' -f $group) }
            }
            if (-not $credentialState.ContainsKey($group)) { $credentialState[$group] = @{ accepted = $false; rejectedOn = @() } }
            $groupState = $credentialState[$group]
            if (-not $groupState.accepted -and $groupState.rejectedOn.Count -ge 2) {
                return [pscustomobject]@{ status = 'GuestCredentialRejected'; error = ('Not tried: the credential for {0} was rejected on {1}.' -f $group, ($groupState.rejectedOn -join ', ')) }
            }
            try {
                $vmResult = Invoke-PatchVmAction -Action $Action -RunPath $runFile -RunState $run -VMRecord $VMRecord -Server $connection.Servers[[string]$VMRecord.vCenter] -GuestCredential $guestCredential -StartOnly:$StartOnly
                # A result without an exception needed a guest login, except a reboot observation that timed out.
                if ([string]$vmResult.status -ne 'PendingRebootConfirmation') { $groupState.accepted = $true }
                $vmResult
            }
            catch {
                # Get-GuestContext raises InvalidCredentialException when the guest rejects the account;
                # the GUI then offers Retry, Skip or Stop (plan: step 1).
                # While waiting for a started agent or reboot, a lost contact leaves the step running; approving the
                # step again observes it (NeedsReview, not Failed).
                if ($_.Exception -is [System.Security.Authentication.InvalidCredentialException]) {
                    $groupState.rejectedOn += [string]$VMRecord.vmName
                    $code = 'GuestCredentialRejected'; $message = $_.Exception.Message
                }
                elseif (-not $StartOnly) { $code = 'NeedsReview'; $message = 'The started {0} could not be observed: {1}' -f $Action, $_.Exception.Message }
                else { $code = 'Failed'; $message = $_.Exception.Message }
                [pscustomobject]@{ status = $code; error = $message }
            }
        }

        # VMs that this action leaves out are recorded first, so a batch holds only VMs that run.
        $toRun = @()
        foreach ($vmRecord in $vmRecords) {
            $skip = $null
            $skipError = $null
            $membership = Get-PatchClusterMembership -VMRecord $vmRecord
            if ($vmRecord.status -eq 'SkippedGuestAccount') { $skip = 'SkippedGuestAccount' }
            elseif ($Action -eq 'Install' -and @(Get-PatchArray $vmRecord.selectedUpdates).Count -eq 0) { $skip = 'SkippedNoSelection' }
            elseif ($Action -eq 'Install' -and (Test-PatchInstallDone -VMRecord $vmRecord)) { $skip = 'SkippedInstalledThisRound' }
            elseif ($Action -eq 'Reboot' -and -not (Test-PatchVmRequiresReboot -VMRecord $vmRecord)) { $skip = 'SkippedNoReboot' }
            elseif ($Action -in @('Install', 'Reboot') -and $membership -ne 'NotMember') {
                # Plan: a configured cluster node is excluded; an unrecognised state blocks the VM and is an error.
                $skip = 'ExcludedCluster'
                if ($membership -ne 'Member') { $skipError = ('{0} is blocked because the cluster membership is {1}.' -f $Action, $membership) }
            }
            elseif ($ObserveOnly -and $Action -in @('Install', 'Reboot') -and -not (Test-PatchStepStarted -VMRecord $vmRecord -Action $Action)) { $skip = 'SkippedNotStarted' }
            elseif ($Action -in @('Install', 'Reboot') -and -not (Test-PatchStepStarted -VMRecord $vmRecord -Action $Action) -and
                $null -ne ($blocker = Get-PatchMutatingStepBlocker -RunState $run -VMRecord $vmRecord -CurrentStep $null)) {
                # Plan: an unclear result needs manual reconciliation before the next install or reboot of this VM.
                $skip = 'SkippedUnreviewedStep'
                $skipError = 'The {0} step of round {1} has no final result. Check the guest and use Mark steps reviewed.' -f $blocker.action, $blocker.round
            }
            if ($null -eq $skip) { $toRun += $vmRecord; continue }
            $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -Action $Action -Result ([pscustomobject]@{ status = $skip; error = $skipError }) -RebootBarrier ([ref]$rebootBarrier)
        }

        # Reboots already sent but not confirmed are observed first, in batches of their own; until they are
        # confirmed no new reboot is sent (plan: step 5), also when they are not part of this call (Retry).
        $observed = @($toRun | Where-Object { $Action -eq 'Reboot' -and (Test-PatchStepStarted -VMRecord $_ -Action 'Reboot') })
        $fresh = @($toRun | Where-Object { $observed -notcontains $_ })
        $runNames = @($toRun | ForEach-Object { [string]$_.vmName })
        if ($Action -eq 'Reboot' -and @(Get-PatchArray $run.vms | Where-Object { $runNames -notcontains [string]$_.vmName -and (Test-PatchStepStarted -VMRecord $_ -Action 'Reboot') }).Count -gt 0) {
            $rebootBarrier = $true
        }
        $batchSize = [Math]::Max(1, $workLimit)
        $batches = New-Object System.Collections.ArrayList
        foreach ($group in @(, $observed) + @(, $fresh)) {
            for ($index = 0; $index -lt $group.Count; $index += $batchSize) { [void]$batches.Add(@($group[$index..([Math]::Min($group.Count, $index + $batchSize) - 1)])) }
        }
        foreach ($batch in $batches) {
            # Start every VM of the batch, then wait for each; at most workLimit agents run at once.
            $started = @()
            foreach ($vmRecord in $batch) {
                if ($Action -eq 'Reboot' -and $rebootBarrier) {
                    $holding = @(Get-PatchArray $run.vms | Where-Object { Test-PatchStepStarted -VMRecord $_ -Action 'Reboot' } | ForEach-Object { [string]$_.vmName }) -join ', '
                    $barrierMessage = 'Not rebooted: the reboot of {0} is not confirmed yet. Approve Reboot again to observe it, or check the guest and use Mark steps reviewed.' -f $holding
                    $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -Action $Action -Result ([pscustomobject]@{ status = 'PendingRebootBarrier'; error = $barrierMessage }) -RebootBarrier ([ref]$rebootBarrier)
                    continue
                }
                Set-PatchValue -InputObject $vmRecord -Name 'currentAction' -Value $Action
                $result = & $invokeVm $vmRecord $true
                if ($result.status -eq 'Started') {
                    Set-PatchValue -InputObject $vmRecord -Name 'status' -Value 'Started'
                    Save-PatchDecision -RunPath $runFile -RunState $run
                    $started += $vmRecord
                }
                else {
                    $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -Action $Action -Result $result -RebootBarrier ([ref]$rebootBarrier)
                }
            }
            foreach ($vmRecord in $started) {
                $result = & $invokeVm $vmRecord $false
                $resultRows += Add-PatchVmResult -RunPath $runFile -RunState $run -VMRecord $vmRecord -Action $Action -Result $result -RebootBarrier ([ref]$rebootBarrier)
            }
        }

        # After a Retry for some VMs, the others keep their result of this step in the run status.
        $processedNames = @($vmRecords | ForEach-Object { [string]$_.vmName })
        $statusRows = @($resultRows) + @(Get-PatchArray $run.vms | Where-Object { $processedNames -notcontains [string]$_.vmName -and [string](Get-PatchValue $_ @('lastProcessedAction') '') -eq $Action } |
                ForEach-Object { [pscustomobject]@{ status = [string](Get-PatchValue $_ @('lastResult') ''); error = '' } })
        $needsReview = @($statusRows | Where-Object { $_.status -in @('NeedsReview', 'PendingRebootConfirmation', 'PendingRebootBarrier', 'SkippedUnreviewedStep') }).Count -gt 0
        $hasErrors = @($statusRows | Where-Object { $_.status -in @('Failed', 'CompletedWithErrors', 'GuestCredentialRejected') -or -not [string]::IsNullOrWhiteSpace([string]$_.error) }).Count -gt 0
        if ($needsReview) { Set-PatchValue -InputObject $run -Name 'status' -Value 'NeedsReview' }
        elseif ($hasErrors) { Set-PatchValue -InputObject $run -Name 'status' -Value 'CompletedWithErrors' }
        else { Set-PatchValue -InputObject $run -Name 'status' -Value 'Completed' }
        Save-PatchDecision -RunPath $runFile -RunState $run
        Write-PatchSummary -RunPath $runFile -RunState $run
        return [pscustomobject]@{ status = [string]$run.status; action = $Action; runId = [string]$run.runId; runPath = $runFile; vmResults = @($resultRows) }
    }
    catch {
        $message = Protect-PatchText $_.Exception.Message
        if ($null -ne $run) {
            $runFile = Get-PatchRunJsonPath -RunPath $RunPath
            $errorRecord = Write-PatchError -RunPath $runFile -Message $message -Step $Action -Code 'ControllerError'
            Set-PatchValue -InputObject $run -Name 'status' -Value 'Stopped'
            Set-PatchValue -InputObject $run -Name 'stopReason' -Value $message
            $runErrors = @(Get-PatchArray $run.errors)
            $runErrors += $errorRecord
            Set-PatchValue -InputObject $run -Name 'errors' -Value $runErrors
            Save-PatchDecision -RunPath $runFile -RunState $run
            Write-PatchEvent -RunPath $runFile -Message $message -Step $Action -Level 'ERROR'
            Write-PatchSummary -RunPath $runFile -RunState $run
            return [pscustomobject]@{ status = 'Stopped'; action = $Action; runId = [string]$run.runId; runPath = $runFile; vmResults = @($resultRows); error = $message }
        }
        throw
    }
    finally {
        if ($null -ne $connection) { foreach ($server in $connection.Servers.Values) { Disconnect-PatchVCenter -Server $server } }
    }
}
