# Offline core behavior checks for Windows Patch Wizard.
# Requires 64-bit Windows PowerShell 5.1. No vCenter, WUA, install, or reboot is used.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$controllerPath = Join-Path $repoRoot 'scripts\RunController.ps1'
$adapterPath = Join-Path $repoRoot 'scripts\GuestOps.ps1'

if (-not (Test-Path -LiteralPath $controllerPath -PathType Leaf)) {
    throw ('Controller script was not found: {0}' -f $controllerPath)
}
if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
    throw ('Guest Operations adapter was not found: {0}' -f $adapterPath)
}

. $adapterPath
. $controllerPath

$script:CoreCheckStartGuestAgentCalls = 0
$script:CoreCheckReadGuestStatusCalls = 0
$script:CoreCheckBootTimeCalls = 0
$script:CoreCheckBootTime = (Get-Date).ToUniversalTime().ToString('o')
$script:CoreCheckVmLookup = @()
$script:CoreCheckLastLookupName = $null
$script:CoreCheckLastLookupServer = $null
$script:CoreCheckStatusPayload = $null
$script:CoreCheckRebootStatusPayload = $null
$script:CoreCheckScanStatusPayloads = $null
$script:CoreCheckScanStatusIndex = 0
$script:CoreCheckFailureSecret = 'core-check-secret'
$script:CoreCheckClusterMembership = 'NotMember'
$script:CoreCheckConnectShouldFail = $true
$script:CoreCheckVCenterCertificateFlags = @()
$script:CoreCheckTransferCertificateFlags = @()
$script:CoreCheckGetVmCalls = 0
$script:CoreCheckGetGuestContextCalls = 0

function Assert-CoreTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-CoreEqual {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ('{0} Expected: [{1}] Actual: [{2}]' -f $Message, $Expected, $Actual)
    }
}

function Assert-CoreThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $thrown = $false
    $exceptionMessage = ''
    try {
        & $ScriptBlock
    }
    catch {
        $thrown = $true
        $exceptionMessage = [string]$_.Exception.Message
    }

    if (-not $thrown) {
        throw ('{0} No exception was raised.' -f $Message)
    }
    if ($exceptionMessage -notmatch $Pattern) {
        throw ('{0} Exception was: {1}' -f $Message, $exceptionMessage)
    }
}

function Invoke-CoreCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        Write-Host ('[PASS] {0}' -f $Name)
        return $true
    }
    catch {
        Write-Host ('[FAIL] {0}: {1}' -f $Name, $_.Exception.Message) -ForegroundColor Red
        $script:CoreCheckFailed = $true
        return $false
    }
}

$testRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('PatchWizard-CoreChecks-{0}' -f ([Guid]::NewGuid().ToString('N')))))
$script:CoreCheckFailed = $false

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $server = [pscustomobject]@{ Name = 'vcenter-double' }
    $uniqueVm = [pscustomobject]@{
        Name = 'APP[01]'
        Id = 'VirtualMachine-vm-01'
        PowerState = 'PoweredOn'
        ExtensionData = [pscustomobject]@{
            Guest = [pscustomobject]@{
                HostName = 'app-01.example.test'
                ToolsRunningStatus = 'guestToolsRunning'
            }
        }
    }
    $duplicateVm = [pscustomobject]@{
        Name = 'APP[01]'
        Id = 'VirtualMachine-vm-02'
        PowerState = 'PoweredOn'
        ExtensionData = [pscustomobject]@{
            Guest = [pscustomobject]@{
                HostName = 'app-01.example.test'
                ToolsRunningStatus = 'guestToolsRunning'
            }
        }
    }

    function Get-VM {
        [CmdletBinding()]
        param(
            [string]$Name,
            [object]$Server,
            [string]$Id
        )

        $script:CoreCheckGetVmCalls++
        $script:CoreCheckLastLookupName = $Name
        $script:CoreCheckLastLookupServer = $Server
        return $script:CoreCheckVmLookup
    }

    function Get-GuestContext {
        [CmdletBinding()]
        param(
            [object]$VM,
            [System.Management.Automation.PSCredential]$GuestCredential
        )

        $script:CoreCheckGetGuestContextCalls++
        return [pscustomobject]@{
            VM = $VM
            Fqdn = 'app-01.example.test'
            ProgramData = $testRoot
            clusterMembership = $script:CoreCheckClusterMembership
            ToolsRunning = $true
        }
    }

    Invoke-CoreCheck -Name 'Get-GuestProcess forwards Pid through the real adapter and returns terminal fields' -ScriptBlock {
        $terminalEndTime = (Get-Date).ToUniversalTime()
        $terminalProcess = [pscustomobject]@{ Pid = 2468; ExitCode = 17; EndTime = $terminalEndTime }
        $processManager = [pscustomobject]@{ Calls = @(); TerminalProcess = $terminalProcess }
        $processManager | Add-Member -MemberType ScriptMethod -Name ListProcessesInGuest -Value {
            param($MoRef, $GuestAuth, [long[]]$ProcessIds)
            $this.Calls += [pscustomobject]@{ MoRef = $MoRef; GuestAuth = $GuestAuth; ProcessIds = @($ProcessIds) }
            return @($this.TerminalProcess)
        }
        $context = [pscustomobject]@{
            ProcessManager = $processManager
            VMView = [pscustomobject]@{ MoRef = [pscustomobject]@{ Value = 'vm-ref' } }
            GuestAuth = [pscustomobject]@{ UserName = 'guest-double' }
        }

        $processes = @(Get-GuestProcess -Context $context -Pid 2468)
        Assert-CoreEqual -Expected 1 -Actual $processManager.Calls.Count -Message 'The ProcessManager was not called exactly once.'
        Assert-CoreEqual -Expected 2468 -Actual $processManager.Calls[0].ProcessIds[0] -Message 'The exact process ID was not forwarded.'
        Assert-CoreEqual -Expected 17 -Actual $processes[0].ExitCode -Message 'The terminal ExitCode was not returned.'
        Assert-CoreEqual -Expected $terminalEndTime -Actual $processes[0].EndTime -Message 'The terminal EndTime was not returned.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Get-PatchVM scopes a literal name to one vCenter VM' -ScriptBlock {
        $script:CoreCheckVmLookup = @($uniqueVm)
        $resolved = Get-PatchVM -Server $server -Name 'APP[01]' -ExpectedFqdn 'app-01.example.test'
        Assert-CoreTrue -Condition ([object]::ReferenceEquals($resolved, $uniqueVm)) -Message 'The resolved VM object was not returned.'
        Assert-CoreEqual -Expected 'APP`[01`]' -Actual $script:CoreCheckLastLookupName -Message 'The VM name was not escaped as a literal lookup.'
        Assert-CoreTrue -Condition ([object]::ReferenceEquals($server, $script:CoreCheckLastLookupServer)) -Message 'The VM lookup lost its vCenter server scope.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Get-PatchVM rejects duplicate names' -ScriptBlock {
        $script:CoreCheckVmLookup = @($uniqueVm, $duplicateVm)
        Assert-CoreThrows -ScriptBlock {
            Get-PatchVM -Server $server -Name 'APP[01]' -ExpectedFqdn 'app-01.example.test'
        } -Pattern 'Expected exactly one VM' -Message 'Duplicate VM names were accepted.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Install and Reboot block a VM whose cluster membership is Member' -ScriptBlock {
        $script:CoreCheckVmLookup = @($uniqueVm)
        $script:CoreCheckClusterMembership = 'Member'
        $clusterRunPath = Join-Path $testRoot 'cluster-run\run.json'
        New-Item -ItemType Directory -Path (Split-Path -Parent $clusterRunPath) -Force | Out-Null
        $clusterRun = [pscustomobject]@{
            runId = ([Guid]::NewGuid()).ToString('D')
            currentRound = 1
            options = [pscustomobject]@{ ignoreEsxiCertificatesForFileTransfers = $false }
        }

        foreach ($action in @('Install', 'Reboot')) {
            $record = [pscustomobject]@{
                vmName = 'APP[01]'
                expectedFqdn = 'app-01.example.test'
                vmId = $null
                currentRound = 1
                steps = @()
                agentStatus = $null
                selectedUpdates = @([pscustomobject]@{ updateId = 'KB-1'; revisionNumber = 1 })
            }
            Assert-CoreThrows -ScriptBlock {
                Invoke-PatchVmAction -Action $action -RunPath $clusterRunPath -RunState $clusterRun -VMRecord $record -Server $server -GuestCredential $null
            } -Pattern 'cluster membership is Member' -Message ("{0} was not blocked for cluster membership." -f $action)
        }
        $script:CoreCheckClusterMembership = 'NotMember'
    } | Out-Null

    function Receive-GuestFile {
        [CmdletBinding()]
        param(
            [object]$Context,
            [string]$GuestPath,
            [string]$LocalPath,
            [bool]$IgnoreEsxiCertificate = $false
        )

        $parent = Split-Path -Parent $LocalPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $json = $script:CoreCheckStatusPayload | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($LocalPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    $statusRunId = [Guid]::NewGuid()
    $statusStepId = [Guid]::NewGuid()
    $statusContext = [pscustomobject]@{ ProgramData = $testRoot }
    $statusLocalPath = Join-Path $testRoot 'terminal-status.json'

    Invoke-CoreCheck -Name 'Read-GuestStatus accepts matching terminal identity and finishedAt' -ScriptBlock {
        $script:CoreCheckStatusPayload = [pscustomobject]@{
            runId = $statusRunId.ToString('D')
            stepId = $statusStepId.ToString('D')
            mode = 'Install'
            status = 'Completed'
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $status = Read-GuestStatus -Context $statusContext -RunId $statusRunId -StepId $statusStepId -ExpectedMode 'Install' -LocalPath $statusLocalPath
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$status.status) -Message 'The terminal status was not returned.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Read-GuestStatus rejects mismatched identity, mode, and missing terminal evidence' -ScriptBlock {
        $script:CoreCheckStatusPayload = [pscustomobject]@{
            runId = ([Guid]::NewGuid()).ToString('D')
            stepId = $statusStepId.ToString('D')
            mode = 'Install'
            status = 'Completed'
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Assert-CoreThrows -ScriptBlock {
            Read-GuestStatus -Context $statusContext -RunId $statusRunId -StepId $statusStepId -ExpectedMode 'Install' -LocalPath $statusLocalPath
        } -Pattern 'runId' -Message 'A mismatched runId was accepted.'

        $script:CoreCheckStatusPayload.runId = $statusRunId.ToString('D')
        $script:CoreCheckStatusPayload.mode = 'Scan'
        Assert-CoreThrows -ScriptBlock {
            Read-GuestStatus -Context $statusContext -RunId $statusRunId -StepId $statusStepId -ExpectedMode 'Install' -LocalPath $statusLocalPath
        } -Pattern 'mode' -Message 'A mismatched mode was accepted.'

        $script:CoreCheckStatusPayload.mode = 'Install'
        $script:CoreCheckStatusPayload.finishedAt = $null
        Assert-CoreThrows -ScriptBlock {
            Read-GuestStatus -Context $statusContext -RunId $statusRunId -StepId $statusStepId -ExpectedMode 'Install' -LocalPath $statusLocalPath
        } -Pattern 'finishedAt' -Message 'A terminal status without finishedAt was accepted.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Read-GuestStatus permits a nonterminal Started status without finishedAt' -ScriptBlock {
        $script:CoreCheckStatusPayload = [pscustomobject]@{
            runId = $statusRunId.ToString('D')
            stepId = $statusStepId.ToString('D')
            mode = 'Install'
            status = 'Started'
        }
        $status = Read-GuestStatus -Context $statusContext -RunId $statusRunId -StepId $statusStepId -ExpectedMode 'Install' -LocalPath $statusLocalPath
        Assert-CoreEqual -Expected 'Started' -Actual ([string]$status.status) -Message 'The nonterminal status was not returned.'
    } | Out-Null

    Invoke-CoreCheck -Name 'New-PatchRun stores independent certificate flags and excludes secrets' -ScriptBlock {
        $entry = @([pscustomobject]@{ VmName = 'APP-01'; ExpectedFqdn = 'app-01.example.test' })
        $configurations = @(
            [pscustomobject]@{
                RunsRoot = (Join-Path $testRoot 'certificate-run-vcenter')
                IgnoreVCenterCertificate = $true
                IgnoreEsxiCertificatesForFileTransfers = $false
            },
            [pscustomobject]@{
                RunsRoot = (Join-Path $testRoot 'certificate-run-esxi')
                IgnoreVCenterCertificate = $false
                IgnoreEsxiCertificatesForFileTransfers = $true
            }
        )

        $runs = @()
        foreach ($choice in $configurations) {
            $config = [pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = $choice.RunsRoot
                Options = [pscustomobject]@{
                    IgnoreVCenterCertificate = $choice.IgnoreVCenterCertificate
                    IgnoreEsxiCertificatesForFileTransfers = $choice.IgnoreEsxiCertificatesForFileTransfers
                }
                Password = $script:CoreCheckFailureSecret
                Credential = [pscustomobject]@{ UserName = 'operator'; Password = $script:CoreCheckFailureSecret }
            }
            $run = New-PatchRun -Config $config -VMEntries $entry
            Set-PatchValue -InputObject $run -Name 'password' -Value $script:CoreCheckFailureSecret
            Set-PatchValue -InputObject $run -Name 'credential' -Value ([pscustomobject]@{ UserName = 'operator'; Password = $script:CoreCheckFailureSecret })
            Write-PatchRun -RunPath ([string]$run.runPath) -RunState $run | Out-Null
            $runs += $run
        }

        $firstJson = Get-Content -LiteralPath ([string]$runs[0].runPath) -Raw
        $secondJson = Get-Content -LiteralPath ([string]$runs[1].runPath) -Raw
        Assert-CoreEqual -Expected $true -Actual ([bool]$runs[0].options.ignoreVCenterCertificate) -Message 'The vCenter certificate flag was not stored in the first variant.'
        Assert-CoreEqual -Expected $false -Actual ([bool]$runs[0].options.ignoreEsxiCertificatesForFileTransfers) -Message 'The ESXi certificate flag was enabled unexpectedly in the first variant.'
        Assert-CoreEqual -Expected $false -Actual ([bool]$runs[1].options.ignoreVCenterCertificate) -Message 'The vCenter certificate flag was enabled unexpectedly in the second variant.'
        Assert-CoreEqual -Expected $true -Actual ([bool]$runs[1].options.ignoreEsxiCertificatesForFileTransfers) -Message 'The ESXi certificate flag was not stored in the second variant.'
        Assert-CoreTrue -Condition ($firstJson -notmatch [regex]::Escape($script:CoreCheckFailureSecret) -and $secondJson -notmatch [regex]::Escape($script:CoreCheckFailureSecret)) -Message 'A secret was written to run.json.'
    } | Out-Null

    function Connect-PatchVCenter {
        [CmdletBinding()]
        param(
            [string]$ServerName,
            [System.Management.Automation.PSCredential]$Credential,
            [bool]$IgnoreVCenterCertificate = $false
        )

        $script:CoreCheckVCenterCertificateFlags += [bool]$IgnoreVCenterCertificate
        if ($script:CoreCheckConnectShouldFail) {
            throw ('offline controller double failed for {0}' -f $script:CoreCheckFailureSecret)
        }
        return $server
    }

    Invoke-CoreCheck -Name 'Fresh controller import resolves the Guest Operations adapter inside action scope' -ScriptBlock {
        $freshRunRoot = Join-Path $testRoot 'fresh-controller-import'
        $freshControllerPath = $controllerPath.Replace("'", "''")
        $freshRunRootQuoted = $freshRunRoot.Replace("'", "''")
        $freshCommand = @'
function Import-Module {
    [CmdletBinding()]
    param([string]$Name)
}
function Set-PowerCLIConfiguration {
    [CmdletBinding()]
    param([string]$Scope, [string]$InvalidCertificateAction, [switch]$Confirm)
}
function Connect-VIServer {
    [CmdletBinding()]
    param([string]$Server, [System.Management.Automation.PSCredential]$Credential)
    throw 'AdapterConnectDouble'
}
. '__CONTROLLER__'
$secure = ConvertTo-SecureString -String 'offline-password' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential('operator', $secure)
$run = New-PatchRun -Config ([pscustomobject]@{ VCenter = 'offline-double'; RunsRoot = '__RUNROOT__' }) -VMEntries @([pscustomobject]@{ VmName = 'APP-01'; ExpectedFqdn = 'app-01.example.test' })
$result = Invoke-PatchAction -Action Scan -RunPath ([string]$run.runPath) -VCenterCredential $credential -GuestCredential $credential
$saved = Read-PatchRun -RunPath ([string]$run.runPath)
Write-Output ('result={0};stop={1}' -f $result.status, $saved.stopReason)
'@
        $freshCommand = $freshCommand.Replace('__CONTROLLER__', $freshControllerPath).Replace('__RUNROOT__', $freshRunRootQuoted)
        $freshOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $freshCommand 2>&1)
        $freshText = ($freshOutput | ForEach-Object { [string]$_ }) -join "`n"
        Assert-CoreTrue -Condition ($freshText -match 'AdapterConnectDouble') -Message ('The fresh controller process did not resolve GuestOps.ps1 in Invoke-PatchAction. Output: {0}' -f $freshText)
        Assert-CoreTrue -Condition ($freshText -notmatch '(?i)Connect-PatchVCenter.*not recognized|term .*Connect-PatchVCenter') -Message ('The fresh controller process reported a missing adapter command. Output: {0}' -f $freshText)
    } | Out-Null

    Invoke-CoreCheck -Name 'Invoke-PatchAction writes errors and summary immediately on controller failure' -ScriptBlock {
        $runRoot = Join-Path $testRoot 'failure-run'
        $run = New-PatchRun -Config ([pscustomobject]@{ VCenter = 'vcenter-double'; RunsRoot = $runRoot }) -VMEntries @([pscustomobject]@{ VmName = 'APP-01'; ExpectedFqdn = 'app-01.example.test' })
        $secure = ConvertTo-SecureString -String $script:CoreCheckFailureSecret -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential('operator', $secure)
        $result = Invoke-PatchAction -Action Scan -RunPath ([string]$run.runPath) -VCenterCredential $credential -GuestCredential $credential
        $runDirectory = Split-Path -Parent ([string]$run.runPath)
        $errorsPath = Join-Path $runDirectory 'errors.log'
        $summaryPath = Join-Path $runDirectory 'summary.md'
        $errors = Get-Content -LiteralPath $errorsPath -Raw
        $summary = Get-Content -LiteralPath $summaryPath -Raw
        $saved = Get-Content -LiteralPath ([string]$run.runPath) -Raw | ConvertFrom-Json
        Assert-CoreEqual -Expected 'Stopped' -Actual ([string]$result.status) -Message 'The immediate controller failure did not stop the run.'
        Assert-CoreTrue -Condition (Test-Path -LiteralPath $errorsPath -PathType Leaf) -Message 'errors.log was not written immediately.'
        Assert-CoreTrue -Condition (Test-Path -LiteralPath $summaryPath -PathType Leaf) -Message 'summary.md was not written immediately.'
        Assert-CoreTrue -Condition ($errors -match 'ControllerError') -Message 'The controller error code was not written.'
        Assert-CoreTrue -Condition ($summary -match '# Patch run summary') -Message 'The summary header was not written.'
        Assert-CoreEqual -Expected 'Stopped' -Actual ([string]$saved.status) -Message 'run.json did not persist the stopped state.'
        Assert-CoreTrue -Condition ($errors -notmatch [regex]::Escape($script:CoreCheckFailureSecret) -and $summary -notmatch [regex]::Escape($script:CoreCheckFailureSecret)) -Message 'The failure secret leaked into output.'
    } | Out-Null

    function Test-GuestTransferEndpoint {
        [CmdletBinding()]
        param(
            [object]$Context,
            [bool]$IgnoreEsxiCertificate = $false
        )

        $script:CoreCheckTransferCertificateFlags += [bool]$IgnoreEsxiCertificate
        return [pscustomobject]@{ Reachable = $true }
    }

    function Send-GuestFile {
        [CmdletBinding()]
        param(
            [object]$Context,
            [string]$LocalPath,
            [string]$GuestPath,
            [bool]$IgnoreEsxiCertificate = $false
        )

        $script:CoreCheckTransferCertificateFlags += [bool]$IgnoreEsxiCertificate
        return [pscustomobject]@{ LocalPath = $LocalPath; GuestPath = $GuestPath }
    }

    function Start-GuestAgent {
        [CmdletBinding()]
        param(
            [object]$Context,
            [string]$GuestAgentPath,
            [ValidateSet('Scan', 'Install', 'Reboot')][string]$Mode,
            [Guid]$RunId,
            [Guid]$StepId,
            [string]$SelectionPath
        )

        $script:CoreCheckStartGuestAgentCalls++
        return [int64](1000 + $script:CoreCheckStartGuestAgentCalls)
    }

    function Read-GuestStatus {
        [CmdletBinding()]
        param(
            [object]$Context,
            [Guid]$RunId,
            [Guid]$StepId,
            [ValidateSet('Scan', 'Install', 'Reboot')][string]$ExpectedMode,
            [string]$LocalPath,
            [bool]$IgnoreEsxiCertificate = $false
        )

        $script:CoreCheckReadGuestStatusCalls++
        if ($ExpectedMode -eq 'Reboot' -and $null -ne $script:CoreCheckRebootStatusPayload) {
            return $script:CoreCheckRebootStatusPayload
        }
        if ($ExpectedMode -eq 'Scan' -and $null -ne $script:CoreCheckScanStatusPayloads) {
            $payloads = @($script:CoreCheckScanStatusPayloads)
            $payloadIndex = [Math]::Min($script:CoreCheckScanStatusIndex, $payloads.Count - 1)
            $payload = $payloads[$payloadIndex]
            $script:CoreCheckScanStatusIndex++
            $payloadStatus = 'Completed'
            if ($null -ne $payload.PSObject.Properties['status']) { $payloadStatus = [string]$payload.status }
            $payloadError = $null
            if ($null -ne $payload.PSObject.Properties['error']) { $payloadError = [string]$payload.error }
            return [pscustomobject]@{
                runId = $RunId.ToString('D')
                stepId = $StepId.ToString('D')
                mode = $ExpectedMode
                status = $payloadStatus
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
                error = $payloadError
                updates = @($payload.updates)
            }
        }
        $state = if ($ExpectedMode -eq 'Reboot') { 'RebootRequested' } else { 'Completed' }
        return [pscustomobject]@{
            runId = $RunId.ToString('D')
            stepId = $StepId.ToString('D')
            mode = $ExpectedMode
            status = $state
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            updates = @()
        }
    }

    function Read-GuestBootTime {
        [CmdletBinding()]
        param([object]$Context, [bool]$IgnoreEsxiCertificate)

        $script:CoreCheckBootTimeCalls++
        return $script:CoreCheckBootTime
    }

    function Receive-GuestFile {
        [CmdletBinding()]
        param(
            [object]$Context,
            [string]$GuestPath,
            [string]$LocalPath,
            [bool]$IgnoreEsxiCertificate = $false
        )

        return [pscustomobject]@{ LocalPath = $LocalPath; GuestPath = $GuestPath }
    }

    Invoke-CoreCheck -Name 'Patch progress markers reset, persist, and count the current action only' -ScriptBlock {
        $script:CoreCheckConnectShouldFail = $false
        $script:CoreCheckVmLookup = @($uniqueVm)
        $script:CoreCheckClusterMembership = 'NotMember'
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

            if ([string](Get-PatchValue $VMRecord @('vmName') '') -eq 'APP-03') {
                return [pscustomobject]@{ status = 'Failed'; error = 'offline scan failure' }
            }
            return [pscustomobject]@{ status = 'Completed'; error = $null }
        }
        $secure = ConvertTo-SecureString -String 'offline-progress-password' -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential('operator', $secure)
        $progressRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'progress-markers')
                Options = [pscustomobject]@{ scanConcurrency = 3 }
            }) -VMEntries @(
                [pscustomobject]@{ VmName = 'APP-01'; ExpectedFqdn = 'app-01.example.test' }
                [pscustomobject]@{ VmName = 'APP-02'; ExpectedFqdn = 'app-01.example.test' }
                [pscustomobject]@{ VmName = 'APP-03'; ExpectedFqdn = 'app-01.example.test' }
                [pscustomobject]@{ VmName = 'APP-04'; ExpectedFqdn = 'app-01.example.test' }
            )
        $progressRunPath = [string]$progressRun.runPath
        $progressState = Read-PatchRun -RunPath $progressRunPath
        $progressVms = @($progressState.vms)
        foreach ($vm in $progressVms) {
            Set-PatchValue -InputObject $vm -Name 'status' -Value 'Completed'
            Set-PatchValue -InputObject $vm -Name 'currentAction' -Value 'Previous'
            Set-PatchValue -InputObject $vm -Name 'lastProcessedAction' -Value 'Previous'
        }
        $skipKey = Get-PatchGuestAccountKey -RunState $progressState -GuestCredential $credential -VMRecord $progressVms[1]
        Set-PatchValue -InputObject $progressState -Name 'skippedGuestAccounts' -Value @($skipKey)
        Write-PatchRun -RunPath $progressRunPath -RunState $progressState | Out-Null

        $progressResult = Invoke-PatchAction -Action Scan -RunPath $progressRunPath -VCenterCredential $credential -GuestCredential $credential
        $savedProgress = Read-PatchRun -RunPath $progressRunPath
        $savedProgressVms = @($savedProgress.vms)
        Assert-CoreEqual -Expected 'CompletedWithErrors' -Actual ([string]$progressResult.status) -Message 'A failed VM did not mark the action as completed with errors.'
        Assert-CoreEqual -Expected 'Scan' -Actual ([string]$savedProgress.currentAction) -Message 'The current run action was not persisted.'
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$savedProgressVms[0].status) -Message 'The completed VM result was not preserved.'
        Assert-CoreEqual -Expected 'SkippedGuestAccount' -Actual ([string]$savedProgressVms[1].status) -Message 'The skipped VM result was not preserved.'
        Assert-CoreEqual -Expected 'Failed' -Actual ([string]$savedProgressVms[2].status) -Message 'The failed VM result was not preserved.'
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$savedProgressVms[3].status) -Message 'A failed VM blocked the next VM.'
        foreach ($vm in $savedProgressVms) {
            Assert-CoreEqual -Expected 'Scan' -Actual ([string]$vm.lastProcessedAction) -Message 'A processed VM did not persist the current action marker.'
        }
        Assert-CoreTrue -Condition ([string]::IsNullOrWhiteSpace([string]$savedProgressVms[1].currentAction)) -Message 'A skipped or barrier VM retained a stale current action.'
        Assert-CoreTrue -Condition (@(@(Get-PatchArray -Value $savedProgressVms[2].errors) | Where-Object { $_.code -eq 'PatchActionFailed' }).Count -eq 1) -Message 'The representative error was not persisted.'

        $script:CoreCheckConnectShouldFail = $true
        $resetResult = Invoke-PatchAction -Action Verify -RunPath $progressRunPath -VCenterCredential $credential -GuestCredential $credential
        $resetState = Read-PatchRun -RunPath $progressRunPath
        Assert-CoreEqual -Expected 'Stopped' -Actual ([string]$resetResult.status) -Message 'The reset checkpoint did not stop on the controlled connection failure.'
        Assert-CoreEqual -Expected 'Verify' -Actual ([string]$resetState.currentAction) -Message 'The next action was not persisted before the connection failure.'
        foreach ($vm in @($resetState.vms)) {
            Assert-CoreTrue -Condition ([string]::IsNullOrWhiteSpace([string]$vm.currentAction) -and [string]::IsNullOrWhiteSpace([string]$vm.lastProcessedAction)) -Message 'The next action did not reset the VM progress markers before processing.'
        }
        $script:CoreCheckConnectShouldFail = $false

        $wizardPath = Join-Path $repoRoot 'Start-PatchWizard.ps1'
        $wizardTokens = $null
        $wizardErrors = $null
        $wizardAst = [System.Management.Automation.Language.Parser]::ParseFile($wizardPath, [ref]$wizardTokens, [ref]$wizardErrors)
        if ($wizardErrors.Count -gt 0) {
            throw ('Wizard parse failed: {0}' -f (($wizardErrors | ForEach-Object { $_.ToString() }) -join '; '))
        }
        foreach ($functionName in @('Get-WizardProperty', 'Get-WizardArray', 'Update-WizardProgress')) {
            $functionAst = @($wizardAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true))[0]
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
        $script:Wizard = [pscustomobject]@{
            Controls = [pscustomobject]@{
                ProgressBar = [pscustomobject]@{ Value = 0 }
                ProgressLabel = [pscustomobject]@{ Text = '' }
            }
            RunState = [pscustomobject]@{
                currentAction = 'Verify'
                vms = @(
                    [pscustomobject]@{ status = 'Completed'; lastProcessedAction = 'Scan' }
                    [pscustomobject]@{ status = 'Started'; lastProcessedAction = 'Verify' }
                    [pscustomobject]@{ status = 'NeedsReview'; lastProcessedAction = 'Verify' }
                )
            }
        }
        Update-WizardProgress
        Assert-CoreEqual -Expected 66 -Actual $script:Wizard.Controls.ProgressBar.Value -Message 'Progress counted a stale VM marker.'
        Assert-CoreEqual -Expected 'Verify: 2 of 3 VM rows processed' -Actual $script:Wizard.Controls.ProgressLabel.Text -Message 'Progress text did not describe the current action.'
        $script:Wizard.RunState.vms = @(1..200 | ForEach-Object {
                [pscustomobject]@{ status = 'Started'; lastProcessedAction = if ($_ -lt 200) { 'Verify' } else { 'Scan' } }
            })
        Update-WizardProgress
        Assert-CoreEqual -Expected 99 -Actual $script:Wizard.Controls.ProgressBar.Value -Message 'Progress reached 100% with one VM still pending.'
        $script:Wizard.RunState.vms[199].lastProcessedAction = 'Verify'
        Update-WizardProgress
        Assert-CoreEqual -Expected 100 -Actual $script:Wizard.Controls.ProgressBar.Value -Message 'Progress did not reach 100% after every VM was processed.'
        $script:Wizard.RunState.currentAction = $null
        Update-WizardProgress
        Assert-CoreEqual -Expected 0 -Actual $script:Wizard.Controls.ProgressBar.Value -Message 'Progress was nonzero without a current action.'
        Assert-CoreEqual -Expected 'No action: 0 of 200 VM rows processed' -Actual $script:Wizard.Controls.ProgressLabel.Text -Message 'No-action progress text was incorrect.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Certificate flags reach their own vCenter and ESXi channels' -ScriptBlock {
        $script:CoreCheckConnectShouldFail = $false
        $script:CoreCheckVmLookup = @($uniqueVm)
        $script:CoreCheckClusterMembership = 'NotMember'
        $script:CoreCheckVCenterCertificateFlags = @()
        $script:CoreCheckTransferCertificateFlags = @()
        $channelEntry = @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })

        $vcenterRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'channel-vcenter')
                Options = [pscustomobject]@{
                    IgnoreVCenterCertificate = $true
                    IgnoreEsxiCertificatesForFileTransfers = $false
                }
            }) -VMEntries $channelEntry
        $esxiRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'channel-esxi')
                Options = [pscustomobject]@{
                    IgnoreVCenterCertificate = $false
                    IgnoreEsxiCertificatesForFileTransfers = $true
                }
            }) -VMEntries $channelEntry

        $channelCredential = New-Object System.Management.Automation.PSCredential('operator', (ConvertTo-SecureString -String $script:CoreCheckFailureSecret -AsPlainText -Force))
        $vcenterResult = Invoke-PatchAction -Action Scan -RunPath ([string]$vcenterRun.runPath) -VCenterCredential $channelCredential -GuestCredential $channelCredential
        $esxiResult = Invoke-PatchAction -Action Scan -RunPath ([string]$esxiRun.runPath) -VCenterCredential $channelCredential -GuestCredential $channelCredential

        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$vcenterResult.status) -Message ('The vCenter-only certificate variant did not complete: {0}' -f (($vcenterResult.vmResults | ConvertTo-Json -Depth 8 -Compress)))
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$esxiResult.status) -Message ('The ESXi-only certificate variant did not complete: {0}' -f (($esxiResult.vmResults | ConvertTo-Json -Depth 8 -Compress)))
        Assert-CoreEqual -Expected 2 -Actual $script:CoreCheckVCenterCertificateFlags.Count -Message 'The vCenter channel was not observed for both variants.'
        Assert-CoreEqual -Expected $true -Actual $script:CoreCheckVCenterCertificateFlags[0] -Message 'The vCenter ignore flag was not passed for the first variant.'
        Assert-CoreEqual -Expected $false -Actual $script:CoreCheckVCenterCertificateFlags[1] -Message 'The vCenter ignore flag leaked from the first variant.'
        Assert-CoreEqual -Expected 4 -Actual $script:CoreCheckTransferCertificateFlags.Count -Message 'The ESXi transfer channel was not observed for both actions.'
        Assert-CoreTrue -Condition ((-not $script:CoreCheckTransferCertificateFlags[0]) -and (-not $script:CoreCheckTransferCertificateFlags[1])) -Message 'The first variant enabled insecure ESXi transfers.'
        Assert-CoreTrue -Condition ($script:CoreCheckTransferCertificateFlags[2] -and $script:CoreCheckTransferCertificateFlags[3]) -Message 'The second variant did not enable insecure ESXi transfers.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Guest account skips stay opaque, isolate local VMs, and block rejected actions' -ScriptBlock {
        $script:CoreCheckConnectShouldFail = $false
        $script:CoreCheckVmLookup = @($uniqueVm)
        $script:CoreCheckGetVmCalls = 0
        $script:CoreCheckGetGuestContextCalls = 0
        $password = ConvertTo-SecureString -String 'offline-guest-password' -AsPlainText -Force
        $localCredential = New-Object System.Management.Automation.PSCredential('.\PatchAdmin', $password)
        $domainCredential = New-Object System.Management.Automation.PSCredential('CONTOSO\PatchAdmin', $password)

        $accountRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'guest-account-keys')
            }) -VMEntries @(
                [pscustomobject]@{ VmName = 'APP-LOCAL-01'; ExpectedFqdn = 'app-local-01.example.test' },
                [pscustomobject]@{ VmName = 'APP-LOCAL-02'; ExpectedFqdn = 'app-local-02.example.test' }
            )
        $accountState = Read-PatchRun -RunPath ([string]$accountRun.runPath)
        $accountVms = @($accountState.vms)
        Set-PatchValue -InputObject $accountVms[0] -Name 'vmId' -Value 'VirtualMachine-local-01'
        Set-PatchValue -InputObject $accountVms[1] -Name 'vmId' -Value 'VirtualMachine-local-02'

        $localKeyFirst = Get-PatchGuestAccountKey -RunState $accountState -GuestCredential $localCredential -VMRecord $accountVms[0]
        $localKeySecond = Get-PatchGuestAccountKey -RunState $accountState -GuestCredential $localCredential -VMRecord $accountVms[1]
        Assert-CoreTrue -Condition ($localKeyFirst -ne $localKeySecond) -Message 'A local account skip key was shared between two VMs.'
        Set-PatchValue -InputObject $accountState -Name 'skippedGuestAccounts' -Value @($localKeyFirst)
        Assert-CoreTrue -Condition (Test-PatchGuestAccountSkipped -RunState $accountState -VMRecord $accountVms[0] -GuestCredential $localCredential) -Message 'The skipped local account was not recognized on its VM.'
        Assert-CoreTrue -Condition (-not (Test-PatchGuestAccountSkipped -RunState $accountState -VMRecord $accountVms[1] -GuestCredential $localCredential)) -Message 'A local account skip leaked to another VM.'

        $domainKeyFirst = Get-PatchGuestAccountKey -RunState $accountState -GuestCredential $domainCredential -VMRecord $accountVms[0]
        $domainKeySecond = Get-PatchGuestAccountKey -RunState $accountState -GuestCredential $domainCredential -VMRecord $accountVms[1]
        Assert-CoreEqual -Expected $domainKeyFirst -Actual $domainKeySecond -Message 'The domain account key was not shared across VM scope.'
        Set-PatchValue -InputObject $accountState -Name 'skippedGuestAccounts' -Value @($domainKeyFirst)
        Assert-CoreTrue -Condition ((Test-PatchGuestAccountSkipped -RunState $accountState -VMRecord $accountVms[0] -GuestCredential $domainCredential) -and (Test-PatchGuestAccountSkipped -RunState $accountState -VMRecord $accountVms[1] -GuestCredential $domainCredential)) -Message 'The domain account skip was not recognized on both VMs.'
        Write-PatchRun -RunPath ([string]$accountRun.runPath) -RunState $accountState | Out-Null
        $accountJson = Get-Content -LiteralPath ([string]$accountRun.runPath) -Raw
        $savedKeys = @(Get-PatchArray -Value (Get-PatchValue (Read-PatchRun -RunPath ([string]$accountRun.runPath)) @('skippedGuestAccounts') @()))
        Assert-CoreEqual -Expected 1 -Actual $savedKeys.Count -Message 'The run persisted an unexpected number of skipped account entries.'
        Assert-CoreTrue -Condition ([string]$savedKeys[0] -match '^sha256:[0-9a-f]{64}$') -Message 'The persisted skipped account entry was not an opaque SHA-256 key.'
        Assert-CoreTrue -Condition ($accountJson -notmatch [regex]::Escape($localCredential.UserName) -and $accountJson -notmatch [regex]::Escape($domainCredential.UserName)) -Message 'A guest username was written to run.json.'

        $rejectedRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'guest-account-rejected')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP-REJECT'; ExpectedFqdn = 'app-reject.example.test' })
        $rejectedState = Read-PatchRun -RunPath ([string]$rejectedRun.runPath)
        $rejectedVm = @($rejectedState.vms)[0]
        Set-PatchValue -InputObject $rejectedVm -Name 'status' -Value 'GuestCredentialRejected'
        Write-PatchRun -RunPath ([string]$rejectedRun.runPath) -RunState $rejectedState | Out-Null
        $rejectedResult = Invoke-PatchAction -Action Scan -RunPath ([string]$rejectedRun.runPath) -VCenterCredential $domainCredential -GuestCredential $domainCredential
        $savedRejectedVm = @((Read-PatchRun -RunPath ([string]$rejectedRun.runPath)).vms)[0]
        Assert-CoreEqual -Expected 'NeedsReview' -Actual ([string]$rejectedResult.status) -Message 'A rejected guest credential did not pause the action for operator decision.'
        Assert-CoreEqual -Expected 'GuestCredentialRejectedPendingDecision' -Actual ([string]$savedRejectedVm.status) -Message 'The rejected guest credential state was not persisted as pending decision.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckGetVmCalls -Message 'Invoke-PatchAction looked up a VM before the credential decision.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckGetGuestContextCalls -Message 'Invoke-PatchAction opened Guest Operations before the credential decision.'
    } | Out-Null

    $resumeContext = [pscustomobject]@{
        ProgramData = $testRoot
        VM = [pscustomobject]@{ Name = 'APP[01]' }
    }

    Invoke-CoreCheck -Name 'Resumed install does not start the guest agent twice' -ScriptBlock {
        $script:CoreCheckStartGuestAgentCalls = 0
        $installRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'resume-install')
                Options = [pscustomobject]@{ IgnoreEsxiCertificatesForFileTransfers = $false }
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $installRunPath = [string]$installRun.runPath
        $installState = Read-PatchRun -RunPath $installRunPath
        $installVm = @($installState.vms)[0]
        Set-PatchValue -InputObject $installVm -Name 'selectedUpdates' -Value @([pscustomobject]@{ updateId = 'KB-1'; revisionNumber = 1 })
        Write-PatchRun -RunPath $installRunPath -RunState $installState | Out-Null

        $firstState = Read-PatchRun -RunPath $installRunPath
        $firstVm = @($firstState.vms)[0]
        $first = Invoke-PatchAgentStep -Action 'Install' -RunPath $installRunPath -RunState $firstState -VMRecord $firstVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        $afterFirstState = Read-PatchRun -RunPath $installRunPath
        $afterFirstVm = @($afterFirstState.vms)[0]
        $second = Invoke-PatchAgentStep -Action 'Install' -RunPath $installRunPath -RunState $afterFirstState -VMRecord $afterFirstVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        $afterSecondState = Read-PatchRun -RunPath $installRunPath
        $afterSecondStep = @(@($afterSecondState.vms)[0].steps)[0]
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$first.status) -Message 'The first install did not complete in the double.'
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$second.status) -Message 'The resumed install did not observe completion.'
        Assert-CoreTrue -Condition ([bool](@($afterFirstVm.steps)[0].startAttempted)) -Message 'The first install did not persist startAttempted in run.json.'
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$afterSecondStep.status) -Message 'The resumed install did not preserve the terminal step state.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The resumed install started the guest agent more than once.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Resumed reboot does not start the guest agent twice' -ScriptBlock {
        $script:CoreCheckStartGuestAgentCalls = 0
        $rebootRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'resume-reboot')
                Options = [pscustomobject]@{ IgnoreEsxiCertificatesForFileTransfers = $false }
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $rebootRunPath = [string]$rebootRun.runPath
        $firstState = Read-PatchRun -RunPath $rebootRunPath
        $firstVm = @($firstState.vms)[0]
        $first = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $rebootRunPath -RunState $firstState -VMRecord $firstVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        $afterFirstState = Read-PatchRun -RunPath $rebootRunPath
        $afterFirstVm = @($afterFirstState.vms)[0]
        $second = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $rebootRunPath -RunState $afterFirstState -VMRecord $afterFirstVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        $afterSecondState = Read-PatchRun -RunPath $rebootRunPath
        $afterSecondStep = @(@($afterSecondState.vms)[0].steps)[0]
        Assert-CoreEqual -Expected 'RebootRequested' -Actual ([string]$first.status) -Message 'The first reboot did not record dispatch evidence in the double.'
        Assert-CoreEqual -Expected 'RebootRequested' -Actual ([string]$second.status) -Message 'The resumed reboot did not preserve dispatch evidence.'
        Assert-CoreTrue -Condition ([bool](@($afterFirstVm.steps)[0].startAttempted)) -Message 'The first reboot did not persist startAttempted in run.json.'
        Assert-CoreEqual -Expected 'RebootRequested' -Actual ([string]$afterSecondStep.status) -Message 'The resumed reboot did not preserve dispatch evidence.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The resumed reboot started the guest agent more than once.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Verify starts a fresh scan after a terminal result and resumes an interrupted step once' -ScriptBlock {
        try {
            $script:CoreCheckStartGuestAgentCalls = 0
            $script:CoreCheckReadGuestStatusCalls = 0
            $script:CoreCheckScanStatusIndex = 0
            $script:CoreCheckScanStatusPayloads = @(
                [pscustomobject]@{ updates = @([pscustomobject]@{ updateId = 'KB-OLD'; revisionNumber = 1 }) },
                [pscustomobject]@{ updates = @([pscustomobject]@{ updateId = 'KB-NEW'; revisionNumber = 2 }) }
            )
            $verifyRun = New-PatchRun -Config ([pscustomobject]@{
                    VCenter = 'vcenter-double'
                    RunsRoot = (Join-Path $testRoot 'verify-fresh-scan')
                }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
            $verifyRunPath = [string]$verifyRun.runPath
            $verifyState = Read-PatchRun -RunPath $verifyRunPath
            $verifyVm = @($verifyState.vms)[0]
            $firstVerify = Invoke-PatchAgentStep -Action 'Verify' -RunPath $verifyRunPath -RunState $verifyState -VMRecord $verifyVm -VM $null -Context $resumeContext -TimeoutMinutes 1
            Assert-CoreEqual -Expected 'Completed' -Actual ([string]$firstVerify.status) -Message 'The first Verify did not complete in the double.'
            Assert-CoreEqual -Expected 'KB-OLD' -Actual ([string](@($firstVerify.agentStatus.updates)[0].updateId)) -Message 'The first Verify did not preserve the initial offered update.'

            $rebootState = Read-PatchRun -RunPath $verifyRunPath
            $rebootVm = @($rebootState.vms)[0]
            $reboot = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $verifyRunPath -RunState $rebootState -VMRecord $rebootVm -VM $null -Context $resumeContext -TimeoutMinutes 1
            Assert-CoreEqual -Expected 'RebootRequested' -Actual ([string]$reboot.status) -Message 'The intervening reboot did not record dispatch evidence.'
            $confirmedRebootState = Read-PatchRun -RunPath $verifyRunPath
            $confirmedRebootVm = @($confirmedRebootState.vms)[0]
            $confirmedRebootStep = @($confirmedRebootVm.steps | Where-Object { $_.action -eq 'Reboot' -and [int]$_.round -eq 1 })[0]
            Set-PatchValue -InputObject $confirmedRebootStep -Name 'status' -Value 'Confirmed'
            Write-PatchRun -RunPath $verifyRunPath -RunState $confirmedRebootState | Out-Null

            $secondVerifyState = Read-PatchRun -RunPath $verifyRunPath
            $secondVerifyVm = @($secondVerifyState.vms)[0]
            $secondVerify = Invoke-PatchAgentStep -Action 'Verify' -RunPath $verifyRunPath -RunState $secondVerifyState -VMRecord $secondVerifyVm -VM $null -Context $resumeContext -TimeoutMinutes 1
            Assert-CoreEqual -Expected 'Completed' -Actual ([string]$secondVerify.status) -Message 'The second Verify did not complete in the double.'
            Assert-CoreEqual -Expected 'KB-NEW' -Actual ([string](@($secondVerify.agentStatus.updates)[0].updateId)) -Message 'The second Verify returned the stale offered update.'
            $savedVerifyState = Read-PatchRun -RunPath $verifyRunPath
            $verifySteps = @(@($savedVerifyState.vms)[0].steps | Where-Object { $_.action -eq 'Verify' -and [int]$_.round -eq 1 })
            Assert-CoreEqual -Expected 2 -Actual $verifySteps.Count -Message 'The second Verify did not append a new step in the same round.'
            Assert-CoreTrue -Condition ([string]$verifySteps[0].stepId -ne [string]$verifySteps[1].stepId) -Message 'The repeated Verify reused the prior terminal step ID.'
            Assert-CoreEqual -Expected 3 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The fresh Verify did not start its own guest agent after the reboot.'

            $script:CoreCheckStartGuestAgentCalls = 0
            $script:CoreCheckReadGuestStatusCalls = 0
            $script:CoreCheckScanStatusIndex = 0
            $script:CoreCheckScanStatusPayloads = @([pscustomobject]@{ updates = @([pscustomobject]@{ updateId = 'KB-RESUMED'; revisionNumber = 3 }) })
            $resumeVerifyRun = New-PatchRun -Config ([pscustomobject]@{
                    VCenter = 'vcenter-double'
                    RunsRoot = (Join-Path $testRoot 'verify-resume')
                }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
            $resumeVerifyPath = [string]$resumeVerifyRun.runPath
            $resumeVerifyState = Read-PatchRun -RunPath $resumeVerifyPath
            $resumeVerifyVm = @($resumeVerifyState.vms)[0]
            $startedVerify = Invoke-PatchAgentStep -Action 'Verify' -RunPath $resumeVerifyPath -RunState $resumeVerifyState -VMRecord $resumeVerifyVm -VM $null -Context $resumeContext -TimeoutMinutes 1 -StartOnly
            Assert-CoreEqual -Expected 'Started' -Actual ([string]$startedVerify.status) -Message 'The interrupted Verify did not persist a started step.'
            $resumedVerifyState = Read-PatchRun -RunPath $resumeVerifyPath
            $resumedVerifyVm = @($resumedVerifyState.vms)[0]
            $resumedVerify = Invoke-PatchAgentStep -Action 'Verify' -RunPath $resumeVerifyPath -RunState $resumedVerifyState -VMRecord $resumedVerifyVm -VM $null -Context $resumeContext -TimeoutMinutes 1
            Assert-CoreEqual -Expected 'Completed' -Actual ([string]$resumedVerify.status) -Message 'The interrupted Verify did not reconcile terminal evidence.'
            Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The interrupted Verify started the guest agent more than once.'
            Assert-CoreEqual -Expected ([string]$startedVerify.step.stepId) -Actual ([string]$resumedVerify.step.stepId) -Message 'The interrupted Verify resume did not reuse the active step.'

            $script:CoreCheckConnectShouldFail = $false
            $script:CoreCheckVmLookup = @($uniqueVm)
            $script:CoreCheckStartGuestAgentCalls = 0
            $script:CoreCheckReadGuestStatusCalls = 0
            $script:CoreCheckScanStatusIndex = 0
            $failedPayload = [pscustomobject]@{
                status = 'Failed'
                error = 'The scan failed in the offline double.'
                updates = @([pscustomobject]@{ updateId = 'KB-FAILED'; revisionNumber = 4 })
            }
            $script:CoreCheckScanStatusPayloads = @($failedPayload, $failedPayload)
            $failedVerifyRun = New-PatchRun -Config ([pscustomobject]@{
                    VCenter = 'vcenter-double'
                    RunsRoot = (Join-Path $testRoot 'verify-failed-repeat')
                }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
            $failedVerifyCredential = New-Object System.Management.Automation.PSCredential('operator', (ConvertTo-SecureString -String 'offline-verify-password' -AsPlainText -Force))
            $failedFirstResult = Invoke-PatchAction -Action Verify -RunPath ([string]$failedVerifyRun.runPath) -VCenterCredential $failedVerifyCredential -GuestCredential $failedVerifyCredential
            $failedSecondResult = Invoke-PatchAction -Action Verify -RunPath ([string]$failedVerifyRun.runPath) -VCenterCredential $failedVerifyCredential -GuestCredential $failedVerifyCredential
            Assert-CoreEqual -Expected 'Failed' -Actual ([string]$failedFirstResult.vmResults[0].status) -Message 'The first public Verify did not return the terminal failure.'
            Assert-CoreEqual -Expected 'Failed' -Actual ([string]$failedSecondResult.vmResults[0].status) -Message 'The repeated public Verify did not return the fresh terminal failure.'
            Assert-CoreEqual -Expected 2 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'A repeated terminal Verify failure did not start a second guest agent.'
            $failedSavedState = Read-PatchRun -RunPath ([string]$failedVerifyRun.runPath)
            $failedVerifySteps = @(@($failedSavedState.vms)[0].steps | Where-Object { $_.action -eq 'Verify' -and [int]$_.round -eq 1 })
            Assert-CoreEqual -Expected 2 -Actual $failedVerifySteps.Count -Message 'A repeated terminal Verify failure did not append a new step.'
            Assert-CoreTrue -Condition ([string]$failedVerifySteps[0].stepId -ne [string]$failedVerifySteps[1].stepId) -Message 'A repeated terminal Verify failure reused the old step ID.'
        }
        finally {
            $script:CoreCheckScanStatusPayloads = $null
            $script:CoreCheckScanStatusIndex = 0
            $script:CoreCheckRebootStatusPayload = $null
        }
    } | Out-Null

    Invoke-CoreCheck -Name 'Unresolved mutating steps block new rounds and same-round reboot starts' -ScriptBlock {
        $script:CoreCheckStartGuestAgentCalls = 0
        $roundRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'mutating-step-barrier-round')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $roundRunPath = [string]$roundRun.runPath
        $roundState = Read-PatchRun -RunPath $roundRunPath
        $roundVm = @($roundState.vms)[0]
        $oldInstall = Get-PatchStep -VMRecord $roundVm -Action 'Install' -Round 1
        Set-PatchValue -InputObject $oldInstall -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $oldInstall -Name 'status' -Value 'NeedsReview'
        Set-PatchValue -InputObject $roundState -Name 'currentRound' -Value 2
        Set-PatchValue -InputObject $roundVm -Name 'currentRound' -Value 2
        Write-PatchRun -RunPath $roundRunPath -RunState $roundState | Out-Null

        $resumedRoundState = Read-PatchRun -RunPath $roundRunPath
        $resumedRoundVm = @($resumedRoundState.vms)[0]
        $roundResult = Invoke-PatchAgentStep -Action 'Install' -RunPath $roundRunPath -RunState $resumedRoundState -VMRecord $resumedRoundVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'NeedsReview' -Actual ([string]$roundResult.status) -Message 'A new round started despite an unresolved prior install.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'A new round started a guest agent before the prior install was reconciled.'
        $newRoundStep = @($resumedRoundVm.steps | Where-Object { $_.action -eq 'Install' -and [int]$_.round -eq 2 })[0]
        Assert-CoreTrue -Condition (-not [bool]$newRoundStep.startAttempted) -Message 'The blocked new-round install persisted a guest start attempt.'

        $reconcileState = Read-PatchRun -RunPath $roundRunPath
        $reconcileVm = @($reconcileState.vms)[0]
        $reconcileStep = Get-PatchStep -VMRecord $reconcileVm -Action 'Install' -Round 2
        Set-PatchValue -InputObject $reconcileStep -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $reconcileStep -Name 'status' -Value 'Started'
        Set-PatchValue -InputObject $reconcileState -Name 'currentRound' -Value 2
        Set-PatchValue -InputObject $reconcileVm -Name 'currentRound' -Value 2
        Write-PatchRun -RunPath $roundRunPath -RunState $reconcileState | Out-Null
        $script:CoreCheckStartGuestAgentCalls = 0
        $script:CoreCheckReadGuestStatusCalls = 0
        $reconcileState = Read-PatchRun -RunPath $roundRunPath
        $reconcileVm = @($reconcileState.vms)[0]
        $reconcileResult = Invoke-PatchAgentStep -Action 'Install' -RunPath $roundRunPath -RunState $reconcileState -VMRecord $reconcileVm -VM $null -Context $resumeContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$reconcileResult.status) -Message 'A current in-flight install did not resume reconciliation.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckReadGuestStatusCalls -Message 'The current in-flight install did not read terminal evidence.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'Current-step reconciliation started a second guest agent.'

        $sameRoundRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'mutating-step-barrier-reboot')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $sameRoundPath = [string]$sameRoundRun.runPath
        $sameRoundState = Read-PatchRun -RunPath $sameRoundPath
        $sameRoundVm = @($sameRoundState.vms)[0]
        $sameRoundInstall = Get-PatchStep -VMRecord $sameRoundVm -Action 'Install' -Round 1
        Set-PatchValue -InputObject $sameRoundInstall -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $sameRoundInstall -Name 'status' -Value 'NeedsReview'
        Write-PatchRun -RunPath $sameRoundPath -RunState $sameRoundState | Out-Null

        $sameRoundState = Read-PatchRun -RunPath $sameRoundPath
        $sameRoundVm = @($sameRoundState.vms)[0]
        $sameRoundReboot = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $sameRoundPath -RunState $sameRoundState -VM $null -VMRecord $sameRoundVm -Context $resumeContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'NeedsReview' -Actual ([string]$sameRoundReboot.status) -Message 'A same-round reboot started despite an unresolved install.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The same-round reboot started a guest agent before the install was reconciled.'

        $resolvedState = Read-PatchRun -RunPath $sameRoundPath
        $resolvedVm = @($resolvedState.vms)[0]
        $resolvedInstall = @($resolvedVm.steps | Where-Object { $_.action -eq 'Install' -and [int]$_.round -eq 1 })[0]
        Set-PatchValue -InputObject $resolvedInstall -Name 'status' -Value 'Completed'
        Set-PatchValue -InputObject $resolvedInstall -Name 'agentStatus' -Value ([pscustomobject]@{
                runId = [string]$resolvedState.runId
                stepId = [string]$resolvedInstall.stepId
                mode = 'Install'
                status = 'Completed'
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        Write-PatchRun -RunPath $sameRoundPath -RunState $resolvedState | Out-Null
        $script:CoreCheckStartGuestAgentCalls = 0
        $resolvedState = Read-PatchRun -RunPath $sameRoundPath
        $resolvedVm = @($resolvedState.vms)[0]
        $resolvedResult = Invoke-PatchAgentStep -Action 'Reboot' -RunPath $sameRoundPath -RunState $resolvedState -VM $null -VMRecord $resolvedVm -Context $resumeContext -TimeoutMinutes 1 -StartOnly
        Assert-CoreEqual -Expected 'Started' -Actual ([string]$resolvedResult.status) -Message 'A reconciled prior install blocked a valid same-round reboot.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'The valid same-round reboot did not start exactly once.'

        $rebootEvidence = @($resolvedVm.steps | Where-Object { $_.action -eq 'Reboot' -and [int]$_.round -eq 1 })[0]
        Set-PatchValue -InputObject $rebootEvidence -Name 'status' -Value 'RebootRequested'
        Set-PatchValue -InputObject $rebootEvidence -Name 'agentStatus' -Value ([pscustomobject]@{
                runId = [string]$resolvedState.runId
                stepId = [string]$rebootEvidence.stepId
                mode = 'Reboot'
                status = 'RebootRequested'
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        $futureInstall = Get-PatchStep -VMRecord $resolvedVm -Action 'Install' -Round 2
        $rebootBlocker = Get-PatchMutatingStepBlocker -RunState $resolvedState -VMRecord $resolvedVm -CurrentStep $futureInstall
        Assert-CoreEqual -Expected 'Reboot' -Actual ([string]$rebootBlocker.action) -Message 'A reboot request without confirmation was treated as reconciled.'
        Set-PatchValue -InputObject $rebootEvidence -Name 'status' -Value 'Confirmed'
        $rebootBlocker = Get-PatchMutatingStepBlocker -RunState $resolvedState -VMRecord $resolvedVm -CurrentStep $futureInstall
        Assert-CoreTrue -Condition ($null -eq $rebootBlocker) -Message 'A confirmed reboot with matching evidence remained blocked.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Expired wait deadlines perform one immediate evidence read without renewal' -ScriptBlock {
        $waitRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'expired-wait-deadline')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $waitRunPath = [string]$waitRun.runPath
        $waitState = Read-PatchRun -RunPath $waitRunPath
        $waitVm = @($waitState.vms)[0]
        $waitStep = Get-PatchStep -VMRecord $waitVm -Action 'Install' -Round 1
        $expiredWaitDeadline = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        Set-PatchValue -InputObject $waitStep -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $waitStep -Name 'status' -Value 'Started'
        Set-PatchValue -InputObject $waitStep -Name 'deadlineAt' -Value $expiredWaitDeadline
        Write-PatchRun -RunPath $waitRunPath -RunState $waitState | Out-Null

        $script:CoreCheckReadGuestStatusCalls = 0
        $waitResult = Wait-PatchAgent -Context $resumeContext -RunState $waitState -Step $waitStep -RunPath $waitRunPath -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Completed' -Actual ([string]$waitResult.status) -Message 'An expired install wait did not reconcile terminal evidence immediately.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckReadGuestStatusCalls -Message 'An expired install wait did not perform exactly one immediate evidence read.'
        Assert-CoreEqual -Expected $expiredWaitDeadline -Actual ([string]$waitStep.deadlineAt) -Message 'An expired install wait renewed its persisted deadline.'

        $rebootRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'expired-reboot-deadline')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $rebootRunPath = [string]$rebootRun.runPath
        $rebootState = Read-PatchRun -RunPath $rebootRunPath
        $rebootVm = @($rebootState.vms)[0]
        $rebootStep = Get-PatchStep -VMRecord $rebootVm -Action 'Reboot' -Round 1
        $expiredConfirmationDeadline = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $baselineBootTime = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
        Set-PatchValue -InputObject $rebootStep -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $rebootStep -Name 'status' -Value 'PendingRebootConfirmation'
        Set-PatchValue -InputObject $rebootStep -Name 'baselineBootTime' -Value $baselineBootTime
        Set-PatchValue -InputObject $rebootStep -Name 'confirmationDeadlineAt' -Value $expiredConfirmationDeadline
        Set-PatchValue -InputObject $rebootStep -Name 'agentStatus' -Value ([pscustomobject]@{
                runId = [string]$rebootState.runId
                stepId = [string]$rebootStep.stepId
                mode = 'Reboot'
                status = 'RebootRequested'
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        Write-PatchRun -RunPath $rebootRunPath -RunState $rebootState | Out-Null

        $script:CoreCheckBootTimeCalls = 0
        $script:CoreCheckBootTime = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o')
        $initialContext = [pscustomobject]@{
            VM = $uniqueVm
            Fqdn = 'app-01.example.test'
            ProgramData = $testRoot
            ToolsRunning = $true
        }
        $confirmationResult = Invoke-PatchRebootConfirmation -RunPath $rebootRunPath -RunState $rebootState -VMRecord $rebootVm -Server $server -GuestCredential $null -Step $rebootStep -InitialVM $uniqueVm -InitialContext $initialContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Confirmed' -Actual ([string]$confirmationResult.status) -Message 'An expired reboot confirmation did not perform one immediate boot evidence read.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckBootTimeCalls -Message 'An expired reboot confirmation did not perform exactly one immediate boot evidence read.'
        Assert-CoreEqual -Expected $expiredConfirmationDeadline -Actual ([string]$rebootStep.confirmationDeadlineAt) -Message 'An expired reboot confirmation renewed its persisted deadline.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Terminal reboot failure stops confirmation, persists on resume, and preserves the reboot barrier' -ScriptBlock {
        $script:CoreCheckStartGuestAgentCalls = 0
        $script:CoreCheckReadGuestStatusCalls = 0
        $script:CoreCheckBootTimeCalls = 0
        $script:CoreCheckRebootStatusPayload = $null
        $failureRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'reboot-terminal-failure')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $failureRunPath = [string]$failureRun.runPath
        $failureState = Read-PatchRun -RunPath $failureRunPath
        $failureVm = @($failureState.vms)[0]
        $failureStep = Get-PatchStep -VMRecord $failureVm -Action 'Reboot' -Round 1
        Set-PatchValue -InputObject $failureStep -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $failureStep -Name 'status' -Value 'PendingRebootConfirmation'
        Set-PatchValue -InputObject $failureStep -Name 'baselineBootTime' -Value ((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o'))
        Set-PatchValue -InputObject $failureStep -Name 'confirmationDeadlineAt' -Value ((Get-Date).ToUniversalTime().AddMinutes(1).ToString('o'))
        $failureContext = [pscustomobject]@{
            VM = $uniqueVm
            Fqdn = 'app-01.example.test'
            ProgramData = $testRoot
            clusterMembership = 'NotMember'
            ToolsRunning = $true
        }
        $script:CoreCheckRebootStatusPayload = [pscustomobject]@{
            runId = [string]$failureState.runId
            stepId = [string]$failureStep.stepId
            mode = 'Reboot'
            status = 'Failed'
            outcome = 'RebootCommandFailed'
            error = 'shutdown.exe returned a nonzero exit code.'
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Write-PatchRun -RunPath $failureRunPath -RunState $failureState | Out-Null

        $failureResult = Invoke-PatchRebootStep -RunPath $failureRunPath -RunState $failureState -VMRecord $failureVm -VM $uniqueVm -Context $failureContext -Server $server -GuestCredential $null -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Failed' -Actual ([string]$failureResult.status) -Message 'A matching terminal reboot failure did not return Failed from the initial evidence read.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'A reboot failure caused a second guest agent start.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckReadGuestStatusCalls -Message 'The initial reboot failure path did not read status.json exactly once.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckBootTimeCalls -Message 'The failed reboot path attempted boot confirmation.'

        $persistedFailureState = Read-PatchRun -RunPath $failureRunPath
        $persistedFailureVm = @($persistedFailureState.vms)[0]
        $persistedFailureStep = @($persistedFailureVm.steps | Where-Object { [string]$_.stepId -eq [string]$failureStep.stepId })[0]
        Assert-CoreTrue -Condition ($null -ne $persistedFailureStep) -Message 'The failed reboot step was not persisted in run.json.'
        Assert-CoreEqual -Expected 'Failed' -Actual ([string]$persistedFailureStep.status) -Message 'The terminal reboot failure was not persisted on the step.'
        Assert-CoreTrue -Condition ([string]$persistedFailureStep.error -match 'shutdown\.exe') -Message 'The reboot failure detail was not persisted on the step.'
        $persistedFinishedAt = [datetime]::MinValue
        Assert-CoreTrue -Condition ([datetime]::TryParse([string]$persistedFailureStep.finishedAt, [ref]$persistedFinishedAt)) -Message 'The persisted reboot failure finishedAt was missing or unparsable.'

        $rebootBarrier = $false
        $needsReviewBarrier = $false
        [void](Add-PatchVmResult -RunPath $failureRunPath -RunState $persistedFailureState -VMRecord $persistedFailureVm -VMName 'APP[01]' -Action 'Reboot' -VmResult $failureResult -RebootBarrier ([ref]$rebootBarrier) -NeedsReviewBarrier ([ref]$needsReviewBarrier))
        $errorsPath = Join-Path (Split-Path -Parent $failureRunPath) 'errors.log'
        $errors = Get-Content -LiteralPath $errorsPath -Raw
        Assert-CoreTrue -Condition $rebootBarrier -Message 'A terminal reboot failure did not preserve the reboot barrier.'
        Assert-CoreTrue -Condition ($errors -match 'PatchActionFailed' -and $errors -match 'shutdown\.exe') -Message 'The terminal reboot failure was not routed to errors.log.'

        $script:CoreCheckRebootStatusPayload = $null
        $script:CoreCheckReadGuestStatusCalls = 0
        $resumeState = Read-PatchRun -RunPath $failureRunPath
        $resumeVm = @($resumeState.vms)[0]
        $resumeStep = @($resumeVm.steps | Where-Object { [string]$_.stepId -eq [string]$failureStep.stepId })[0]
        $resumeResult = Invoke-PatchRebootConfirmation -RunPath $failureRunPath -RunState $resumeState -VMRecord $resumeVm -Server $server -GuestCredential $null -Step $resumeStep -InitialVM $uniqueVm -InitialContext $failureContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Failed' -Actual ([string]$resumeResult.status) -Message 'A persisted terminal reboot failure did not return Failed on resume.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckReadGuestStatusCalls -Message 'Persisted reboot failure evidence was needlessly re-read on resume.'

        $pollRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'reboot-terminal-failure-poll')
            }) -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
        $pollRunPath = [string]$pollRun.runPath
        $pollState = Read-PatchRun -RunPath $pollRunPath
        $pollVm = @($pollState.vms)[0]
        $pollStep = Get-PatchStep -VMRecord $pollVm -Action 'Reboot' -Round 1
        Set-PatchValue -InputObject $pollStep -Name 'startAttempted' -Value $true
        Set-PatchValue -InputObject $pollStep -Name 'status' -Value 'PendingRebootConfirmation'
        Set-PatchValue -InputObject $pollStep -Name 'baselineBootTime' -Value ((Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o'))
        Set-PatchValue -InputObject $pollStep -Name 'confirmationDeadlineAt' -Value ((Get-Date).ToUniversalTime().AddMinutes(1).ToString('o'))
        Set-PatchValue -InputObject $pollStep -Name 'agentStatus' -Value ([pscustomobject]@{
                runId = [string]$pollState.runId
                stepId = [string]$pollStep.stepId
                mode = 'Reboot'
                status = 'RebootRequested'
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        $script:CoreCheckRebootStatusPayload = [pscustomobject]@{
            runId = [string]$pollState.runId
            stepId = [string]$pollStep.stepId
            mode = 'Reboot'
            status = 'Failed'
            error = 'shutdown.exe returned a nonzero exit code.'
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $script:CoreCheckReadGuestStatusCalls = 0
        $script:CoreCheckBootTimeCalls = 0
        $pollResult = Invoke-PatchRebootConfirmation -RunPath $pollRunPath -RunState $pollState -VMRecord $pollVm -Server $server -GuestCredential $null -Step $pollStep -InitialVM $uniqueVm -InitialContext $failureContext -TimeoutMinutes 1
        Assert-CoreEqual -Expected 'Failed' -Actual ([string]$pollResult.status) -Message 'A later terminal reboot failure did not stop confirmation polling.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckReadGuestStatusCalls -Message 'Confirmation polling did not seek fresh status evidence once.'
        Assert-CoreEqual -Expected 0 -Actual $script:CoreCheckBootTimeCalls -Message 'Confirmation polling attempted boot confirmation after a terminal failure.'

        $wrongIdentityStep = Get-PatchStep -VMRecord $pollVm -Action 'Reboot' -Round 2
        $wrongIdentityStatus = [pscustomobject]@{
            runId = [string]$pollState.runId
            stepId = ([Guid]::NewGuid()).ToString('D')
            mode = 'Reboot'
            status = 'Failed'
            error = 'foreign status'
            finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        $script:CoreCheckRebootStatusPayload = $wrongIdentityStatus
        $wrongIdentityRead = Read-PatchRebootEvidence -RunPath $pollRunPath -RunState $pollState -Step $wrongIdentityStep -Context $failureContext
        Assert-CoreEqual -Expected $false -Actual ([bool]$wrongIdentityRead) -Message 'A failed status with the wrong step identity was accepted.'
        Assert-CoreTrue -Condition ($null -eq $wrongIdentityStep.agentStatus) -Message 'A failed status with the wrong step identity was persisted.'
        $script:CoreCheckRebootStatusPayload = $null
    } | Out-Null

    Invoke-CoreCheck -Name 'A reboot batch stays blocked when newer boot evidence lacks matching request status' -ScriptBlock {
        $script:CoreCheckConnectShouldFail = $false
        $script:CoreCheckStartGuestAgentCalls = 0
        $script:CoreCheckRebootBootReads = @{}
        $batchBaselineBoot = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o')
        $batchNewBoot = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o')
        $batchExpiredDeadline = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o')
        $script:CoreCheckRebootBatchVMs = @(
            [pscustomobject]@{
                Name = 'APP-REBOOT-01'
                Id = 'VirtualMachine-reboot-01'
                PowerState = 'PoweredOn'
                ExtensionData = [pscustomobject]@{
                    Guest = [pscustomobject]@{ HostName = 'app-reboot-01.example.test'; ToolsRunningStatus = 'guestToolsRunning' }
                }
            },
            [pscustomobject]@{
                Name = 'APP-REBOOT-02'
                Id = 'VirtualMachine-reboot-02'
                PowerState = 'PoweredOn'
                ExtensionData = [pscustomobject]@{
                    Guest = [pscustomobject]@{ HostName = 'app-reboot-02.example.test'; ToolsRunningStatus = 'guestToolsRunning' }
                }
            }
        )

        function Get-VM {
            [CmdletBinding()]
            param(
                [string]$Name,
                [object]$Server,
                [string]$Id
            )

            if (-not [string]::IsNullOrWhiteSpace($Id)) {
                return @($script:CoreCheckRebootBatchVMs | Where-Object { [string]$_.Id -eq $Id })
            }
            return @($script:CoreCheckRebootBatchVMs | Where-Object { [string]$_.Name -eq $Name })
        }

        function Get-GuestContext {
            [CmdletBinding()]
            param(
                [object]$VM,
                [System.Management.Automation.PSCredential]$GuestCredential
            )

            return [pscustomobject]@{
                VM = $VM
                Fqdn = [string]$VM.ExtensionData.Guest.HostName
                ProgramData = $testRoot
                clusterMembership = 'NotMember'
                ToolsRunning = $true
                Server = $server
                GuestCredential = $GuestCredential
            }
        }

        function Read-GuestStatus {
            [CmdletBinding()]
            param(
                [object]$Context,
                [Guid]$RunId,
                [Guid]$StepId,
                [ValidateSet('Scan', 'Install', 'Reboot')][string]$ExpectedMode,
                [string]$LocalPath,
                [bool]$IgnoreEsxiCertificate = $false
            )

            $reportedStepId = $StepId.ToString('D')
            if ($ExpectedMode -eq 'Reboot' -and [string]$Context.VM.Name -eq 'APP-REBOOT-01') {
                $reportedStepId = ([Guid]::NewGuid()).ToString('D')
            }
            return [pscustomobject]@{
                runId = $RunId.ToString('D')
                stepId = $reportedStepId
                mode = $ExpectedMode
                status = if ($ExpectedMode -eq 'Reboot') { 'RebootRequested' } else { 'Completed' }
                finishedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
        }

        function Read-GuestBootTime {
            [CmdletBinding()]
            param([object]$Context, [bool]$IgnoreEsxiCertificate)

            $vmName = [string]$Context.VM.Name
            if (-not $script:CoreCheckRebootBootReads.ContainsKey($vmName)) {
                $script:CoreCheckRebootBootReads[$vmName] = 0
            }
            $script:CoreCheckRebootBootReads[$vmName]++
            return $batchNewBoot
        }

        $batchRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'reboot-evidence-batch')
                RebootBatchSize = 1
                RebootConfirmationTimeoutMinutes = 1
            }) -VMEntries @(
                [pscustomobject]@{ VmName = 'APP-REBOOT-01'; ExpectedFqdn = 'app-reboot-01.example.test' },
                [pscustomobject]@{ VmName = 'APP-REBOOT-02'; ExpectedFqdn = 'app-reboot-02.example.test' }
            )
        $batchRunPath = [string]$batchRun.runPath
        $batchState = Read-PatchRun -RunPath $batchRunPath
        foreach ($batchVm in @($batchState.vms)) {
            $batchReboot = Get-PatchValue $batchVm @('reboot') ([pscustomobject]@{})
            Set-PatchValue -InputObject $batchReboot -Name 'required' -Value $true
            Set-PatchValue -InputObject $batchReboot -Name 'status' -Value 'Pending'
            $batchStep = Get-PatchStep -VMRecord $batchVm -Action 'Reboot' -Round 1
            Set-PatchValue -InputObject $batchStep -Name 'baselineBootTime' -Value $batchBaselineBoot
            Set-PatchValue -InputObject $batchStep -Name 'confirmationDeadlineAt' -Value $batchExpiredDeadline
        }
        Write-PatchRun -RunPath $batchRunPath -RunState $batchState | Out-Null

        $secure = ConvertTo-SecureString -String 'offline-reboot-password' -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential('operator', $secure)
        $batchResult = Invoke-PatchAction -Action Reboot -RunPath $batchRunPath -VCenterCredential $credential -GuestCredential $credential
        $savedBatch = Read-PatchRun -RunPath $batchRunPath
        $savedBatchVms = @($savedBatch.vms)
        Assert-CoreEqual -Expected 'NeedsReview' -Actual ([string]$batchResult.status) -Message 'A reboot batch with mismatched evidence did not remain in review.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckStartGuestAgentCalls -Message 'A reboot batch started the second VM after newer boot evidence without matching request status.'
        Assert-CoreEqual -Expected 'PendingRebootConfirmation' -Actual ([string]$savedBatchVms[0].status) -Message 'The first VM did not remain pending reboot confirmation.'
        Assert-CoreEqual -Expected 'PendingRebootBarrier' -Actual ([string]$savedBatchVms[1].status) -Message 'The second VM was not held behind the reboot barrier.'
        $firstBatchStep = @($savedBatchVms[0].steps | Where-Object { $_.action -eq 'Reboot' -and [int]$_.round -eq 1 })[0]
        Assert-CoreEqual -Expected 'PendingRebootConfirmation' -Actual ([string]$firstBatchStep.status) -Message 'The mismatched reboot request was treated as confirmed.'
        Assert-CoreTrue -Condition ($null -eq $firstBatchStep.agentStatus) -Message 'Mismatched reboot evidence was persisted as matching agent status.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Saving selections preserves an empty selection for one VM' -ScriptBlock {
        $wizardPath = Join-Path $repoRoot 'Start-PatchWizard.ps1'
        $wizardTokens = $null
        $wizardErrors = $null
        $wizardAst = [System.Management.Automation.Language.Parser]::ParseFile($wizardPath, [ref]$wizardTokens, [ref]$wizardErrors)
        if ($wizardErrors.Count -gt 0) {
            throw ('Wizard parse failed: {0}' -f (($wizardErrors | ForEach-Object { $_.ToString() }) -join '; '))
        }
        $requiredFunctions = @('Get-WizardProperty', 'Set-WizardProperty', 'Get-WizardArray', 'Get-WizardSelectedUpdateKey', 'Save-WizardSelections')
        foreach ($functionAst in @($wizardAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $requiredFunctions -contains $node.Name }, $true))) {
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }
        function Set-WizardStatus {
            param([string]$Message)
            $script:CoreCheckWizardStatusMessage = $Message
        }
        function Refresh-WizardSelectionGrid {
        }

        $selectionRun = New-PatchRun -Config ([pscustomobject]@{
                VCenter = 'vcenter-double'
                RunsRoot = (Join-Path $testRoot 'per-vm-selection')
            }) -VMEntries @(
                [pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' },
                [pscustomobject]@{ VmName = 'APP-02'; ExpectedFqdn = 'app-02.example.test' }
            )
        $selectionRunPath = [string]$selectionRun.runPath
        $selectionState = Read-PatchRun -RunPath $selectionRunPath
        $selectionVms = @($selectionState.vms)
        Set-PatchValue -InputObject $selectionVms[0] -Name 'selectedUpdates' -Value @([pscustomobject]@{ updateId = 'stale-a'; revisionNumber = 1 })
        Set-PatchValue -InputObject $selectionVms[1] -Name 'selectedUpdates' -Value @([pscustomobject]@{ updateId = 'stale-b'; revisionNumber = 1 })
        Write-PatchRun -RunPath $selectionRunPath -RunState $selectionState | Out-Null
        $script:Wizard = [pscustomobject]@{
            RunState = $selectionState
            RunPath = $selectionRunPath
            UpdateRows = @(
                [pscustomobject]@{
                    VmName = 'APP[01]'
                    Selected = $false
                    Update = [pscustomobject]@{ updateId = 'KB-1'; revisionNumber = 1; selected = $true }
                },
                [pscustomobject]@{
                    VmName = 'APP-02'
                    Selected = $true
                    Update = [pscustomobject]@{ updateId = 'KB-2'; revisionNumber = 2; selected = $false }
                }
            )
        }

        Save-WizardSelections
        $savedState = Read-PatchRun -RunPath $selectionRunPath
        $savedVms = @($savedState.vms)
        $savedFirstSelection = @(Get-PatchArray -Value $savedVms[0].selectedUpdates)
        $savedSecondSelection = @(Get-PatchArray -Value $savedVms[1].selectedUpdates)
        $savedRootSelection = @(Get-PatchArray -Value $savedState.selectedUpdates)
        Assert-CoreEqual -Expected 0 -Actual $savedFirstSelection.Count -Message 'The first VM kept a stale update after an empty selection.'
        Assert-CoreEqual -Expected 1 -Actual $savedSecondSelection.Count -Message 'The second VM selection was not persisted.'
        Assert-CoreEqual -Expected 'KB-2' -Actual ([string]$savedSecondSelection[0].updateId) -Message 'The second VM selection has the wrong update ID.'
        Assert-CoreEqual -Expected 1 -Actual $savedRootSelection.Count -Message 'The run-level selection contains an unexpected VM entry.'
        Assert-CoreEqual -Expected 'APP-02' -Actual ([string]$savedRootSelection[0].vmName) -Message 'The run-level selection did not preserve the selected VM.'
    } | Out-Null

    Invoke-CoreCheck -Name 'Install matches updates by exact UpdateID and RevisionNumber' -ScriptBlock {
        $agentPath = Join-Path $repoRoot 'guest\PatchAgent.ps1'
        $agentTokens = $null
        $agentErrors = $null
        $agentAst = [System.Management.Automation.Language.Parser]::ParseFile($agentPath, [ref]$agentTokens, [ref]$agentErrors)
        if ($agentErrors.Count -gt 0) {
            throw ('Guest agent parse failed: {0}' -f (($agentErrors | ForEach-Object { $_.ToString() }) -join '; '))
        }
        foreach ($functionAst in @($agentAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            . ([scriptblock]::Create($functionAst.Extent.Text))
        }

        $script:Status = [ordered]@{
            runId = ([Guid]::NewGuid()).ToString('D')
            stepId = ([Guid]::NewGuid()).ToString('D')
            mode = 'Install'
            status = 'Started'
            outcome = $null
            startedAt = (Get-Date).ToUniversalTime().ToString('o')
            finishedAt = $null
            updates = @()
        }
        $statusDirectory = Join-Path $testRoot 'update-match'
        New-Item -ItemType Directory -Path $statusDirectory -Force | Out-Null
        $script:StatusPath = Join-Path $statusDirectory 'status.json'
        $script:LogPath = Join-Path $statusDirectory 'agent.log'
        $SelectionPath = Join-Path $statusDirectory 'selection.json'

        $updateA = [pscustomobject]@{
            Identity = [pscustomobject]@{ UpdateID = 'UPDATE-A'; RevisionNumber = 10 }
            Title = 'Matching update'
            Type = 'Software'
            BrowseOnly = $false
            EulaAccepted = $true
        }
        $updateB = [pscustomobject]@{
            Identity = [pscustomobject]@{ UpdateID = 'UPDATE-B'; RevisionNumber = 20 }
            Title = 'Other update'
            Type = 'Software'
            BrowseOnly = $false
            EulaAccepted = $true
        }

        $updates = [pscustomobject]@{ Items = @($updateA, $updateB); Count = 2 }
        $updates | Add-Member -MemberType ScriptMethod -Name Item -Value { param([int]$Index) return $this.Items[$Index] }

        $downloadResult = [pscustomobject]@{ ResultCode = 2; HResult = 0; RebootRequired = $false }
        $downloadResult | Add-Member -MemberType ScriptMethod -Name GetUpdateResult -Value {
            param([int]$Index)
            return [pscustomobject]@{ ResultCode = 2; HResult = 0; RebootRequired = $false }
        }
        $installResult = [pscustomobject]@{ ResultCode = 2; HResult = 0; RebootRequired = $false }
        $installResult | Add-Member -MemberType ScriptMethod -Name GetUpdateResult -Value {
            param([int]$Index)
            return [pscustomobject]@{ ResultCode = 2; HResult = 0; RebootRequired = $false }
        }

        $selectedCollection = [pscustomobject]@{ Items = @(); Count = 0 }
        $selectedCollection | Add-Member -MemberType ScriptMethod -Name Add -Value {
            param($Item)
            $this.Items = @($this.Items + $Item)
            $this.Count = $this.Items.Count
        }
        $downloader = [pscustomobject]@{ Updates = $null; DownloadCalls = 0 }
        $downloader | Add-Member -MemberType ScriptMethod -Name Download -Value {
            $this.DownloadCalls++
            return $downloadResult
        }
        $installer = [pscustomobject]@{ Updates = $null; InstallCalls = 0 }
        $installer | Add-Member -MemberType ScriptMethod -Name Install -Value {
            $this.InstallCalls++
            return $installResult
        }
        $session = [pscustomobject]@{}
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateDownloader -Value { return $downloader }
        $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateInstaller -Value { return $installer }
        $script:CoreCheckSearch = [pscustomobject]@{
            session = $session
            result = [pscustomobject]@{ ResultCode = 2; HResult = 0 }
            updates = $updates
        }
        $script:CoreCheckSelectedCollection = $selectedCollection
        $script:CoreCheckDownloader = $downloader
        $script:CoreCheckInstaller = $installer

        function Get-ClusterState {
            return [ordered]@{ membership = 'NotMember'; state = 'Standalone'; nativeReturnCode = 0; reason = $null }
        }
        function Get-SystemSnapshot {
            return [ordered]@{
                fqdn = 'app-01.example.test'
                pendingReboot = [ordered]@{ isPending = $false }
                lastBootUpTime = $null
            }
        }
        function Search-Updates {
            return $script:CoreCheckSearch
        }
        function New-Object {
            [CmdletBinding()]
            param(
                [string]$TypeName,
                [switch]$ComObject
            )

            if ($ComObject -and $TypeName -eq 'Microsoft.Update.UpdateColl') {
                return $script:CoreCheckSelectedCollection
            }
            throw ('Unexpected object construction in the offline update double: {0}' -f $TypeName)
        }

        $selection = @(
            [ordered]@{ updateId = 'update-a'; revisionNumber = 10 },
            [ordered]@{ updateId = 'update-a'; revisionNumber = 11 },
            [ordered]@{ updateId = 'missing-update'; revisionNumber = 99 }
        )
        ConvertTo-Json -InputObject $selection -Depth 5 | Set-Content -LiteralPath $SelectionPath -Encoding UTF8
        Invoke-Install

        Assert-CoreEqual -Expected 'InstallSucceeded' -Actual ([string]$script:Status.outcome) -Message 'The exact-pair install did not complete.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckSelectedCollection.Count -Message 'A revision mismatch was sent to the installer.'
        Assert-CoreEqual -Expected 1 -Actual $script:CoreCheckDownloader.Updates.Count -Message 'The downloader received more than the exact matching update.'
        Assert-CoreEqual -Expected 'UPDATE-A' -Actual ([string]$script:CoreCheckSelectedCollection.Items[0].Identity.UpdateID) -Message 'The selected update ID changed.'
        Assert-CoreEqual -Expected 10 -Actual ([int64]$script:CoreCheckSelectedCollection.Items[0].Identity.RevisionNumber) -Message 'The selected update revision changed.'
        Assert-CoreEqual -Expected 2 -Actual $script:Status.skipped.Count -Message 'Missing and changed revisions were not reported.'
        Assert-CoreTrue -Condition (@($script:Status.skipped | Where-Object { $_.reason -eq 'RevisionChanged' }).Count -eq 1) -Message 'The changed revision was not classified as RevisionChanged.'
        Assert-CoreTrue -Condition (@($script:Status.skipped | Where-Object { $_.reason -eq 'Missing' }).Count -eq 1) -Message 'The missing update was not classified as Missing.'
    } | Out-Null
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:CoreCheckFailed) {
    Write-Host 'Core checks failed.' -ForegroundColor Red
    exit 1
}

Write-Host 'All core checks passed.' -ForegroundColor Green
exit 0
