[CmdletBinding()]
param(
    [switch]$NoUi,
    [switch]$SmokeUi
)

# Windows Patch Wizard launcher.  This file owns the WinForms user interface;
# state and Guest Operations stay in the controller and adapter scripts.

$script:WizardRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ControllerPath = Join-Path $script:WizardRoot 'scripts\RunController.ps1'
$script:Wizard = @{
    Form = $null
    Tabs = $null
    Timer = $null
    RunPath = $null
    RunState = $null
    VCenterCredential = $null
    GuestCredential = $null
    ActivePowerShell = $null
    ActiveAsyncResult = $null
    ActiveAction = $null
    ActiveStartedAt = $null
    LastRunLog = ''
    LastRunReadError = ''
    UpdatingGrid = $false
    UpdateRows = @()
    Controls = @{}
}

$savedPreference = $ErrorActionPreference
. $script:ControllerPath
$ErrorActionPreference = $savedPreference

function Get-WizardRunDirectory {
    if ([string]::IsNullOrWhiteSpace([string]$script:Wizard.RunPath)) { return $null }
    if (Test-Path -LiteralPath $script:Wizard.RunPath -PathType Leaf) {
        return (Split-Path -Parent $script:Wizard.RunPath)
    }
    return $script:Wizard.RunPath
}

function Set-WizardStatus {
    param([Parameter(Mandatory = $true)][string]$Message)

    if ($null -ne $script:Wizard.Controls.StatusLabel) {
        $script:Wizard.Controls.StatusLabel.Text = $Message
    }
    if ($null -ne $script:Wizard.Controls.StatusText) {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        $script:Wizard.Controls.StatusText.AppendText(('[{0}] {1}{2}' -f $stamp, $Message, [Environment]::NewLine))
        $script:Wizard.Controls.StatusText.SelectionStart = $script:Wizard.Controls.StatusText.TextLength
        $script:Wizard.Controls.StatusText.ScrollToCaret()
    }
}

function Show-WizardError {
    param([Parameter(Mandatory = $true)][string]$Message)
    Set-WizardStatus -Message $Message
    if ($null -ne $script:Wizard.Form) {
        [void][System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, $Message, 'Patch Wizard', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
}

function Get-WizardPositiveInteger {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$TextBox,
        [Parameter(Mandatory = $true)][string]$Name
    )

    [int]$value = 0
    if (-not [int]::TryParse($TextBox.Text.Trim(), [ref]$value) -or $value -lt 1) {
        throw ('{0} must be a positive whole number.' -f $Name)
    }
    return $value
}

function ConvertTo-WizardVmEntries {
    param([Parameter(Mandatory = $true)][string]$Text)

    $entries = @()
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $parts = $trimmed.Split(@('|'), 2, [System.StringSplitOptions]::None)
        if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
            throw ('VM line {0} must use the format: VM name|expected FQDN.' -f $lineNumber)
        }
        $entries += [pscustomobject]@{
            VmName = $parts[0].Trim()
            ExpectedFqdn = $parts[1].Trim().TrimEnd('.')
        }
    }
    if ($entries.Count -eq 0) {
        throw 'Enter at least one VM as VM name|expected FQDN.'
    }
    return @($entries)
}

function Get-WizardConfigFromControls {
    $controls = $script:Wizard.Controls
    if ([string]::IsNullOrWhiteSpace($controls.VCenter.Text)) { throw 'vCenter is required.' }
    if ([string]::IsNullOrWhiteSpace($controls.OutputRoot.Text)) { throw 'Output root is required.' }

    $entries = ConvertTo-WizardVmEntries -Text $controls.VmEntries.Text
    $scanConcurrency = Get-WizardPositiveInteger -TextBox $controls.ScanConcurrency -Name 'Scan concurrency'
    $installConcurrency = Get-WizardPositiveInteger -TextBox $controls.InstallConcurrency -Name 'Install concurrency'
    $rebootBatch = Get-WizardPositiveInteger -TextBox $controls.RebootBatch -Name 'Reboot batch size'
    $scanLimit = Get-WizardPositiveInteger -TextBox $controls.ScanLimit -Name 'Scan limit'
    $installLimit = Get-WizardPositiveInteger -TextBox $controls.InstallLimit -Name 'Install limit'
    $rebootLimit = Get-WizardPositiveInteger -TextBox $controls.RebootLimit -Name 'Reboot confirmation limit'

    return [pscustomobject]@{
        VCenter = $controls.VCenter.Text.Trim()
        OutputRoot = $controls.OutputRoot.Text.Trim()
        Options = [pscustomobject]@{
            ScanConcurrency = $scanConcurrency
            InstallConcurrency = $installConcurrency
            RebootBatchSize = $rebootBatch
            ScanTimeoutMinutes = $scanLimit
            InstallTimeoutMinutes = $installLimit
            RebootConfirmationTimeoutMinutes = $rebootLimit
            IgnoreVCenterCertificate = [bool]$controls.IgnoreVCenter.Checked
            IgnoreEsxiCertificatesForFileTransfers = [bool]$controls.IgnoreEsxi.Checked
        }
    }
}

function Get-WizardSelectedUpdateKey {
    param($Update)
    $id = [string](Get-PatchValue -InputObject $Update -Names @('updateId') -Default '')
    $revision = Get-PatchValue -InputObject $Update -Names @('revisionNumber') -Default $null
    if ([string]::IsNullOrWhiteSpace($id) -or $null -eq $revision) { return $null }
    return ('{0}|{1}' -f $id.ToLowerInvariant(), [int64]$revision)
}

function Save-WizardSelections {
    if ($null -eq $script:Wizard.RunState -or [string]::IsNullOrWhiteSpace([string]$script:Wizard.RunPath)) {
        throw 'Create or resume a run before saving update selections.'
    }

    $allSelected = @()
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $vmName = [string](Get-PatchValue $vm @('vmName') '')
        $rows = @($script:Wizard.UpdateRows | Where-Object { $_.VmName -eq $vmName })
        $selected = @()
        foreach ($row in $rows) {
            $record = $row.Update
            $key = Get-WizardSelectedUpdateKey -Update $record
            if ($row.Selected -and $null -ne $key) {
                $id = [string](Get-PatchValue $record @('updateId') '')
                $revision = [int64](Get-PatchValue $record @('revisionNumber') 0)
                $selected += [pscustomobject][ordered]@{
                    updateId = $id
                    revisionNumber = $revision
                }
                $allSelected += [pscustomobject][ordered]@{
                    vmName = $vmName
                    updateId = $id
                    revisionNumber = $revision
                }
                Set-PatchValue -InputObject $record -Name 'selected' -Value $true
            }
            else {
                Set-PatchValue -InputObject $record -Name 'selected' -Value $false
            }
        }
        Set-PatchValue -InputObject $vm -Name 'selectedUpdates' -Value @($selected)
        Set-PatchValue -InputObject $vm -Name 'selectionSaved' -Value $true
    }

    Set-PatchValue -InputObject $script:Wizard.RunState -Name 'selectedUpdates' -Value @($allSelected)
    Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
    Set-WizardStatus -Message ('Saved {0} exact update selections.' -f $allSelected.Count)
    Refresh-WizardSelectionGrid
}

function Set-WizardSettingsFromRun {
    param([Parameter(Mandatory = $true)]$RunState)

    $controls = $script:Wizard.Controls
    $options = Get-PatchValue $RunState @('options') ([pscustomobject]@{})
    $limits = Get-PatchValue $options @('limits') ([pscustomobject]@{})
    $controls.VCenter.Text = [string](Get-PatchValue $RunState @('vCenter') '')
    $controls.OutputRoot.Text = [string](Split-Path -Parent (Split-Path -Parent ([string](Get-PatchValue $RunState @('runPath') ''))))
    if ([string]::IsNullOrWhiteSpace($controls.OutputRoot.Text)) {
        $runDirectory = Split-Path -Parent ([string](Get-PatchValue $RunState @('runPath') ''))
        $controls.OutputRoot.Text = Split-Path -Parent $runDirectory
    }
    $controls.ScanConcurrency.Text = [string](Get-PatchValue $options @('scanConcurrency') 3)
    $controls.InstallConcurrency.Text = [string](Get-PatchValue $options @('installConcurrency') 3)
    $controls.RebootBatch.Text = [string](Get-PatchValue $options @('rebootBatchSize') 1)
    $controls.ScanLimit.Text = [string](Get-PatchValue $limits @('scanTimeoutMinutes') 30)
    $controls.InstallLimit.Text = [string](Get-PatchValue $limits @('installTimeoutMinutes') 180)
    $controls.RebootLimit.Text = [string](Get-PatchValue $limits @('rebootConfirmationTimeoutMinutes') 30)
    $controls.IgnoreVCenter.Checked = [bool](Get-PatchValue $options @('ignoreVCenterCertificate') $false)
    $controls.IgnoreEsxi.Checked = [bool](Get-PatchValue $options @('ignoreEsxiCertificatesForFileTransfers') $false)

    $lines = @()
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $RunState @('vms') @()))) {
        $lines += ('{0}|{1}' -f [string](Get-PatchValue $vm @('vmName') ''), [string](Get-PatchValue $vm @('expectedFqdn') ''))
    }
    $controls.VmEntries.Text = ($lines -join [Environment]::NewLine)
}

function New-WizardRun {
    try {
        if ($null -ne $script:Wizard.ActivePowerShell) { throw 'An action is already running.' }
        $config = Get-WizardConfigFromControls
        $entries = ConvertTo-WizardVmEntries -Text $script:Wizard.Controls.VmEntries.Text
        $script:Wizard.RunState = New-PatchRun -Config $config -VMEntries $entries
        $script:Wizard.RunPath = [string](Get-PatchValue $script:Wizard.RunState @('runPath') '')
        $script:Wizard.VCenterCredential = $null
        $script:Wizard.GuestCredential = $null
        $script:Wizard.Controls.OpenLogs.Enabled = $true
        $script:Wizard.Controls.RunPathLabel.Text = ('Run: {0}' -f $script:Wizard.RunPath)
        Set-WizardStatus -Message ('Created run {0}.' -f [string](Get-PatchValue $script:Wizard.RunState @('runId') ''))
        Refresh-WizardVmGrid
        Refresh-WizardSelectionGrid
        Update-WizardStepState
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Request-WizardCredential {
    param([ValidateSet('vCenter', 'guest')][string]$Kind)

    $message = if ($Kind -eq 'vCenter') { 'Enter the vCenter credential for this run.' } else { 'Enter the Windows guest credential for this run.' }
    try {
        $credential = Get-Credential -Message $message
    }
    catch {
        Show-WizardError -Message ('Credential prompt failed: {0}' -f $_.Exception.Message)
        return
    }
    if ($null -eq $credential) { return }
    if ($Kind -eq 'vCenter') {
        $script:Wizard.VCenterCredential = $credential
        Set-WizardStatus -Message ('vCenter credential held in memory for {0}.' -f $credential.UserName)
    }
    else {
        $script:Wizard.GuestCredential = $credential
        Set-WizardStatus -Message ('Guest credential held in memory for {0}.' -f $credential.UserName)
    }
}

function Resume-WizardRun {
    if ($null -ne $script:Wizard.ActivePowerShell) {
        Show-WizardError -Message 'An action is already running.'
        return
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Patch run (run.json)|run.json|JSON files (*.json)|*.json|All files (*.*)|*.*'
    $dialog.Title = 'Resume patch run'
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($script:Wizard.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    try {
        $runPath = $dialog.FileName
        $state = Read-PatchRun -RunPath $runPath
        Write-PatchSummary -RunPath $runPath -RunState $state
        $script:Wizard.RunState = $state
        $script:Wizard.RunPath = $runPath
        $script:Wizard.VCenterCredential = $null
        $script:Wizard.GuestCredential = $null
        Set-WizardSettingsFromRun -RunState $state
        $script:Wizard.Controls.OpenLogs.Enabled = $true
        $script:Wizard.Controls.RunPathLabel.Text = ('Run: {0}' -f $script:Wizard.RunPath)
        Set-WizardStatus -Message 'Run loaded. Credentials are required again for a resumed run.'

        Request-WizardCredential -Kind vCenter
        if ($null -eq $script:Wizard.VCenterCredential) { throw 'Resume cancelled because the vCenter credential was not supplied.' }
        Refresh-WizardVmGrid
        Refresh-WizardSelectionGrid
        Update-WizardStepState
        $currentAction = [string](Get-PatchValue $state @('currentAction') '')
        $credentialDecision = Resolve-WizardCredentialRejection -Action $currentAction
        if ($credentialDecision -eq 'None') {
            Request-WizardCredential -Kind guest
            if ($null -eq $script:Wizard.GuestCredential) { throw 'Resume cancelled because the guest credential was not supplied.' }
        }
        if ($credentialDecision -eq 'None' -or $credentialDecision -eq 'Retry') {
            Set-WizardStatus -Message 'Run resumed in memory. Credentials are not written to run.json.'
        }
        if ($credentialDecision -eq 'Retry' -and $currentAction -in @('Scan', 'Install', 'Reboot', 'Verify')) {
            Start-WizardAction -Action $currentAction -ApprovalAlreadyGiven
        }
        elseif ($credentialDecision -eq 'None' -and [string](Get-PatchValue $state @('status') '') -eq 'Running' -and $currentAction -in @('Scan', 'Install', 'Reboot', 'Verify')) {
            Start-WizardAction -Action $currentAction -ApprovalAlreadyGiven
        }
    }
    catch {
        $script:Wizard.RunState = $null
        $script:Wizard.RunPath = $null
        $script:Wizard.Controls.OpenLogs.Enabled = $false
        Show-WizardError -Message $_.Exception.Message
    }
}

function Open-WizardLogs {
    $directory = Get-WizardRunDirectory
    if ([string]::IsNullOrWhiteSpace($directory) -or -not (Test-Path -LiteralPath $directory -PathType Container)) {
        Show-WizardError -Message 'Create or resume a run before opening logs.'
        return
    }
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($directory) -WindowStyle Normal | Out-Null
    }
    catch {
        Show-WizardError -Message ('Could not open the run folder: {0}' -f $_.Exception.Message)
    }
}

function Get-WizardUpdateRowsFromState {
    $rows = @()
    if ($null -eq $script:Wizard.RunState) { return @() }
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $vmName = [string](Get-PatchValue $vm @('vmName') '')
        $updates = @(Get-PatchArray (Get-PatchValue $vm @('availableUpdates') @()))
        if ($updates.Count -eq 0) {
            $agentStatus = Get-PatchValue $vm @('agentStatus') $null
            $updates = @(Get-PatchArray (Get-PatchValue $agentStatus @('updates') @()))
        }
        $savedSelection = [bool](Get-PatchValue $vm @('selectionSaved') $false)
        $savedKeys = @{}
        foreach ($selectedUpdate in @(Get-PatchArray (Get-PatchValue $vm @('selectedUpdates') @()))) {
            $savedKey = Get-WizardSelectedUpdateKey -Update $selectedUpdate
            if ($null -ne $savedKey) { $savedKeys[$savedKey] = $true }
        }
        foreach ($update in $updates) {
            $key = Get-WizardSelectedUpdateKey -Update $update
            if ($null -eq $key) { continue }
            $selected = if ($savedSelection) { $savedKeys.ContainsKey($key) } else { $true }
            $rows += [pscustomobject]@{
                VmName = $vmName
                VmRecord = $vm
                Update = $update
                Key = $key
                Selected = $selected
            }
        }
    }
    return @($rows)
}

function Refresh-WizardSelectionGrid {
    if ($null -eq $script:Wizard.Controls.SelectGrid) { return }
    $grid = $script:Wizard.Controls.SelectGrid
    $script:Wizard.UpdateRows = @(Get-WizardUpdateRowsFromState)
    $grid.Rows.Clear()
    foreach ($row in $script:Wizard.UpdateRows) {
        $record = $row.Update
        $type = [string](Get-PatchValue $record @('type') 'Unknown')
        $browseOnly = [bool](Get-PatchValue $record @('browseOnly') $false)
        $eulaAccepted = [bool](Get-PatchValue $record @('eulaAccepted') $false)
        $labels = @()
        if ($type -eq 'Driver') { $labels += 'Driver' }
        if ($browseOnly) { $labels += 'Browse-only' }
        if (-not $eulaAccepted) { $labels += 'EULA required' }
        $labelText = if ($labels.Count -gt 0) { $labels -join ', ' } else { 'Standard update' }
        $index = $grid.Rows.Add([bool]$row.Selected,
            $row.VmName,
            [string](Get-PatchValue $record @('updateId') ''),
            [string](Get-PatchValue $record @('revisionNumber') ''),
            [string](Get-PatchValue $record @('title') ''),
            $type,
            $labelText)
        $grid.Rows[$index].Tag = $row
    }
    if ($script:Wizard.UpdateRows.Count -eq 0) {
        Set-WizardStatus -Message 'No offered updates are available yet. Run Scan first.'
    }
}

function Refresh-WizardVmGrid {
    if ($null -eq $script:Wizard.Controls.VmGrid) { return }
    $grid = $script:Wizard.Controls.VmGrid
    $vms = @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))
    $script:Wizard.UpdatingGrid = $true
    try {
        if ($grid.Rows.Count -ne $vms.Count) {
            $grid.Rows.Clear()
            foreach ($vm in $vms) {
                [void]$grid.Rows.Add('', '', '', '', '', '', '')
            }
        }
        for ($i = 0; $i -lt $vms.Count; $i++) {
            $vm = $vms[$i]
            $updates = @(Get-PatchArray (Get-PatchValue $vm @('availableUpdates') @()))
            if ($updates.Count -eq 0) {
                $updates = @(Get-PatchArray (Get-PatchValue (Get-PatchValue $vm @('agentStatus') $null) @('updates') @()))
            }
            $reboot = Get-PatchValue $vm @('reboot') $null
            $grid.Rows[$i].Cells[0].Value = [string](Get-PatchValue $vm @('vmName') '')
            $grid.Rows[$i].Cells[1].Value = [string](Get-PatchValue $vm @('expectedFqdn') '')
            $grid.Rows[$i].Cells[2].Value = [string](Get-PatchValue $vm @('status') 'Pending')
            $grid.Rows[$i].Cells[3].Value = [string](Get-PatchValue $vm @('currentAction') '')
            $grid.Rows[$i].Cells[4].Value = [string]$updates.Count
            $grid.Rows[$i].Cells[5].Value = [string](Get-PatchValue $reboot @('status') 'NotRequested')
            $errors = @(Get-PatchArray (Get-PatchValue $vm @('errors') @()))
            $grid.Rows[$i].Cells[6].Value = [string]$errors.Count
        }
    }
    finally {
        $script:Wizard.UpdatingGrid = $false
    }
}

function Get-WizardPendingRebootVms {
    return @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()) | Where-Object { Test-PatchVmRequiresReboot -VMRecord $_ })
}

function Refresh-WizardRebootGrid {
    $grid = $script:Wizard.Controls.RebootGrid
    if ($null -eq $grid) { return }
    $grid.Rows.Clear()
    foreach ($vm in @(Get-WizardPendingRebootVms)) {
        $index = $grid.Rows.Add(
            [string](Get-PatchValue $vm @('vmName') ''),
            [string](Get-PatchValue $vm @('expectedFqdn') ''),
            [string](Get-PatchValue $vm @('status') 'Pending'),
            [string](Get-PatchValue (Get-PatchValue $vm @('agentStatus') $null) @('outcome') 'Pending reboot'))
        $grid.Rows[$index].Tag = $vm
    }
    $script:Wizard.Controls.RebootButton.Enabled = ($grid.Rows.Count -gt 0 -and $null -eq $script:Wizard.ActivePowerShell)
}

function Sync-WizardAvailableUpdates {
    if ($null -eq $script:Wizard.RunState) { return }
    $changed = $false
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $agentStatus = Get-PatchValue $vm @('agentStatus') $null
        $updates = @(Get-PatchArray (Get-PatchValue $agentStatus @('updates') @()))
        if ($updates.Count -gt 0) {
            Set-PatchValue -InputObject $vm -Name 'availableUpdates' -Value @($updates)
            $changed = $true
        }
    }
    if ($changed) { Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null }
}

function Get-WizardUnresolvedMutatingStep {
    if ($null -eq $script:Wizard.RunState) { return $null }

    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $blocker = Get-PatchMutatingStepBlocker -RunState $script:Wizard.RunState -VMRecord $vm -CurrentStep $null
        if ($null -ne $blocker) {
            return $blocker
        }
    }
    return $null
}

function Update-WizardStepState {
    if ($null -eq $script:Wizard.RunState) { return }
    $state = [string](Get-PatchValue $script:Wizard.RunState @('status') 'Created')
    $active = $null -ne $script:Wizard.ActivePowerShell
    $script:Wizard.Controls.ResumeButton.Enabled = (-not $active)
    $script:Wizard.Controls.ScanButton.Enabled = (-not $active)
    $script:Wizard.Controls.InstallButton.Enabled = (-not $active)
    $script:Wizard.Controls.VerifyButton.Enabled = (-not $active)
    $script:Wizard.Controls.SaveSelectionButton.Enabled = (-not $active)
    $unresolvedMutatingStep = Get-WizardUnresolvedMutatingStep
    $script:Wizard.Controls.StartRoundButton.Enabled = (-not $active -and $null -eq $unresolvedMutatingStep -and ($state -match '(?i)completed|needsreview|stopped'))
    $script:Wizard.Controls.FinishButton.Enabled = (-not $active)
    Refresh-WizardRebootGrid
}

function Update-WizardProgress {
    if ($null -eq $script:Wizard.Controls.ProgressBar -or $null -eq $script:Wizard.RunState) { return }
    $vms = @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))
    $total = $vms.Count
    $actionText = [string](Get-PatchValue $script:Wizard.RunState @('currentAction') '')
    $done = 0
    if (-not [string]::IsNullOrWhiteSpace($actionText)) {
        $done = @($vms | Where-Object { [string](Get-PatchValue $_ @('lastProcessedAction') '') -eq $actionText }).Count
    }
    $percent = 0
    if ($total -gt 0) {
        $percent = [int][Math]::Floor(($done * 100.0) / $total)
    }
    $script:Wizard.Controls.ProgressBar.Value = $percent
    if ([string]::IsNullOrWhiteSpace($actionText)) { $actionText = 'No action' }
    $script:Wizard.Controls.ProgressLabel.Text = ('{0}: {1} of {2} VM rows processed' -f $actionText, $done, $total)
}

function Refresh-WizardRunLog {
    $directory = Get-WizardRunDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) { return }
    $logPath = Join-Path $directory 'run.log'
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return }
    try {
        $content = (Get-Content -LiteralPath $logPath -Tail 80 -ErrorAction Stop) -join [Environment]::NewLine
        if ($content -ne $script:Wizard.LastRunLog) {
            $script:Wizard.LastRunLog = $content
            $script:Wizard.Controls.StatusText.Text = $content
            $script:Wizard.Controls.StatusText.SelectionStart = $script:Wizard.Controls.StatusText.TextLength
            $script:Wizard.Controls.StatusText.ScrollToCaret()
        }
    }
    catch {
        $script:Wizard.LastRunReadError = $_.Exception.Message
    }
}

function Get-WizardActionResult {
    param($Output)
    foreach ($item in @($Output | Where-Object { $null -ne $_ })) {
        if ($null -ne $item.PSObject.Properties['action'] -or $null -ne $item.PSObject.Properties['status']) {
            $candidate = $item
        }
    }
    return $candidate
}

function Show-WizardCredentialDecision {
    param([Parameter(Mandatory = $true)][string[]]$VmNames)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Guest credential rejected'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 180)
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(12, 12)
    $label.Size = New-Object System.Drawing.Size(536, 72)
    $label.Text = ('The guest credential was rejected for: {0}{1}{1}Choose Retry for a fresh credential, Skip these VMs for the rest of this run, or Stop.' -f ($VmNames -join ', '), [Environment]::NewLine)
    $label.AutoSize = $false
    $dialog.Controls.Add($label)
    $retry = New-Object System.Windows.Forms.Button
    $retry.Text = 'Retry'
    $retry.Size = New-Object System.Drawing.Size(100, 30)
    $retry.Location = New-Object System.Drawing.Point(150, 120)
    $skip = New-Object System.Windows.Forms.Button
    $skip.Text = 'Skip these VMs'
    $skip.Size = New-Object System.Drawing.Size(150, 30)
    $skip.Location = New-Object System.Drawing.Point(260, 120)
    $stop = New-Object System.Windows.Forms.Button
    $stop.Text = 'Stop'
    $stop.Size = New-Object System.Drawing.Size(100, 30)
    $stop.Location = New-Object System.Drawing.Point(420, 120)
    $dialog.Controls.AddRange(@($retry, $skip, $stop))
    $retry.Add_Click({ $dialog.Tag = 'Retry'; $dialog.Close() })
    $skip.Add_Click({ $dialog.Tag = 'Skip'; $dialog.Close() })
    $stop.Add_Click({ $dialog.Tag = 'Stop'; $dialog.Close() })
    [void]$dialog.ShowDialog($script:Wizard.Form)
    $choice = [string]$dialog.Tag
    $dialog.Dispose()
    if ([string]::IsNullOrWhiteSpace($choice)) { return 'Stop' }
    return $choice
}

function Resolve-WizardCredentialRejection {
    param([string]$Action)

    # Plan step 1: a rejected guest credential offers Retry, Skip (for the rest of this run), or Stop.
    $affected = @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()) |
        Where-Object { [string](Get-PatchValue $_ @('status') '') -eq 'GuestCredentialRejected' })
    if ($affected.Count -eq 0) { return 'None' }

    $names = @($affected | ForEach-Object { [string](Get-PatchValue $_ @('vmName') '') })
    $choice = Show-WizardCredentialDecision -VmNames $names
    if ($choice -eq 'Retry') {
        $script:Wizard.GuestCredential = $null
        Request-WizardCredential -Kind guest
        if ($null -eq $script:Wizard.GuestCredential) {
            Set-WizardStatus -Message 'Retry cancelled because no replacement guest credential was supplied.'
            return 'Cancel'
        }
        foreach ($vm in $affected) { Set-PatchValue -InputObject $vm -Name 'status' -Value 'Pending' }
        Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
        return 'Retry'
    }
    if ($choice -eq 'Skip') {
        foreach ($vm in $affected) { Set-PatchValue -InputObject $vm -Name 'status' -Value 'SkippedGuestAccount' }
        $message = 'Operator skipped the rejected guest account for this run.'
    }
    else {
        $script:Wizard.GuestCredential = $null
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'status' -Value 'Stopped'
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'stopReason' -Value 'Operator stopped after guest credential rejection.'
        $message = 'Operator stopped after guest credential rejection.'
    }
    Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
    Write-PatchEvent -RunPath $script:Wizard.RunPath -Message $message -Step $Action -Level 'WARN'
    Write-PatchSummary -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState
    Set-WizardStatus -Message $message
    return $choice
}

function Start-WizardAction {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install', 'Reboot', 'Verify')][string]$Action,
        [switch]$ApprovalAlreadyGiven
    )

    try {
        if ($null -ne $script:Wizard.ActivePowerShell) { throw 'An action is already running.' }
        if ($null -eq $script:Wizard.RunState -or [string]::IsNullOrWhiteSpace([string]$script:Wizard.RunPath)) { throw 'Create or resume a run first.' }
        if ($null -eq $script:Wizard.VCenterCredential) { Request-WizardCredential -Kind vCenter }
        $credentialDecision = Resolve-WizardCredentialRejection -Action $Action
        if ($credentialDecision -in @('Skip', 'Stop', 'Cancel')) { return }
        if ($null -eq $script:Wizard.GuestCredential) { Request-WizardCredential -Kind guest }
        if ($null -eq $script:Wizard.VCenterCredential -or $null -eq $script:Wizard.GuestCredential) { throw 'Both vCenter and guest credentials are required.' }
        if ($Action -eq 'Install' -and -not $ApprovalAlreadyGiven) {
            Save-WizardSelections
            $selectedCount = @($script:Wizard.RunState.selectedUpdates).Count
            $installPrompt = if ($selectedCount -eq 0) { 'No updates are selected. Continue and mark all VM installations as skipped?' } else { 'Install {0} explicitly selected update entries? The agent will search again and install only matching UpdateID and RevisionNumber values.' -f $selectedCount }
            $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, $installPrompt, 'Approve installation', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($Action -eq 'Reboot' -and -not $ApprovalAlreadyGiven) {
            Refresh-WizardRebootGrid
            $pending = @(Get-WizardPendingRebootVms)
            if ($pending.Count -eq 0) { throw 'No VM currently has a pending reboot.' }
            $names = @($pending | ForEach-Object { [string](Get-PatchValue $_ @('vmName') '') })
            $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, ('Approve reboot for pending VM(s): {0}' -f ($names -join ', ')), 'Approve reboot', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $controller = $script:ControllerPath
        $runPath = [string]$script:Wizard.RunPath
        $vcCredential = $script:Wizard.VCenterCredential
        $guestCredential = $script:Wizard.GuestCredential
        $workerScript = {
            param($ControllerPath, $ActionName, $RunFilePath, $VCenterCredential, $GuestCredential)
            try {
                . $ControllerPath
                return (Invoke-PatchAction -Action $ActionName -RunPath $RunFilePath -VCenterCredential $VCenterCredential -GuestCredential $GuestCredential)
            }
            catch {
                return [pscustomobject]@{ status = 'Stopped'; action = $ActionName; runPath = $RunFilePath; error = $_.Exception.Message; vmResults = @() }
            }
        }
        $powerShell = [PowerShell]::Create()
        [void]$powerShell.AddScript($workerScript.ToString())
        [void]$powerShell.AddArgument($controller)
        [void]$powerShell.AddArgument($Action)
        [void]$powerShell.AddArgument($runPath)
        [void]$powerShell.AddArgument($vcCredential)
        [void]$powerShell.AddArgument($guestCredential)
        $script:Wizard.ActivePowerShell = $powerShell
        $script:Wizard.ActiveAsyncResult = $powerShell.BeginInvoke()
        $script:Wizard.ActiveAction = $Action
        $script:Wizard.ActiveStartedAt = Get-Date
        Set-WizardStatus -Message ('{0} is running asynchronously. The window remains responsive.' -f $Action)
        Update-WizardStepState
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Complete-WizardAction {
    if ($null -eq $script:Wizard.ActivePowerShell -or $null -eq $script:Wizard.ActiveAsyncResult) { return }
    if (-not $script:Wizard.ActiveAsyncResult.IsCompleted) { return }

    $action = [string]$script:Wizard.ActiveAction
    $powerShell = $script:Wizard.ActivePowerShell
    $output = @()
    try {
        $output = @($powerShell.EndInvoke($script:Wizard.ActiveAsyncResult))
    }
    catch {
        $output = @([pscustomobject]@{ status = 'Stopped'; action = $action; error = $_.Exception.Message; vmResults = @() })
    }
    try { $powerShell.Dispose() } catch { }
    $script:Wizard.ActivePowerShell = $null
    $script:Wizard.ActiveAsyncResult = $null
    $script:Wizard.ActiveAction = $null
    $result = Get-WizardActionResult -Output $output

    try {
        $script:Wizard.RunState = Read-PatchRun -RunPath $script:Wizard.RunPath
        Sync-WizardAvailableUpdates
    }
    catch {
        Set-WizardStatus -Message ('Action finished, but run state could not be read: {0}' -f $_.Exception.Message)
    }

    if ($null -ne $result) {
        $resultStatus = [string](Get-PatchValue $result @('status') 'Unknown')
        $credentialDecision = Resolve-WizardCredentialRejection -Action $action
        if ($credentialDecision -eq 'Retry') {
            Start-WizardAction -Action $action -ApprovalAlreadyGiven
            return
        }
        if ($credentialDecision -eq 'None') {
            Set-WizardStatus -Message ('{0} finished with status {1}.' -f $action, $resultStatus)
        }
    }

    Refresh-WizardVmGrid
    Refresh-WizardSelectionGrid
    Refresh-WizardRebootGrid
    Refresh-WizardRunLog
    Update-WizardProgress
    Update-WizardStepState
    if ($credentialDecision -in @('Skip', 'Stop', 'Cancel')) { return }
    switch ($action) {
        'Scan' { $script:Wizard.Tabs.SelectedIndex = 2; Set-WizardStatus -Message 'Scan finished. Review and save the offered update selections.' }
        'Install' { $script:Wizard.Tabs.SelectedIndex = 4; Set-WizardStatus -Message 'Install finished. Only VMs with fresh pending reboot evidence are shown.' }
        'Reboot' { $script:Wizard.Tabs.SelectedIndex = 5; Set-WizardStatus -Message 'Reboot action finished. Run Verify for a fresh result.' }
        'Verify' { $script:Wizard.Tabs.SelectedIndex = 5; Set-WizardStatus -Message 'Verify finished. Start another round explicitly or finish the run.' }
    }
}

function Start-WizardNewRound {
    try {
        if ($null -eq $script:Wizard.RunState) { throw 'Create or resume a run first.' }
        $unresolvedMutatingStep = Get-WizardUnresolvedMutatingStep
        if ($null -ne $unresolvedMutatingStep) {
            $action = [string](Get-PatchValue $unresolvedMutatingStep @('action') 'mutating')
            Set-WizardStatus -Message ('The started {0} step has no final result. Check the guest, then use Mark steps reviewed.' -f $action)
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, 'Start a new round? This clears the current offered update lists and selections. Run Scan again to obtain a fresh selection.', 'Start another round', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $round = [int](Get-PatchValue $script:Wizard.RunState @('currentRound') 1) + 1
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'currentRound' -Value $round
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'selectedUpdates' -Value @()
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'currentAction' -Value $null
        foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
            Set-PatchValue -InputObject $vm -Name 'currentRound' -Value $round
            Set-PatchValue -InputObject $vm -Name 'availableUpdates' -Value @()
            Set-PatchValue -InputObject $vm -Name 'selectedUpdates' -Value @()
            Set-PatchValue -InputObject $vm -Name 'selectionSaved' -Value $false
            Set-PatchValue -InputObject $vm -Name 'pendingUpdates' -Value @()
            Set-PatchValue -InputObject $vm -Name 'reboot' -Value ([pscustomobject]@{ status = 'NotRequested'; required = $false; baselineBootTime = $null; requestEvidence = $null; confirmedBootTime = $null })
            # A skipped guest account stays skipped for the rest of the run.
            if ([string](Get-PatchValue $vm @('status') '') -ne 'SkippedGuestAccount') { Set-PatchValue -InputObject $vm -Name 'status' -Value 'Pending' }
            Set-PatchValue -InputObject $vm -Name 'currentAction' -Value $null
            Set-PatchValue -InputObject $vm -Name 'agentStatus' -Value $null
        }
        Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
        Refresh-WizardVmGrid
        Refresh-WizardSelectionGrid
        Refresh-WizardRebootGrid
        $script:Wizard.Tabs.SelectedIndex = 1
        Set-WizardStatus -Message ('Round {0} created. Run Scan to build a fresh update selection.' -f $round)
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Set-WizardStepsReviewed {
    try {
        if ($null -eq $script:Wizard.RunState) { throw 'Create or resume a run first.' }
        $blocked = @()
        foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
            $step = Get-PatchMutatingStepBlocker -RunState $script:Wizard.RunState -VMRecord $vm -CurrentStep $null
            if ($null -ne $step) { $blocked += [pscustomobject]@{ VmName = [string](Get-PatchValue $vm @('vmName') ''); Step = $step } }
        }
        if ($blocked.Count -eq 0) {
            Set-WizardStatus -Message 'There are no unresolved install or reboot steps.'
            return
        }
        $lines = @($blocked | ForEach-Object { '{0}: {1} (round {2})' -f $_.VmName, $_.Step.action, $_.Step.round })
        $prompt = 'These steps have no final agent result:{0}{0}{1}{0}{0}Check each guest manually (agent log, Windows Update history, last boot time). Mark them as reviewed so the VMs can continue?' -f [Environment]::NewLine, ($lines -join [Environment]::NewLine)
        $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, $prompt, 'Mark steps as reviewed', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        foreach ($item in $blocked) {
            Set-PatchValue -InputObject $item.Step -Name 'status' -Value 'Reviewed'
            Write-PatchEvent -RunPath $script:Wizard.RunPath -Message ('Operator marked the unresolved {0} step as reviewed.' -f $item.Step.action) -VMName $item.VmName -Step $item.Step.action -Level 'WARN'
        }
        Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
        Set-WizardStatus -Message ('Marked {0} step(s) as reviewed.' -f $blocked.Count)
        Update-WizardStepState
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Finish-WizardRun {
    try {
        if ($null -eq $script:Wizard.RunState) { throw 'Create or resume a run first.' }
        $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, 'Finish this run and write the current summary files?', 'Finish patch run', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'status' -Value 'Finished'
        Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
        Write-PatchSummary -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState
        Set-WizardStatus -Message 'Run finished. Summary files are available in the run folder.'
        Update-WizardStepState
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Refresh-WizardUi {
    # Only a running background action changes run.json. While idle, the in-memory state is
    # authoritative; re-reading it here would discard changes made behind an open dialog.
    if ($null -eq $script:Wizard.ActivePowerShell) { return }
    try {
        $script:Wizard.RunState = Read-PatchRun -RunPath $script:Wizard.RunPath
        $script:Wizard.LastRunReadError = ''
        Refresh-WizardVmGrid
        Update-WizardProgress
        Update-WizardStepState
        Refresh-WizardRunLog
    }
    catch {
        if ($script:Wizard.LastRunReadError -ne $_.Exception.Message) {
            $script:Wizard.LastRunReadError = $_.Exception.Message
            Set-WizardStatus -Message ('Waiting for a readable run state: {0}' -f $_.Exception.Message)
        }
    }
    Complete-WizardAction
}

function New-WizardLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 140, [int]$Height = 22)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.AutoSize = $false
    return $label
}

function New-WizardTextBox {
    param([int]$X, [int]$Y, [int]$Width = 260, [int]$Height = 24)
    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point($X, $Y)
    $textBox.Size = New-Object System.Drawing.Size($Width, $Height)
    return $textBox
}

function New-WizardGrid {
    param([string[]]$Headers, [int[]]$Widths)
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.ReadOnly = $true
    $grid.MultiSelect = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.AutoGenerateColumns = $false
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText = $Headers[$i]
        $column.Name = ('Column{0}' -f $i)
        $column.Width = $Widths[$i]
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$grid.Columns.Add($column)
    }
    return $grid
}

function Initialize-WizardUi {
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess) {
        throw 'Run the wizard in 64-bit Windows PowerShell 5.1.'
    }
    Import-Module -Name 'VMware.VimAutomation.Core' -ErrorAction Stop
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Windows Patch Wizard'
    $form.StartPosition = 'CenterScreen'
    $form.MinimumSize = New-Object System.Drawing.Size(1050, 700)
    $form.Size = New-Object System.Drawing.Size(1250, 820)
    $form.Padding = New-Object System.Windows.Forms.Padding(8)
    $script:Wizard.Form = $form

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 42
    $title = New-WizardLabel -Text 'Windows patch run' -X 0 -Y 5 -Width 500 -Height 30
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $openLogs = New-Object System.Windows.Forms.Button
    $openLogs.Text = 'Open logs'
    $openLogs.Width = 110
    $openLogs.Dock = [System.Windows.Forms.DockStyle]::Right
    $openLogs.Enabled = $false
    $openLogs.Add_Click({ Open-WizardLogs })
    $header.Controls.AddRange(@($title, $openLogs))
    $form.Controls.Add($header)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:Wizard.Tabs = $tabs
    $form.Controls.Add($tabs)

    $settingsTab = New-Object System.Windows.Forms.TabPage
    $settingsTab.Text = 'Settings'
    $settingsTab.Padding = New-Object System.Windows.Forms.Padding(10)
    $settingsPanel = New-Object System.Windows.Forms.Panel
    $settingsPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $settingsTab.Controls.Add($settingsPanel)
    [void]$tabs.TabPages.Add($settingsTab)

    $vcLabel = New-WizardLabel -Text 'vCenter server' -X 10 -Y 12
    $vcText = New-WizardTextBox -X 155 -Y 9 -Width 360
    $vcButton = New-Object System.Windows.Forms.Button
    $vcButton.Text = 'Get vCenter credential'
    $vcButton.Location = New-Object System.Drawing.Point(530, 8)
    $vcButton.Size = New-Object System.Drawing.Size(170, 27)
    $vcButton.Add_Click({ Request-WizardCredential -Kind vCenter })
    $guestButton = New-Object System.Windows.Forms.Button
    $guestButton.Text = 'Get guest credential'
    $guestButton.Location = New-Object System.Drawing.Point(710, 8)
    $guestButton.Size = New-Object System.Drawing.Size(155, 27)
    $guestButton.Add_Click({ Request-WizardCredential -Kind guest })

    $vmLabel = New-WizardLabel -Text 'VM entries' -X 10 -Y 48
    $vmHint = New-WizardLabel -Text 'One per line: VM name|expected FQDN' -X 155 -Y 48 -Width 400 -Height 22
    $vmHint.ForeColor = [System.Drawing.Color]::DimGray
    $vmText = New-Object System.Windows.Forms.TextBox
    $vmText.Location = New-Object System.Drawing.Point(155, 70)
    $vmText.Size = New-Object System.Drawing.Size(710, 120)
    $vmText.Multiline = $true
    $vmText.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $loadFile = New-Object System.Windows.Forms.Button
    $loadFile.Text = 'Load text file'
    $loadFile.Location = New-Object System.Drawing.Point(875, 70)
    $loadFile.Size = New-Object System.Drawing.Size(125, 28)
    $loadFile.Add_Click({
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        if ($fileDialog.ShowDialog($script:Wizard.Form) -eq [System.Windows.Forms.DialogResult]::OK) {
            try { $script:Wizard.Controls.VmEntries.Text = Get-Content -LiteralPath $fileDialog.FileName -Raw -ErrorAction Stop }
            catch { Show-WizardError -Message ('Could not load VM entries: {0}' -f $_.Exception.Message) }
        }
    })
    $outputLabel = New-WizardLabel -Text 'Output root' -X 10 -Y 205
    $outputText = New-WizardTextBox -X 155 -Y 202 -Width 710
    $outputText.Text = Join-Path $script:WizardRoot 'runs'
    $browseOutput = New-Object System.Windows.Forms.Button
    $browseOutput.Text = 'Browse'
    $browseOutput.Location = New-Object System.Drawing.Point(875, 201)
    $browseOutput.Size = New-Object System.Drawing.Size(125, 28)
    $browseOutput.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = 'Choose the output root for patch runs.'
        $folderDialog.SelectedPath = $script:Wizard.Controls.OutputRoot.Text
        if ($folderDialog.ShowDialog($script:Wizard.Form) -eq [System.Windows.Forms.DialogResult]::OK) { $script:Wizard.Controls.OutputRoot.Text = $folderDialog.SelectedPath }
    })

    $concurrencyLabel = New-WizardLabel -Text 'Scan concurrency' -X 10 -Y 250
    $scanConcurrency = New-WizardTextBox -X 155 -Y 247 -Width 70
    $scanConcurrency.Text = '3'
    $installConcurrencyLabel = New-WizardLabel -Text 'Install concurrency' -X 250 -Y 250
    $installConcurrency = New-WizardTextBox -X 395 -Y 247 -Width 70
    $installConcurrency.Text = '3'
    $rebootBatchLabel = New-WizardLabel -Text 'Reboot batch' -X 490 -Y 250 -Width 90
    $rebootBatch = New-WizardTextBox -X 585 -Y 247 -Width 70
    $rebootBatch.Text = '1'

    $advancedToggle = New-Object System.Windows.Forms.Button
    $advancedToggle.Text = 'Advanced limits (click to expand)'
    $advancedToggle.Location = New-Object System.Drawing.Point(10, 290)
    $advancedToggle.Size = New-Object System.Drawing.Size(240, 28)
    $advancedPanel = New-Object System.Windows.Forms.Panel
    $advancedPanel.Location = New-Object System.Drawing.Point(10, 322)
    $advancedPanel.Size = New-Object System.Drawing.Size(990, 82)
    $advancedPanel.Visible = $false
    $scanLimitLabel = New-WizardLabel -Text 'Scan limit (minutes)' -X 0 -Y 4 -Width 135
    $scanLimit = New-WizardTextBox -X 140 -Y 1 -Width 65
    $scanLimit.Text = '30'
    $installLimitLabel = New-WizardLabel -Text 'Install limit (minutes)' -X 220 -Y 4 -Width 145
    $installLimit = New-WizardTextBox -X 370 -Y 1 -Width 65
    $installLimit.Text = '180'
    $rebootLimitLabel = New-WizardLabel -Text 'Reboot confirmation (min)' -X 445 -Y 4 -Width 190
    $rebootLimit = New-WizardTextBox -X 640 -Y 1 -Width 65
    $rebootLimit.Text = '30'
    $advancedPanel.Controls.AddRange(@($scanLimitLabel, $scanLimit, $installLimitLabel, $installLimit, $rebootLimitLabel, $rebootLimit))
    $advancedToggle.Add_Click({
        $panel = $script:Wizard.Controls.AdvancedPanel
        $button = $script:Wizard.Controls.AdvancedToggle
        $panel.Visible = -not $panel.Visible
        if ($panel.Visible) { $button.Text = 'Advanced limits (click to collapse)' } else { $button.Text = 'Advanced limits (click to expand)' }
    })

    $ignoreVc = New-Object System.Windows.Forms.CheckBox
    $ignoreVc.Text = 'Ignore vCenter certificate'
    $ignoreVc.Location = New-Object System.Drawing.Point(10, 420)
    $ignoreVc.Size = New-Object System.Drawing.Size(250, 25)
    $ignoreEsxi = New-Object System.Windows.Forms.CheckBox
    $ignoreEsxi.Text = 'Ignore ESXi certificates for file transfers'
    $ignoreEsxi.Location = New-Object System.Drawing.Point(280, 420)
    $ignoreEsxi.Size = New-Object System.Drawing.Size(330, 25)
    $certificateHint = New-WizardLabel -Text 'Both options are independent and unchecked by default. Ignoring a certificate means the server identity is not verified.' -X 10 -Y 448 -Width 850 -Height 38
    $certificateHint.ForeColor = [System.Drawing.Color]::DarkRed

    $newRun = New-Object System.Windows.Forms.Button
    $newRun.Text = 'New patch run'
    $newRun.Location = New-Object System.Drawing.Point(10, 505)
    $newRun.Size = New-Object System.Drawing.Size(135, 32)
    $newRun.Add_Click({ New-WizardRun })
    $resume = New-Object System.Windows.Forms.Button
    $resume.Text = 'Resume run'
    $resume.Location = New-Object System.Drawing.Point(155, 505)
    $resume.Size = New-Object System.Drawing.Size(135, 32)
    $resume.Add_Click({ Resume-WizardRun })
    $runPathLabel = New-WizardLabel -Text 'No active run' -X 310 -Y 510 -Width 690 -Height 30
    $runPathLabel.ForeColor = [System.Drawing.Color]::DimGray
    $settingsPanel.Controls.AddRange(@($vcLabel, $vcText, $vcButton, $guestButton, $vmLabel, $vmHint, $vmText, $loadFile, $outputLabel, $outputText, $browseOutput, $concurrencyLabel, $scanConcurrency, $installConcurrencyLabel, $installConcurrency, $rebootBatchLabel, $rebootBatch, $advancedToggle, $advancedPanel, $ignoreVc, $ignoreEsxi, $certificateHint, $newRun, $resume, $runPathLabel))

    $scanTab = New-Object System.Windows.Forms.TabPage
    $scanTab.Text = 'Scan'
    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = 'Start Scan'
    $scanButton.Dock = [System.Windows.Forms.DockStyle]::Top
    $scanButton.Height = 34
    $scanButton.Add_Click({ Start-WizardAction -Action Scan })
    $vmGrid = New-WizardGrid -Headers @('VM', 'Expected FQDN', 'Status', 'Current action', 'Offered updates', 'Reboot', 'Errors') -Widths @(190, 220, 145, 125, 100, 125, 65)
    $scanTab.Controls.Add($vmGrid)
    $scanTab.Controls.Add($scanButton)
    [void]$tabs.TabPages.Add($scanTab)

    $selectTab = New-Object System.Windows.Forms.TabPage
    $selectTab.Text = 'Select updates'
    $selectPanel = New-Object System.Windows.Forms.Panel
    $selectPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $saveSelection = New-Object System.Windows.Forms.Button
    $saveSelection.Text = 'Save selections'
    $saveSelection.Dock = [System.Windows.Forms.DockStyle]::Top
    $saveSelection.Height = 34
    $saveSelection.Add_Click({
        try { Save-WizardSelections }
        catch { Show-WizardError -Message $_.Exception.Message }
    })
    $selectHint = New-WizardLabel -Text 'All offered updates are selected initially. Uncheck individual rows; Driver, Browse-only, and EULA required labels are shown.' -X 8 -Y 37 -Width 1000 -Height 26
    $selectHint.ForeColor = [System.Drawing.Color]::DimGray
    $selectGrid = New-Object System.Windows.Forms.DataGridView
    $selectGrid.Location = New-Object System.Drawing.Point(8, 68)
    $selectGrid.Size = New-Object System.Drawing.Size(1120, 600)
    $selectGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $selectGrid.AllowUserToAddRows = $false
    $selectGrid.AllowUserToDeleteRows = $false
    $selectGrid.MultiSelect = $false
    $selectGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $selectGrid.AutoGenerateColumns = $false
    $checkColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $checkColumn.HeaderText = 'Selected'
    $checkColumn.Name = 'Selected'
    $checkColumn.Width = 65
    $checkColumn.ReadOnly = $false
    [void]$selectGrid.Columns.Add($checkColumn)
    $selectHeaders = @('VM', 'UpdateID', 'Revision', 'Title', 'Type', 'Labels')
    $selectWidths = @(170, 280, 80, 350, 90, 180)
    for ($i = 0; $i -lt $selectHeaders.Count; $i++) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText = $selectHeaders[$i]
        $column.Name = ('SelectColumn{0}' -f $i)
        $column.Width = $selectWidths[$i]
        $column.ReadOnly = $true
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
        [void]$selectGrid.Columns.Add($column)
    }
    $selectGrid.Add_CurrentCellDirtyStateChanged({
        $gridControl = $script:Wizard.Controls.SelectGrid
        if ($null -ne $gridControl -and $gridControl.IsCurrentCellDirty) { $gridControl.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $selectGrid.Add_CellValueChanged({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne 0) { return }
        if ($eventArgs.RowIndex -lt $script:Wizard.UpdateRows.Count) {
            $gridControl = $script:Wizard.Controls.SelectGrid
            $script:Wizard.UpdateRows[$eventArgs.RowIndex].Selected = [bool]$gridControl.Rows[$eventArgs.RowIndex].Cells[0].Value
        }
    })
    $selectPanel.Controls.Add($selectGrid)
    $selectPanel.Controls.Add($selectHint)
    $selectPanel.Controls.Add($saveSelection)
    $selectTab.Controls.Add($selectPanel)
    [void]$tabs.TabPages.Add($selectTab)

    $installTab = New-Object System.Windows.Forms.TabPage
    $installTab.Text = 'Install'
    $installButton = New-Object System.Windows.Forms.Button
    $installButton.Text = 'Approve and start Install'
    $installButton.Dock = [System.Windows.Forms.DockStyle]::Top
    $installButton.Height = 34
    $installButton.Add_Click({ Start-WizardAction -Action Install })
    $installHint = New-WizardLabel -Text 'Installation re-searches Windows Update and uses only saved UpdateID + RevisionNumber selections. The agent does not restart the guest.' -X 12 -Y 48 -Width 1050 -Height 35
    $installHint.ForeColor = [System.Drawing.Color]::DimGray
    $installTab.Controls.Add($installHint)
    $installTab.Controls.Add($installButton)
    [void]$tabs.TabPages.Add($installTab)

    $rebootTab = New-Object System.Windows.Forms.TabPage
    $rebootTab.Text = 'Reboot'
    $rebootButton = New-Object System.Windows.Forms.Button
    $rebootButton.Text = 'Approve and start Reboot'
    $rebootButton.Dock = [System.Windows.Forms.DockStyle]::Top
    $rebootButton.Height = 34
    $rebootButton.Add_Click({ Start-WizardAction -Action Reboot })
    $rebootHint = New-WizardLabel -Text 'Only VMs with pending reboot evidence are listed. A separate approval is required before a reboot is sent.' -X 12 -Y 48 -Width 1050 -Height 35
    $rebootHint.ForeColor = [System.Drawing.Color]::DimGray
    $rebootGrid = New-WizardGrid -Headers @('VM', 'Expected FQDN', 'Status', 'Evidence') -Widths @(220, 260, 170, 400)
    $rebootTab.Controls.Add($rebootGrid)
    $rebootTab.Controls.Add($rebootHint)
    $rebootTab.Controls.Add($rebootButton)
    [void]$tabs.TabPages.Add($rebootTab)

    $verifyTab = New-Object System.Windows.Forms.TabPage
    $verifyTab.Text = 'Verify'
    $verifyButton = New-Object System.Windows.Forms.Button
    $verifyButton.Text = 'Start Verify (fresh scan)'
    $verifyButton.Dock = [System.Windows.Forms.DockStyle]::Top
    $verifyButton.Height = 34
    $verifyButton.Add_Click({ Start-WizardAction -Action Verify })
    $roundButton = New-Object System.Windows.Forms.Button
    $roundButton.Text = 'Start another round'
    $roundButton.Location = New-Object System.Drawing.Point(12, 45)
    $roundButton.Size = New-Object System.Drawing.Size(155, 30)
    $roundButton.Add_Click({ Start-WizardNewRound })
    $finishButton = New-Object System.Windows.Forms.Button
    $finishButton.Text = 'Finish run'
    $finishButton.Location = New-Object System.Drawing.Point(180, 45)
    $finishButton.Size = New-Object System.Drawing.Size(115, 30)
    $finishButton.Add_Click({ Finish-WizardRun })
    $reviewButton = New-Object System.Windows.Forms.Button
    $reviewButton.Text = 'Mark steps reviewed'
    $reviewButton.Location = New-Object System.Drawing.Point(308, 45)
    $reviewButton.Size = New-Object System.Drawing.Size(150, 30)
    $reviewButton.Add_Click({ Set-WizardStepsReviewed })
    $verifyHint = New-WizardLabel -Text 'Verify is a fresh scan. Start another round only for a new scan and selection; there is no automatic loop. Mark steps reviewed after checking a guest whose install or reboot has no final result.' -X 470 -Y 42 -Width 640 -Height 40
    $verifyHint.ForeColor = [System.Drawing.Color]::DimGray
    $verifyTab.Controls.Add($verifyHint)
    $verifyTab.Controls.Add($reviewButton)
    $verifyTab.Controls.Add($finishButton)
    $verifyTab.Controls.Add($roundButton)
    $verifyTab.Controls.Add($verifyButton)
    [void]$tabs.TabPages.Add($verifyTab)

    $statusPanel = New-Object System.Windows.Forms.Panel
    $statusPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $statusPanel.Height = 118
    $statusPanel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $statusLabel = New-WizardLabel -Text 'Create or resume a run.' -X 0 -Y 0 -Width 700 -Height 22
    $progressLabel = New-WizardLabel -Text 'No active run' -X 705 -Y 0 -Width 350 -Height 22
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(0, 24)
    $progress.Size = New-Object System.Drawing.Size(1060, 18)
    $progress.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
    $statusText = New-Object System.Windows.Forms.TextBox
    $statusText.Location = New-Object System.Drawing.Point(0, 48)
    $statusText.Size = New-Object System.Drawing.Size(1160, 65)
    $statusText.Multiline = $true
    $statusText.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $statusText.ReadOnly = $true
    $statusText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $statusPanel.Controls.AddRange(@($statusLabel, $progressLabel, $progress, $statusText))
    $statusPanel.Add_Resize({
        param($sender, $eventArgs)
        $bar = @($sender.Controls | Where-Object { $_ -is [System.Windows.Forms.ProgressBar] })[0]
        if ($null -ne $bar) { $bar.Width = [Math]::Max(1, $sender.ClientSize.Width - $bar.Left - 8) }
    })
    $form.Controls.Add($statusPanel)
    $form.Controls.SetChildIndex($header, 2)
    $form.Controls.SetChildIndex($statusPanel, 1)
    $form.Controls.SetChildIndex($tabs, 0)

    $script:Wizard.Controls = @{
        VCenter = $vcText
        VmEntries = $vmText
        OutputRoot = $outputText
        ScanConcurrency = $scanConcurrency
        InstallConcurrency = $installConcurrency
        RebootBatch = $rebootBatch
        ScanLimit = $scanLimit
        InstallLimit = $installLimit
        RebootLimit = $rebootLimit
        IgnoreVCenter = $ignoreVc
        IgnoreEsxi = $ignoreEsxi
        AdvancedToggle = $advancedToggle
        AdvancedPanel = $advancedPanel
        OpenLogs = $openLogs
        RunPathLabel = $runPathLabel
        ResumeButton = $resume
        VmGrid = $vmGrid
        SelectGrid = $selectGrid
        RebootGrid = $rebootGrid
        RebootButton = $rebootButton
        ScanButton = $scanButton
        SaveSelectionButton = $saveSelection
        InstallButton = $installButton
        VerifyButton = $verifyButton
        StartRoundButton = $roundButton
        FinishButton = $finishButton
        StatusLabel = $statusLabel
        ProgressLabel = $progressLabel
        ProgressBar = $progress
        StatusText = $statusText
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({ Refresh-WizardUi })
    $script:Wizard.Timer = $timer
    $timer.Start()
    $form.Add_FormClosing({
        if ($null -ne $script:Wizard.ActivePowerShell) {
            $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, 'An action is still running. Closing stops monitoring on this workstation; agents already started in the guests keep running. Use Resume run later to continue. Close now?', 'Close Patch Wizard', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $_.Cancel = $true; return }
            try { $script:Wizard.ActivePowerShell.Dispose() } catch { }
            $script:Wizard.ActivePowerShell = $null
        }
        if ($null -ne $script:Wizard.Timer) { $script:Wizard.Timer.Stop() }
    })

    Set-WizardStatus -Message 'Create or resume a run. Credentials are requested only into memory.'
    return $form
}

if (-not $NoUi) {
    try {
        $form = Initialize-WizardUi
        if ($SmokeUi) {
            $form.Dispose()
            return
        }
        [void]$form.ShowDialog()
        $form.Dispose()
    }
    catch {
        Write-Error $_.Exception.Message
    }
}
