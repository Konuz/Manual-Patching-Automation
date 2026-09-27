# Offline checks of the key behaviours listed in Plan.md (64-bit Windows PowerShell 5.1).
# Local doubles only: no vCenter, WUA, installation or reboot.

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'scripts\RunController.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('PatchWizard-Checks-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$script:Failed = $false

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; Write-Host "[PASS] $Name" }
    catch { Write-Host "[FAIL] $Name`: $($_.Exception.Message)" -ForegroundColor Red; $script:Failed = $true }
}

function New-TestRun {
    param([string]$Name, $Options = $null)
    New-PatchRun -Config ([pscustomobject]@{ VCenter = 'vcenter-double'; OutputRoot = (Join-Path $testRoot $Name); Options = $Options }) `
        -VMEntries @([pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = 'app-01.example.test' })
}

function New-TestVm {
    param([string]$Id, [string]$HostName = 'app-01.example.test', [string]$Name = 'APP[01]')
    [pscustomobject]@{ Name = $Name; Id = $Id; PowerState = 'PoweredOn'; ExtensionData = [pscustomobject]@{ Guest = [pscustomobject]@{ HostName = $HostName; ToolsRunningStatus = 'guestToolsRunning' } } }
}

$credential = New-Object System.Management.Automation.PSCredential('operator', (ConvertTo-SecureString 'check-secret' -AsPlainText -Force))
$script:GuestContext = [pscustomobject]@{ ProgramData = $testRoot; VM = [pscustomobject]@{ Name = 'APP[01]' } }

# vSphere / guest doubles (defined after the controller, so they replace the adapter functions).
$script:VmLookup = @()
$script:ConnectFails = $false
$script:VCenterFlags = @()
$script:EsxiFlags = @()
$script:AgentStarts = 0
$script:VmByServer = $null
function Get-VM { param([string]$Name, $Server, [string]$Id) if ($null -ne $script:VmByServer) { $script:VmByServer[[string]$Server] } else { $script:VmLookup } }
function Connect-PatchVCenter {
    param([string]$ServerName, $Credential, [bool]$IgnoreVCenterCertificate)
    $script:VCenterFlags += $IgnoreVCenterCertificate
    if ($script:ConnectFails) { throw 'vCenter refused check-secret' }
    return $ServerName
}
function Get-GuestContext { param($VM, $GuestCredential) $script:GuestContext }
function Send-GuestFile { param($Context, [string]$LocalPath, [string]$GuestPath, [bool]$IgnoreEsxiCertificate) $script:EsxiFlags += $IgnoreEsxiCertificate }
function Receive-GuestFile { param($Context, [string]$GuestPath, [string]$LocalPath, [bool]$IgnoreEsxiCertificate) $script:EsxiFlags += $IgnoreEsxiCertificate }
function Start-GuestAgent { param($Context, [string]$GuestAgentPath, [string]$Mode, [Guid]$RunId, [Guid]$StepId, [string]$SelectionPath) $script:AgentStarts++; 1000 }
# The first read is the baseline before the reboot; later reads return a newer boot time.
$script:BootReads = 0
function Read-GuestBootTime { param($Context, [bool]$IgnoreEsxiCertificate) $script:BootReads++; [datetime]::UtcNow.AddMinutes($script:BootReads).ToString('o') }
function Read-GuestStatus {
    param($Context, [Guid]$RunId, [Guid]$StepId, [string]$ExpectedMode, [string]$LocalPath, [bool]$IgnoreEsxiCertificate)
    [pscustomobject]@{
        runId = $RunId.ToString('D'); stepId = $StepId.ToString('D'); mode = $ExpectedMode
        status = $(if ($ExpectedMode -eq 'Reboot') { 'RebootRequested' } else { 'Completed' })
        finishedAt = (Get-Date).ToUniversalTime().ToString('o'); updates = @()
        cluster = [pscustomobject]@{ membership = 'NotMember' }
    }
}

try {
    Invoke-Check 'The right VM is selected (FQDN optional) and grouped for guest credentials' {
        $script:VmLookup = @(New-TestVm 'vm-1')
        Assert ((Get-PatchVM -Server 's' -Name 'APP[01]' -ExpectedFqdn 'app-01.example.test').Id -eq 'vm-1') 'The unique VM was not returned.'
        $script:VmLookup = @((New-TestVm 'vm-1'), (New-TestVm 'vm-2'))
        try { Get-PatchVM -Server 's' -Name 'APP[01]' -ExpectedFqdn 'app-01.example.test'; throw 'accepted' } catch { Assert ($_.Exception.Message -match 'exactly one') 'A duplicate name was accepted.' }
        $script:VmLookup = @(New-TestVm 'vm-1' 'other.example.test')
        try { Get-PatchVM -Server 's' -Name 'APP[01]' -ExpectedFqdn 'app-01.example.test'; throw 'accepted' } catch { Assert ($_.Exception.Message -match 'expected guest FQDN') 'An FQDN mismatch was accepted.' }
        Assert ((Get-PatchVM -Server 's' -Name 'APP[01]').Id -eq 'vm-1') 'A VM without an expected FQDN was rejected.'
        $script:VmLookup = @(New-TestVm 'vm-3' 'app03.example.test' 'app03')
        Assert ((Get-PatchVM -Server 's' -Name 'app03.example.test').Id -eq 'vm-3') 'An FQDN entry was not found by its short VM name.'
        Assert ((Get-PatchAccountGroup -HostName 'app03.corp.local' -VmName 'app03') -eq 'corp.local') 'A domain VM was not grouped by its DNS suffix.'
        Assert ((Get-PatchAccountGroup -HostName 'dmz01' -VmName 'dmz01') -eq 'vm:dmz01') 'A VM without a DNS suffix did not get its own credential group.'
        # Several vCenters: a VM is bound to the one vCenter that has it; a name on two vCenters is blocked.
        $path = (New-PatchRun -Config ([pscustomobject]@{ VCenter = 'vc1, vc2'; OutputRoot = (Join-Path $testRoot 'multi') }) -VMEntries @(
                [pscustomobject]@{ VmName = 'APP[01]'; ExpectedFqdn = '' }, [pscustomobject]@{ VmName = 'app03'; ExpectedFqdn = '' })).runPath
        $script:VmByServer = @{ vc1 = @(New-TestVm 'vm-1'); vc2 = @((New-TestVm 'vm-9'), (New-TestVm 'vm-3' 'app03.example.test' 'app03')) }
        [void](Resolve-PatchVms -RunPath $path -VCenterCredentials @{ '*' = $credential })
        $script:VmByServer = $null
        $vms = (Read-PatchRun $path).vms
        Assert ($vms[1].vCenter -eq 'vc2' -and $vms[1].vmId -eq 'vm-3') 'A VM was not bound to the vCenter that has it.'
        Assert ($vms[0].status -eq 'Failed' -and [string]::IsNullOrEmpty([string]$vms[0].vCenter)) 'A VM name found on two vCenters was not blocked.'
    }

    Invoke-Check 'Cluster members and unknown cluster states are excluded from install and reboot' {
        $script:VmLookup = @(New-TestVm 'vm-1')
        $run = Read-PatchRun ([string](New-TestRun 'cluster').runPath)
        foreach ($membership in @('Member', 'Unknown')) {
            $vm = $run.vms[0]
            Set-PatchValue $vm 'agentStatus' ([pscustomobject]@{ cluster = [pscustomobject]@{ membership = $membership } })
            foreach ($action in @('Install', 'Reboot')) {
                try { Invoke-PatchVmAction -Action $action -RunPath $run.runPath -RunState $run -VMRecord $vm -Server 's' -GuestCredential $credential; throw 'not blocked' }
                catch { Assert ($_.Exception.Message -match "cluster membership is $membership") "$action was not blocked for ${membership}: $($_.Exception.Message) $($_.ScriptStackTrace)" }
            }
        }
    }

    Invoke-Check 'A controller error is written to errors.log and the summary at once, without secrets' {
        $script:ConnectFails = $true
        $run = Read-PatchRun (New-TestRun 'failure').runPath
        Set-PatchValue $run.vms[0] 'vCenter' 'vcenter-double'   # only vCenters that hold VMs are contacted
        Write-PatchRun -RunPath $run.runPath -RunState $run | Out-Null
        $result = Invoke-PatchAction -Action Scan -RunPath $run.runPath -VCenterCredentials @{ '*' = $credential } -GuestCredentials @{}
        $script:ConnectFails = $false
        $dir = Split-Path -Parent $run.runPath
        $errors = Get-Content (Join-Path $dir 'errors.log') -Raw
        Assert ($result.status -eq 'Stopped') 'The run did not stop.'
        Assert ($errors -match 'ControllerError') 'errors.log has no controller error.'
        Assert ((Test-Path (Join-Path $dir 'summary.md')) -and (Test-Path (Join-Path $dir 'summary.csv'))) 'The summary files were not written.'
        Assert (($errors + (Get-Content (Join-Path $dir 'summary.md') -Raw)) -notmatch 'check-secret') 'A secret was written to a file.'
    }

    Invoke-Check 'The vCenter and ESXi certificate options are independent' {
        $script:VmLookup = @(New-TestVm 'vm-1')
        foreach ($case in @(@{ VCenter = $true; Esxi = $false }, @{ VCenter = $false; Esxi = $true })) {
            $script:VCenterFlags = @(); $script:EsxiFlags = @()
            $run = New-TestRun 'certificates' ([pscustomobject]@{ IgnoreVCenterCertificate = $case.VCenter; IgnoreEsxiCertificatesForFileTransfers = $case.Esxi })
            [void](Resolve-PatchVms -RunPath $run.runPath -VCenterCredentials @{ '*' = $credential })
            $result = Invoke-PatchAction -Action Scan -RunPath $run.runPath -VCenterCredentials @{ '*' = $credential } -GuestCredentials @{ 'example.test' = $credential }
            $saved = Read-PatchRun $run.runPath
            Assert ($result.status -eq 'Completed') "The scan did not complete: $($result.vmResults | ConvertTo-Json -Compress)"
            Assert ($saved.options.ignoreVCenterCertificate -eq $case.VCenter -and $saved.options.ignoreEsxiCertificatesForFileTransfers -eq $case.Esxi) 'The choices were not saved in run.json.'
            Assert (@($script:VCenterFlags | Where-Object { $_ -ne $case.VCenter }).Count -eq 0) 'The vCenter channel used the wrong option.'
            Assert ($script:EsxiFlags.Count -gt 0 -and @($script:EsxiFlags | Where-Object { $_ -ne $case.Esxi }).Count -eq 0) 'The ESXi transfer channel used the wrong option.'
        }
    }

    Invoke-Check 'A resumed install or reboot observes the started step instead of starting it again' {
        $script:VmLookup = @(New-TestVm 'vm-1')
        foreach ($action in @('Install', 'Reboot')) {
            $script:AgentStarts = 0
            $script:BootReads = 0
            $path = (New-TestRun "resume-$action").runPath
            $run = Read-PatchRun $path
            Set-PatchValue $run.vms[0] 'selectedUpdates' @([pscustomobject]@{ updateId = 'KB-1'; revisionNumber = 1 })
            Set-PatchValue $run.vms[0] 'agentStatus' ([pscustomobject]@{ cluster = [pscustomobject]@{ membership = 'NotMember' } })
            Write-PatchRun -RunPath $path -RunState $run | Out-Null
            # Start, then "close the GUI" and resume from the saved run.json.
            [void](Invoke-PatchVmAction -Action $action -RunPath $path -RunState $run -VMRecord $run.vms[0] -Server 's' -GuestCredential $credential -StartOnly)
            $resumed = Read-PatchRun $path
            $result = Invoke-PatchVmAction -Action $action -RunPath $path -RunState $resumed -VMRecord $resumed.vms[0] -Server 's' -GuestCredential $credential
            Assert ($script:AgentStarts -eq 1) "$action started the guest agent $($script:AgentStarts) times."
            Assert ($result.status -in @('Completed', 'Confirmed')) "$action did not observe the final result: $($result.status) $($result.error)"
        }
    }

    Invoke-Check 'The agent installs only approved UpdateID + RevisionNumber pairs and blocks cluster members' {
        # Load the agent's functions without running its main block.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'guest\PatchAgent.ps1'), [ref]$null, [ref]$null)
        foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
            . ([scriptblock]::Create($function.Extent.Text))
        }
        $script:StatusPath = Join-Path $testRoot 'agent-status.json'
        $script:LogPath = Join-Path $testRoot 'agent.log'
        $SelectionPath = Join-Path $testRoot 'selection.json'
        ConvertTo-Json -InputObject @(
            @{ updateId = 'update-a'; revisionNumber = 10 },   # offered: installed
            @{ updateId = 'update-a'; revisionNumber = 11 },   # revision changed: skipped
            @{ updateId = 'missing'; revisionNumber = 99 }     # no longer offered: skipped
        ) | Set-Content -LiteralPath $SelectionPath

        $wuaResult = [pscustomobject]@{ ResultCode = 2; HResult = 0; RebootRequired = $false }
        $wuaResult | Add-Member ScriptMethod GetUpdateResult { param($i) $wuaResult }
        $offered = [pscustomobject]@{ Items = @(
                [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'UPDATE-A'; RevisionNumber = 10 }; Title = 'A'; Type = 1; EulaAccepted = $true },
                [pscustomobject]@{ Identity = [pscustomobject]@{ UpdateID = 'UPDATE-B'; RevisionNumber = 20 }; Title = 'B'; Type = 1; EulaAccepted = $true }); Count = 2 }
        $offered | Add-Member ScriptMethod Item { param($i) $this.Items[$i] }
        $script:Chosen = [pscustomobject]@{ Items = @(); Count = 0 }
        $script:Chosen | Add-Member ScriptMethod Add { param($u) $this.Items += $u; $this.Count = $this.Items.Count }
        $installer = [pscustomobject]@{ Updates = $null }
        $installer | Add-Member ScriptMethod Install { $wuaResult }
        $downloader = [pscustomobject]@{ Updates = $null }
        $downloader | Add-Member ScriptMethod Download { $wuaResult }
        $session = [pscustomobject]@{}
        $session | Add-Member ScriptMethod CreateUpdateDownloader { $downloader }
        $session | Add-Member ScriptMethod CreateUpdateInstaller { $installer }
        function Search-Updates { [pscustomobject]@{ session = $session; result = $wuaResult; updates = $offered } }
        function New-Object { param([string]$TypeName, [switch]$ComObject) $script:Chosen }
        function Get-SystemSnapshot { [ordered]@{ pendingReboot = [ordered]@{ isPending = $false } } }
        function Get-ClusterState { [ordered]@{ membership = $script:Membership } }

        $script:Membership = 'NotMember'
        $script:Status = [ordered]@{ mode = 'Install'; status = 'Started'; outcome = $null; updates = @() }
        Invoke-Install
        Assert ($script:Chosen.Count -eq 1 -and $script:Chosen.Items[0].Identity.RevisionNumber -eq 10) 'Something other than the approved revision was installed.'
        Assert ((@($script:Status.skipped | ForEach-Object { $_.reason }) -join ',') -eq 'RevisionChanged,Missing') 'Changed and missing revisions were not reported.'

        $script:Membership = 'Member'
        $script:Chosen = [pscustomobject]@{ Items = @(); Count = 0 }
        $script:Status = [ordered]@{ mode = 'Install'; status = 'Started'; outcome = $null; updates = @() }
        try { Invoke-Install; throw 'not blocked' } catch { Assert ($script:Status.outcome -eq 'BlockedByCluster') 'The agent did not block a cluster member.' }
    }
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failed) { Write-Host 'Checks failed.' -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
exit 0
