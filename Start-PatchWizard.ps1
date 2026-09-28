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
    VCenterCredentials = @{}
    GuestCredentials = @{}
    PendingAction = $null
    ObserveOnly = $false
    RetryVms = @()
    ActivePowerShell = $null
    ActiveAsyncResult = $null
    ActiveAction = $null
    LastRunLog = ''
    LastRunReadError = ''
    UpdatingGrid = $false
    UpdateRows = @()
    Controls = @{}
    BaseClientSize = $null
    BaseFont = $null
    BaseLayout = @{}
    Stretch = @{}
    OutlineSizing = $null
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
    Update-WizardStatusLayout
}

function Update-WizardStatusLayout {
    # The status area under the VM table: the message wraps and its box grows to fit it (at least two lines,
    # text centered vertically); the progress text is right-aligned beside it; the progress bar and the log
    # follow below. Runs after every message, progress change and window resize (after the zoom layout).
    $controls = $script:Wizard.Controls
    if ($null -eq $controls.StatusLabel -or $null -eq $controls.StatusLabel.Parent) { return }
    $panel = $controls.StatusLabel.Parent
    $width = $panel.ClientSize.Width - $panel.Padding.Right
    $lineHeight = $controls.StatusLabel.Font.Height
    $progressWidth = [System.Windows.Forms.TextRenderer]::MeasureText($controls.ProgressLabel.Text, $controls.ProgressLabel.Font).Width + 8
    $messageWidth = [Math]::Max(50, $width - $progressWidth - 10)
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $messageHeight = [System.Windows.Forms.TextRenderer]::MeasureText($controls.StatusLabel.Text, $controls.StatusLabel.Font, (New-Object System.Drawing.Size($messageWidth, 0)), $flags).Height
    $boxHeight = [Math]::Max(2 * $lineHeight, $messageHeight) + [int]($lineHeight / 2)
    $controls.StatusLabel.SetBounds(0, 0, $messageWidth, $boxHeight)
    $controls.ProgressLabel.SetBounds($width - $progressWidth, 0, $progressWidth, $boxHeight)
    $controls.ProgressBar.SetBounds(0, $boxHeight + 2, $width, $controls.ProgressBar.Height)
    $controls.StatusText.SetBounds(0, $controls.ProgressBar.Bottom + 6, $width, $controls.StatusText.Height)
    $panel.Height = $controls.StatusText.Bottom + 5
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
    # One VM per line: "VM name", "FQDN" or "VM name|FQDN". The FQDN is optional; when given it is checked.
    param([Parameter(Mandatory = $true)][string]$Text)

    $entries = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Split('|')
        $entries += [pscustomobject]@{
            VmName = $parts[0].Trim()
            ExpectedFqdn = $(if ($parts.Count -gt 1) { $parts[1].Trim().TrimEnd('.') } else { '' })
        }
    }
    if ($entries.Count -eq 0) { throw 'Enter at least one VM.' }
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

    $savedCount = 0
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $vmName = [string](Get-PatchValue $vm @('vmName') '')
        $rows = @($script:Wizard.UpdateRows | Where-Object { $_.VmName -eq $vmName })
        $selected = @()
        $deselected = @()
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
                Set-PatchValue -InputObject $record -Name 'selected' -Value $true
            }
            else {
                if ($null -ne $key) { $deselected += $key }
                Set-PatchValue -InputObject $record -Name 'selected' -Value $false
            }
        }
        Set-PatchValue -InputObject $vm -Name 'selectedUpdates' -Value @($selected)
        $savedCount += $selected.Count
        # Only what the operator unchecked is remembered: every other offered update, also one offered by a
        # later scan, stays preselected (plan).
        Set-PatchValue -InputObject $vm -Name 'deselectedUpdates' -Value @($deselected)
    }

    Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
    Set-WizardStatus -Message ('Saved {0} exact update selections.' -f $savedCount)
    Refresh-WizardSelectionGrid
}

function Set-WizardSettingsFromRun {
    param([Parameter(Mandatory = $true)]$RunState)

    $controls = $script:Wizard.Controls
    $options = $RunState.options
    $controls.VCenter.Text = (@($RunState.vCenters) -join ', ')
    # runPath is <output root>\<runId>\run.json
    $controls.OutputRoot.Text = Split-Path -Parent (Split-Path -Parent ([string]$RunState.runPath))
    $controls.ScanConcurrency.Text = [string]$options.scanConcurrency
    $controls.InstallConcurrency.Text = [string]$options.installConcurrency
    $controls.RebootBatch.Text = [string]$options.rebootBatchSize
    $controls.ScanLimit.Text = [string]$options.limits.scanTimeoutMinutes
    $controls.InstallLimit.Text = [string]$options.limits.installTimeoutMinutes
    $controls.RebootLimit.Text = [string]$options.limits.rebootConfirmationTimeoutMinutes
    $controls.IgnoreVCenter.Checked = [bool]$options.ignoreVCenterCertificate
    $controls.IgnoreEsxi.Checked = [bool]$options.ignoreEsxiCertificatesForFileTransfers
    $controls.VmEntries.Text = (@(Get-PatchArray $RunState.vms | ForEach-Object { '{0}|{1}' -f $_.vmName, $_.expectedFqdn }) -join [Environment]::NewLine)
}

function New-WizardRun {
    try {
        if ($null -ne $script:Wizard.ActivePowerShell) { throw 'An action is already running.' }
        $config = Get-WizardConfigFromControls
        $entries = ConvertTo-WizardVmEntries -Text $script:Wizard.Controls.VmEntries.Text
        $script:Wizard.RunState = New-PatchRun -Config $config -VMEntries $entries
        $script:Wizard.RunPath = [string](Get-PatchValue $script:Wizard.RunState @('runPath') '')
        $script:Wizard.VCenterCredentials = @{}
        $script:Wizard.GuestCredentials = @{}
        $script:Wizard.UpdateRows = @()
        $script:Wizard.Controls.OpenLogs.Enabled = $true
        $script:Wizard.Controls.RunPathLabel.Text = ('Run: {0}{1}The run keeps the settings it was created with; edited fields apply only to a New patch run.' -f $script:Wizard.RunPath, [Environment]::NewLine)
        Set-WizardStatus -Message ('Run {0} has been created. Go to the Scan tab and start the scan.' -f [string](Get-PatchValue $script:Wizard.RunState @('runId') ''))
        Refresh-WizardVmGrid
        Refresh-WizardSelectionGrid
        Update-WizardStepState
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Request-WizardCredential {
    # '*' is the credential for every vCenter; a vCenter that rejects it gets its own (see Complete-WizardAction).
    param([string]$VCenter = '*')

    $message = if ($VCenter -eq '*') { 'Enter the vCenter credential for this run (used for every vCenter).' } else { 'vCenter {0} rejected the shared credential. Enter the credential for {0}.' -f $VCenter }
    $credential = Get-Credential -Message $message
    if ($null -eq $credential) { return }
    $script:Wizard.VCenterCredentials[$VCenter] = $credential
    Set-WizardStatus -Message ('vCenter credential for {0} held in memory.' -f $VCenter)
}

function Request-WizardGuestCredentials {
    # Asks once per credential group that has no credential yet: one prompt per domain (DNS suffix),
    # one per VM without a suffix (e.g. DMZ servers with a local administrator). Memory only.
    $vms = @(Get-PatchArray $script:Wizard.RunState.vms | Where-Object { $_.status -ne 'SkippedGuestAccount' -and -not [string]::IsNullOrWhiteSpace([string]$_.accountGroup) })
    foreach ($group in @($vms | ForEach-Object { [string]$_.accountGroup } | Sort-Object -Unique)) {
        if ($script:Wizard.GuestCredentials.ContainsKey($group)) { continue }
        $names = @($vms | Where-Object { $_.accountGroup -eq $group } | ForEach-Object { $_.vmName }) -join ', '
        $message = if ($group.StartsWith('vm:')) { 'Local administrator credential for VM {0}.' -f $names } else { 'Guest credential for domain {0} (VMs: {1}).' -f $group, $names }
        $credential = Get-Credential -Message $message
        if ($null -eq $credential) { return $false }
        $script:Wizard.GuestCredentials[$group] = $credential
        Set-WizardStatus -Message ('Guest credential for {0} held in memory.' -f $group)
    }
    return $true
}

function Resume-WizardRun {
    if ($null -ne $script:Wizard.ActivePowerShell) {
        Show-WizardError -Message 'An action is already running.'
        return
    }

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Patch run (run.json)|run.json'
    $dialog.Title = 'Resume patch run'
    if ($dialog.ShowDialog($script:Wizard.Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }

    try {
        $state = Read-PatchRun -RunPath $dialog.FileName
        Write-PatchSummary -RunPath $dialog.FileName -RunState $state
        $script:Wizard.RunState = $state
        $script:Wizard.RunPath = $dialog.FileName
        # Credentials are never saved; they are asked for again when the next action starts.
        $script:Wizard.VCenterCredentials = @{}
        $script:Wizard.GuestCredentials = @{}
        $script:Wizard.UpdateRows = @()
        Set-WizardSettingsFromRun -RunState $state
        $script:Wizard.Controls.OpenLogs.Enabled = $true
        $script:Wizard.Controls.RunPathLabel.Text = ('Run: {0}{1}The run keeps the settings it was created with; edited fields apply only to a New patch run.' -f $script:Wizard.RunPath, [Environment]::NewLine)
        Refresh-WizardVmGrid
        Refresh-WizardSelectionGrid
        Update-WizardStepState
        Set-WizardStatus -Message 'Run loaded.'

        # An interrupted action continues by observing the steps it already started (plan: Resume run).
        $currentAction = [string](Get-PatchValue $state @('currentAction') '')
        if ([string]$state.status -eq 'Running' -and $currentAction -in @('Scan', 'Install', 'Reboot', 'Verify')) {
            Set-WizardStatus -Message ('{0} was interrupted; its started installs and reboots are observed again; nothing new is installed or rebooted without a new approval (a scan simply runs again).' -f $currentAction)
            Start-WizardAction -Action $currentAction -ApprovalAlreadyGiven -ObserveOnly
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
    # A choice made in the grid but not saved yet survives the refresh after an action.
    $shown = @{}
    foreach ($row in @($script:Wizard.UpdateRows)) { $shown[$row.VmName + '|' + $row.Key] = [bool]$row.Selected }
    foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
        $vmName = [string](Get-PatchValue $vm @('vmName') '')
        $updates = @(Get-PatchArray (Get-PatchValue $vm @('availableUpdates') @()))
        $deselected = @(Get-PatchArray (Get-PatchValue $vm @('deselectedUpdates') @()))
        foreach ($update in $updates) {
            $key = Get-WizardSelectedUpdateKey -Update $update
            if ($null -eq $key) { continue }
            $selected = if ($shown.ContainsKey($vmName + '|' + $key)) { $shown[$vmName + '|' + $key] } else { $key -notin $deselected }
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
                [void]$grid.Rows.Add('', '', '', '', '', '', '', '', '')
            }
        }
        for ($i = 0; $i -lt $vms.Count; $i++) {
            $vm = $vms[$i]
            $updates = @(Get-PatchArray (Get-PatchValue $vm @('availableUpdates') @()))
            $reboot = Get-PatchValue $vm @('reboot') $null
            $grid.Rows[$i].Cells[0].Value = [string](Get-PatchValue $vm @('vmName') '')
            $grid.Rows[$i].Cells[1].Value = [string](Get-PatchValue $vm @('expectedFqdn') '')
            $grid.Rows[$i].Cells[2].Value = [string](Get-PatchValue $vm @('status') 'Pending')
            $grid.Rows[$i].Cells[3].Value = [string](Get-PatchValue $vm @('currentAction') '')
            $grid.Rows[$i].Cells[4].Value = [string]$updates.Count
            $grid.Rows[$i].Cells[5].Value = [string](Get-PatchValue $reboot @('status') 'NotRequested')
            # Cluster membership from the last agent status; empty until the VM is scanned.
            $grid.Rows[$i].Cells[6].Value = $(if ($null -eq (Get-PatchValue $vm @('agentStatus') $null)) { '' } else { Get-PatchClusterMembership -VMRecord $vm })
            $errors = @(Get-PatchArray (Get-PatchValue $vm @('errors') @()))
            $grid.Rows[$i].Cells[7].Value = [string]$errors.Count
            $grid.Rows[$i].Cells[8].Value = [string](Get-PatchValue $vm @('accountGroup') '')
        }
    }
    finally {
        $script:Wizard.UpdatingGrid = $false
    }
}

function Get-WizardPendingRebootVms {
    # Only VMs the controller will reboot: not cluster members (or unknown), not skipped accounts, and not
    # blocked by an install without a final result. A reboot that is not confirmed yet is listed (observed again).
    return @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()) | Where-Object {
            $blocker = Get-PatchMutatingStepBlocker -RunState $script:Wizard.RunState -VMRecord $_ -CurrentStep $null
            (Test-PatchVmRequiresReboot -VMRecord $_) -and (Get-PatchClusterMembership -VMRecord $_) -eq 'NotMember' -and
            $_.status -ne 'SkippedGuestAccount' -and ($null -eq $blocker -or [string]$blocker.action -eq 'Reboot')
        })
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
    # Mark steps reviewed and New patch run write run.json, which only the running action may change.
    $script:Wizard.Controls.ReviewButton.Enabled = (-not $active)
    $script:Wizard.Controls.NewRunButton.Enabled = (-not $active)
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
    Update-WizardStatusLayout
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
    $allVms = @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))
    $affected = @($allVms | Where-Object { [string](Get-PatchValue $_ @('status') '') -eq 'GuestCredentialRejected' })
    if ($affected.Count -eq 0) { return 'None' }

    $names = @($affected | ForEach-Object { [string](Get-PatchValue $_ @('vmName') '') })
    $choice = Show-WizardCredentialDecision -VmNames $names
    if ($choice -eq 'Retry') {
        # Rejected on some VMs of a domain only (e.g. DMZ servers sharing the DNS suffix): those VMs
        # get their own credential. Rejected on every VM of the domain: the domain password is asked again.
        # Only a result of this step that needed a guest login shows that the credential worked (lastResult: a skip
        # keeps the VM's displayed status, so an older Completed would mislead).
        $loggedIn = @('Completed', 'CompletedWithErrors', 'Confirmed')
        $partlyRejected = @($affected | ForEach-Object { [string]$_.accountGroup } | Sort-Object -Unique | Where-Object {
                $group = $_
                -not $group.StartsWith('vm:') -and @($allVms | Where-Object { $_.accountGroup -eq $group -and [string](Get-PatchValue $_ @('lastResult') '') -in $loggedIn }).Count -gt 0
            })
        foreach ($vm in $affected) {
            $group = [string]$vm.accountGroup
            if ($group -in $partlyRejected) {
                $group = 'vm:' + $vm.vmName
                Set-PatchValue -InputObject $vm -Name 'accountGroup' -Value $group
            }
            $script:Wizard.GuestCredentials.Remove($group)
            Set-PatchValue -InputObject $vm -Name 'status' -Value 'Pending'
        }
        if (-not (Request-WizardGuestCredentials)) {
            Set-WizardStatus -Message 'Retry cancelled because a replacement guest credential was not entered.'
            Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
            return 'Cancel'
        }
        Write-PatchRun -RunPath $script:Wizard.RunPath -RunState $script:Wizard.RunState | Out-Null
        return 'Retry'
    }
    if ($choice -eq 'Skip') {
        foreach ($vm in $affected) { Set-PatchValue -InputObject $vm -Name 'status' -Value 'SkippedGuestAccount' }
        $message = 'Operator skipped the VMs whose guest credential was rejected, for the rest of this run.'
    }
    else {
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
        [switch]$ApprovalAlreadyGiven,
        [switch]$VmsResolved,
        # Resume run: only observe installs and reboots started before the interruption.
        [switch]$ObserveOnly
    )

    if ($ObserveOnly) { $script:Wizard.ObserveOnly = $true }
    elseif (-not $ApprovalAlreadyGiven) { $script:Wizard.ObserveOnly = $false; $script:Wizard.RetryVms = @() }
    try {
        if ($null -ne $script:Wizard.ActivePowerShell) { throw 'An action is already running.' }
        if ($null -eq $script:Wizard.RunState -or [string]::IsNullOrWhiteSpace([string]$script:Wizard.RunPath)) { throw 'Create or resume a run first.' }
        if (-not $script:Wizard.VCenterCredentials.ContainsKey('*')) { Request-WizardCredential }
        if (-not $script:Wizard.VCenterCredentials.ContainsKey('*')) { throw 'The vCenter credential is required.' }
        $credentialDecision = Resolve-WizardCredentialRejection -Action $Action
        if ($credentialDecision -in @('Skip', 'Stop', 'Cancel')) { return }
        if ($Action -eq 'Install' -and -not $ApprovalAlreadyGiven) {
            Save-WizardSelections
            # The approval lists exactly the VMs the controller will install on (see its skip rules).
            $plan = @(Get-PatchArray $script:Wizard.RunState.vms | Where-Object {
                    $_.status -ne 'SkippedGuestAccount' -and @(Get-PatchArray $_.selectedUpdates).Count -gt 0 -and
                    (Get-PatchClusterMembership -VMRecord $_) -eq 'NotMember' -and -not (Test-PatchInstallDone -VMRecord $_) -and
                    ((Test-PatchStepStarted -VMRecord $_ -Action 'Install') -or
                     $null -eq (Get-PatchMutatingStepBlocker -RunState $script:Wizard.RunState -VMRecord $_ -CurrentStep $null))
                })
            if ($plan.Count -eq 0) { throw 'No VM will install in this round: select updates on scanned VMs. Cluster members, skipped accounts, VMs already installed in this round and VMs with an unreviewed install or reboot are left out.' }
            # A started install without a final result (e.g. lost contact) is only observed again, never started twice.
            $lines = @($plan | ForEach-Object {
                    if (Test-PatchStepStarted -VMRecord $_ -Action 'Install') { '{0}: observe the install already started (it is not started again)' -f $_.vmName }
                    else { '{0}: {1} update(s)' -f $_.vmName, @(Get-PatchArray $_.selectedUpdates).Count }
                })
            $installPrompt = 'Install the selected updates on these VMs? The agent searches again and installs only matching UpdateID and RevisionNumber values; it does not reboot.{0}{0}{1}' -f [Environment]::NewLine, ($lines -join [Environment]::NewLine)
            $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, $installPrompt, 'Approve installation', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        if ($Action -eq 'Reboot' -and -not $ApprovalAlreadyGiven) {
            Refresh-WizardRebootGrid
            $pending = @(Get-WizardPendingRebootVms)
            if ($pending.Count -eq 0) { throw 'No VM currently has a pending reboot.' }
            # A reboot already sent and not confirmed yet is only observed again, never sent twice.
            $lines = @($pending | ForEach-Object {
                    if (Test-PatchStepStarted -VMRecord $_ -Action 'Reboot') { '{0}: observe the reboot already sent (it is not sent again)' -f $_.vmName }
                    else { '{0}: reboot now' -f $_.vmName }
                })
            $answer = [System.Windows.Forms.MessageBox]::Show($script:Wizard.Form, ('Approve the reboot step for these VMs? The next batch starts only after the previous one reports a newer boot time.{0}{0}{1}' -f [Environment]::NewLine, ($lines -join [Environment]::NewLine)), 'Approve reboot', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        # VMs not yet found in vCenter are resolved first (vCenter credential only), so the guest
        # credentials can be asked per domain or per VM. The action continues when that finishes.
        $unresolved = @(Get-PatchArray $script:Wizard.RunState.vms | Where-Object { $_.status -ne 'SkippedGuestAccount' -and [string]::IsNullOrWhiteSpace([string]$_.accountGroup) })
        if ($unresolved.Count -gt 0 -and -not $VmsResolved) {
            $script:Wizard.PendingAction = $Action
            Start-WizardWorker -Action 'Resolve'
            return
        }
        if (-not (Request-WizardGuestCredentials)) {
            Set-WizardStatus -Message ('{0} cancelled: a guest credential was not entered.' -f $Action)
            return
        }
        Start-WizardWorker -Action $Action
    }
    catch {
        Show-WizardError -Message $_.Exception.Message
    }
}

function Start-WizardWorker {
    # Runs one controller call in a background runspace so the window stays responsive.
    param([Parameter(Mandatory = $true)][string]$Action)

    $workerScript = {
        param($ControllerPath, $ActionName, $RunFilePath, $VCenterCredentials, $GuestCredentials, $ObserveOnly, $VmNames)
        try {
            . $ControllerPath
            if ($ActionName -eq 'Resolve') { return (Resolve-PatchVms -RunPath $RunFilePath -VCenterCredentials $VCenterCredentials) }
            return (Invoke-PatchAction -Action $ActionName -RunPath $RunFilePath -VCenterCredentials $VCenterCredentials -GuestCredentials $GuestCredentials -ObserveOnly:$ObserveOnly -VmNames $VmNames)
        }
        catch {
            return [pscustomobject]@{ status = 'Stopped'; action = $ActionName; error = $_.Exception.Message }
        }
    }
    $powerShell = [PowerShell]::Create()
    [void]$powerShell.AddScript($workerScript.ToString())
    [void]$powerShell.AddArgument($script:ControllerPath)
    [void]$powerShell.AddArgument($Action)
    [void]$powerShell.AddArgument([string]$script:Wizard.RunPath)
    [void]$powerShell.AddArgument($script:Wizard.VCenterCredentials)
    [void]$powerShell.AddArgument($script:Wizard.GuestCredentials)
    [void]$powerShell.AddArgument([bool]$script:Wizard.ObserveOnly)
    [void]$powerShell.AddArgument([string[]]@($script:Wizard.RetryVms))
    $script:Wizard.ActivePowerShell = $powerShell
    $script:Wizard.ActiveAsyncResult = $powerShell.BeginInvoke()
    $script:Wizard.ActiveAction = $Action
    Set-WizardStatus -Message ('{0} is running in the background. The window remains responsive.' -f $Action)
    Update-WizardStepState
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
    $result = @($output)[-1]

    try {
        $script:Wizard.RunState = Read-PatchRun -RunPath $script:Wizard.RunPath
    }
    catch {
        Set-WizardStatus -Message ('Action finished, but run state could not be read: {0}' -f $_.Exception.Message)
    }

    # A vCenter rejected the shared credential: ask for its own credential and run the same step again.
    $rejectedVCenters = @(Get-PatchValue $result @('rejectedVCenters') @())
    if ($rejectedVCenters.Count -gt 0) {
        foreach ($name in $rejectedVCenters) {
            $script:Wizard.VCenterCredentials.Remove($name)
            Request-WizardCredential -VCenter $name
            if (-not $script:Wizard.VCenterCredentials.ContainsKey($name)) {
                $script:Wizard.PendingAction = $null
                Show-WizardError -Message ('Stopped: no credential was entered for vCenter {0}.' -f $name)
                Update-WizardStepState
                return
            }
        }
        if ($action -eq 'Resolve') { Start-WizardWorker -Action 'Resolve' }
        else { Start-WizardAction -Action $action -ApprovalAlreadyGiven -VmsResolved }
        return
    }

    if ($action -eq 'Resolve') {
        Refresh-WizardVmGrid
        Refresh-WizardRunLog
        $pendingAction = $script:Wizard.PendingAction
        $script:Wizard.PendingAction = $null
        if ([string]$result.status -ne 'Completed') {
            Show-WizardError -Message ('VMs could not be looked up in vCenter: {0}' -f $result.error)
            Update-WizardStepState
            return
        }
        Start-WizardAction -Action $pendingAction -ApprovalAlreadyGiven -VmsResolved
        return
    }

    $resultSummary = $null
    if ($null -ne $result) {
        $resultStatus = [string](Get-PatchValue $result @('status') 'Unknown')
        $rejectedNames = @(Get-PatchArray $script:Wizard.RunState.vms | Where-Object { $_.status -eq 'GuestCredentialRejected' } | ForEach-Object { [string]$_.vmName })
        $credentialDecision = Resolve-WizardCredentialRejection -Action $action
        if ($credentialDecision -eq 'Retry') {
            # The same step again, only for the VMs whose credential was rejected; the others keep their results.
            $script:Wizard.RetryVms = $rejectedNames
            Start-WizardAction -Action $action -ApprovalAlreadyGiven
            return
        }
        if ($credentialDecision -eq 'None') {
            # Per-status counts; VMs that did not complete are named so the operator sees what failed.
            $groups = @(@(Get-PatchArray (Get-PatchValue $result @('vmResults') @())) | Group-Object -Property status | ForEach-Object {
                if ($_.Name -in @('Completed', 'Confirmed')) { '{0} {1}' -f $_.Name, $_.Count }
                else { '{0} {1} ({2})' -f $_.Name, $_.Count, (@($_.Group | ForEach-Object { $_.vmName }) -join ', ') }
            })
            $resultSummary = '{0} finished: {1}.' -f $action, $(if ($groups.Count -gt 0) { $groups -join '; ' } else { $resultStatus })
            if ($resultStatus -ne 'Completed') { $resultSummary += ' Details for each VM are in errors.log.' }
            if (@(Get-PatchArray (Get-PatchValue $result @('vmResults') @()) | Where-Object { $_.status -eq 'SkippedInstalledThisRound' }).Count -gt 0) { $resultSummary += ' Install runs once per round: for updates found later, use Start another round on the Verify tab.' }
            if ($script:Wizard.ObserveOnly -and $action -in @('Install', 'Reboot')) { $resultSummary += (' VMs not started before the interruption (SkippedNotStarted) need a new {0} approval.' -f $action) }
        }
    }
    $script:Wizard.ObserveOnly = $false
    $script:Wizard.RetryVms = @()

    Refresh-WizardVmGrid
    Refresh-WizardSelectionGrid
    Refresh-WizardRebootGrid
    Refresh-WizardRunLog
    Update-WizardProgress
    Update-WizardStepState
    if ($credentialDecision -in @('Skip', 'Stop', 'Cancel')) { return }
    if ($null -eq $resultSummary) { $resultSummary = '{0} finished.' -f $action }
    # Written after Refresh-WizardRunLog, which replaces the log box with run.log.
    switch ($action) {
        'Scan' { $script:Wizard.Tabs.SelectedIndex = 2; Set-WizardStatus -Message ($resultSummary + ' Review and save the offered update selections.') }
        'Install' { $script:Wizard.Tabs.SelectedIndex = 4; Set-WizardStatus -Message ($resultSummary + ' Only VMs with fresh pending reboot evidence are shown.') }
        'Reboot' { $script:Wizard.Tabs.SelectedIndex = 5; Set-WizardStatus -Message ($resultSummary + ' Run Verify for a fresh result.') }
        'Verify' { $script:Wizard.Tabs.SelectedIndex = 5; Set-WizardStatus -Message ($resultSummary + ' Start another round explicitly or finish the run.') }
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
        Set-PatchValue -InputObject $script:Wizard.RunState -Name 'currentAction' -Value $null
        foreach ($vm in @(Get-PatchArray (Get-PatchValue $script:Wizard.RunState @('vms') @()))) {
            Set-PatchValue -InputObject $vm -Name 'currentRound' -Value $round
            Set-PatchValue -InputObject $vm -Name 'availableUpdates' -Value @()
            Set-PatchValue -InputObject $vm -Name 'selectedUpdates' -Value @()
            Set-PatchValue -InputObject $vm -Name 'deselectedUpdates' -Value @()
            # pendingUpdates stays until the next scan, so finishing right after a new round still lists what is left.
            Set-PatchValue -InputObject $vm -Name 'reboot' -Value ([pscustomobject]@{ status = 'NotRequested'; required = $false; confirmedBootTime = $null })
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
            if ($null -ne $step) { $blocked += [pscustomobject]@{ VmName = [string](Get-PatchValue $vm @('vmName') ''); Step = $step; Vm = $vm } }
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
            if ([string]$item.Step.action -eq 'Reboot') {
                # A reviewed reboot is not offered again until a new scan reports a pending reboot.
                Set-PatchValue -InputObject $item.Vm.reboot -Name 'status' -Value 'Reviewed'
                Set-PatchValue -InputObject $item.Vm.reboot -Name 'required' -Value $false
            }
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

function Set-WizardGridScaling {
    # Columns share the grid width in fixed proportions; row and header heights follow the font.
    param([System.Windows.Forms.DataGridView]$Grid)
    $Grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $Grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::DisplayedCells
    $Grid.ColumnHeadersHeightSizeMode = [System.Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    # Header text stays on one line (see Set-WizardGridMinimumWidths for the scroll bar).
    $Grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
}

function Save-WizardLayout {
    # Remembers every control's bounds at the first shown size: the 100 % reference for zooming.
    param([System.Windows.Forms.Control]$Parent)
    foreach ($control in $Parent.Controls) {
        $script:Wizard.BaseLayout[$control] = @{ Bounds = $control.Bounds; ParentSize = $Parent.ClientSize }
        if ($control -is [System.Windows.Forms.Panel] -or $control -is [System.Windows.Forms.TabControl]) { Save-WizardLayout -Parent $control }
    }
}

function Set-WizardScaledBounds {
    # Reference bounds x factor; fields marked in Wizard.Stretch also take up the space left over
    # when the window is wider (or taller) than the zoom factor needs.
    param([System.Windows.Forms.Control]$Parent, [double]$Factor)
    if ($Parent -is [System.Windows.Forms.ScrollableControl] -and $Parent.AutoScroll) { $Parent.AutoScrollPosition = New-Object System.Drawing.Point(0, 0) }
    foreach ($control in $Parent.Controls) {
        $base = $script:Wizard.BaseLayout[$control]
        if ($null -eq $base -or $control -is [System.Windows.Forms.TabPage] -or $control.Dock -eq [System.Windows.Forms.DockStyle]::Fill) { continue }
        $x = $base.Bounds.X * $Factor; $y = $base.Bounds.Y * $Factor
        $width = $base.Bounds.Width * $Factor; $height = $base.Bounds.Height * $Factor
        $extraWidth = [Math]::Max(0, $Parent.ClientSize.Width - $base.ParentSize.Width * $Factor)
        $extraHeight = [Math]::Max(0, $Parent.ClientSize.Height - $base.ParentSize.Height * $Factor)
        switch ([string]$script:Wizard.Stretch[$control]) {
            'Width' { $width += $extraWidth }
            'Right' { $x += $extraWidth }
            'Both' { $width += $extraWidth; $height += $extraHeight }
        }
        $control.SetBounds([int]$x, [int]$y, [int]$width, [int]$height)
    }
    # Let docked siblings take their new size before their children are placed.
    $Parent.PerformLayout()
    foreach ($control in $Parent.Controls) {
        if ($control -is [System.Windows.Forms.Panel] -or $control -is [System.Windows.Forms.TabControl]) { Set-WizardScaledBounds -Parent $control -Factor $Factor }
    }
}

function Set-WizardGridMinimumWidths {
    # A column is never narrower than its header text at the current font; when the columns do not
    # fit, the grid shows a horizontal scroll bar instead of squeezing them.
    foreach ($grid in @($script:Wizard.Controls.VmGrid, $script:Wizard.Controls.SelectGrid, $script:Wizard.Controls.RebootGrid)) {
        foreach ($column in $grid.Columns) {
            $column.MinimumWidth = [System.Windows.Forms.TextRenderer]::MeasureText($column.HeaderText, $grid.Font).Width + 16
        }
    }
}

function Update-WizardScale {
    # Zooms the window content (positions, sizes, fonts, tabs) with the window by the smaller of the
    # width and height ratios to the first shown size. Always computed from that reference, so
    # repeated resizing does not drift.
    $form = $script:Wizard.Form
    if ($script:Wizard.BaseLayout.Count -eq 0 -or $form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return }
    $factor = [Math]::Min($form.ClientSize.Width / $script:Wizard.BaseClientSize.Width, $form.ClientSize.Height / $script:Wizard.BaseClientSize.Height)
    # Fonts are recreated only when the size changes by a visible step (0.25 pt).
    $fontSize = [float]([Math]::Round($script:Wizard.BaseFont.Size * $factor * 4) / 4)
    if ($fontSize -ne $form.Font.Size) {
        $form.Font = New-Object System.Drawing.Font($script:Wizard.BaseFont.FontFamily, $fontSize)
        $script:Wizard.Controls.Title.Font = New-Object System.Drawing.Font('Segoe UI', [float]([Math]::Round(14 * $factor * 4) / 4), [System.Drawing.FontStyle]::Bold)
    }
    Set-WizardScaledBounds -Parent $form -Factor $factor
    Set-WizardGridMinimumWidths
    Update-WizardStatusLayout
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
    Set-WizardGridScaling -Grid $grid
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText = $Headers[$i]
        $column.Name = ('Column{0}' -f $i)
        $column.FillWeight = $Widths[$i]
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
    # Resizing the window shows only its outline, so the content is zoomed once, when the mouse button is
    # released. Windows has no per-window option for this: the system setting "show window contents while
    # dragging" is turned off for the duration of the resize loop only (not saved) and then restored.
    if (-not ('PatchWizardOutlineSizing' -as [type])) {
        # The class has no public members besides the constructor, which Add-Type reports as a warning.
        Add-Type -ReferencedAssemblies System.Windows.Forms -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class PatchWizardOutlineSizing : NativeWindow {
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(int action, int uiParam, ref int pvParam, int winIni);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(int action, int uiParam, IntPtr pvParam, int winIni);
    const int WM_SYSCOMMAND = 0x0112, SC_SIZE = 0xF000, SPI_SETDRAGFULLWINDOWS = 0x0025, SPI_GETDRAGFULLWINDOWS = 0x0026;
    public PatchWizardOutlineSizing(Form form) { AssignHandle(form.Handle); }
    protected override void WndProc(ref Message m) {
        if (m.Msg != WM_SYSCOMMAND || ((int)m.WParam & 0xFFF0) != SC_SIZE) { base.WndProc(ref m); return; }
        int dragFull = 0;
        SystemParametersInfo(SPI_GETDRAGFULLWINDOWS, 0, ref dragFull, 0);
        SystemParametersInfo(SPI_SETDRAGFULLWINDOWS, 0, IntPtr.Zero, 0);
        try { base.WndProc(ref m); }
        finally { SystemParametersInfo(SPI_SETDRAGFULLWINDOWS, dragFull, IntPtr.Zero, 0); }
    }
}
'@
    }
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Windows Patch Wizard'
    $form.StartPosition = 'CenterScreen'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.MinimumSize = New-Object System.Drawing.Size(800, 540)
    $form.Size = New-Object System.Drawing.Size(1250, 900)
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
    $settingsPanel.AutoScroll = $true
    $settingsTab.Controls.Add($settingsPanel)
    [void]$tabs.TabPages.Add($settingsTab)

    $vcLabel = New-WizardLabel -Text 'vCenter server(s)' -X 10 -Y 12
    $vcText = New-WizardTextBox -X 155 -Y 9 -Width 360

    $vmLabel = New-WizardLabel -Text 'VM entries' -X 10 -Y 48
    $vmHint = New-WizardLabel -Text 'One per line: VM name, FQDN, or VM name|FQDN. Guest credentials are asked per domain.' -X 155 -Y 48 -Width 710 -Height 22
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

    # Hover help for the concurrency and limit fields (shown on both the label and the text box).
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 15000
    $hints = @(
        @($vcLabel, $vcText, 'One or more vCenters, separated by commas. Each VM is looked up on all of them; a name found on more than one is blocked.'),
        @($concurrencyLabel, $scanConcurrency, 'How many VMs are scanned at the same time (Scan and Verify). Default: 3.'),
        @($installConcurrencyLabel, $installConcurrency, 'How many VMs install updates at the same time. Default: 3.'),
        @($rebootBatchLabel, $rebootBatch, 'How many VMs are restarted together. The next batch starts only after every VM in this batch reports a newer boot time. Default: 1.'),
        @($scanLimitLabel, $scanLimit, 'Maximum minutes to wait for one VM scan. After that the VM is marked NeedsReview. Default: 30.'),
        @($installLimitLabel, $installLimit, 'Maximum minutes to wait for installation on one VM. After that the VM is marked NeedsReview and later install batches wait, since it may still be running; the installation is never started again automatically. Default: 180.'),
        @($rebootLimitLabel, $rebootLimit, 'Maximum minutes to wait for a newer boot time and running VMware Tools after a reboot. Without confirmation, later reboot batches are stopped. Default: 30.')
    )
    foreach ($hint in $hints) {
        $toolTip.SetToolTip($hint[0], $hint[2])
        $toolTip.SetToolTip($hint[1], $hint[2])
    }

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
    $runPathLabel = New-WizardLabel -Text 'No active run' -X 310 -Y 505 -Width 690 -Height 44
    $runPathLabel.ForeColor = [System.Drawing.Color]::DimGray
    $settingsPanel.Controls.AddRange(@($vcLabel, $vcText, $vmLabel, $vmHint, $vmText, $loadFile, $outputLabel, $outputText, $browseOutput, $concurrencyLabel, $scanConcurrency, $installConcurrencyLabel, $installConcurrency, $rebootBatchLabel, $rebootBatch, $advancedToggle, $advancedPanel, $ignoreVc, $ignoreEsxi, $certificateHint, $newRun, $resume, $runPathLabel))

    $scanTab = New-Object System.Windows.Forms.TabPage
    $scanTab.Text = 'Scan'
    $scanButton = New-Object System.Windows.Forms.Button
    $scanButton.Text = 'Start Scan'
    $scanButton.Dock = [System.Windows.Forms.DockStyle]::Top
    $scanButton.Height = 34
    $scanButton.Add_Click({ Start-WizardAction -Action Scan })
    $scanHint = New-WizardLabel -Text 'The scan reports the offered updates, a pending reboot and the cluster membership of each VM. Every step shows the VM table below the tabs.' -X 12 -Y 48 -Width 1050 -Height 35
    $scanHint.ForeColor = [System.Drawing.Color]::DimGray
    $scanTab.Controls.Add($scanHint)
    $scanTab.Controls.Add($scanButton)
    # The VM table sits below the tabs, so each step (except Settings) shows the VMs and their results.
    $vmGrid = New-WizardGrid -Headers @('VM', 'Expected FQDN', 'Status', 'Current action', 'Offered updates', 'Reboot', 'Cluster', 'Errors', 'Account group') -Widths @(170, 200, 135, 110, 95, 115, 90, 55, 150)
    $vmGrid.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $vmGrid.Height = 190
    $vmGrid.Visible = $false
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
    $selectHint.Dock = [System.Windows.Forms.DockStyle]::Top
    $selectGrid = New-Object System.Windows.Forms.DataGridView
    $selectGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $selectGrid.AllowUserToAddRows = $false
    $selectGrid.AllowUserToDeleteRows = $false
    $selectGrid.MultiSelect = $false
    $selectGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $selectGrid.AutoGenerateColumns = $false
    Set-WizardGridScaling -Grid $selectGrid
    $checkColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $checkColumn.HeaderText = 'Selected'
    $checkColumn.Name = 'Selected'
    $checkColumn.FillWeight = 65
    $checkColumn.ReadOnly = $false
    [void]$selectGrid.Columns.Add($checkColumn)
    $selectHeaders = @('VM', 'UpdateID', 'Revision', 'Title', 'Type', 'Labels')
    $selectWidths = @(170, 280, 80, 350, 90, 180)
    for ($i = 0; $i -lt $selectHeaders.Count; $i++) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.HeaderText = $selectHeaders[$i]
        $column.Name = ('SelectColumn{0}' -f $i)
        $column.FillWeight = $selectWidths[$i]
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
    $statusPanel.Height = 140
    $statusPanel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    # Positions and sizes in the status area are set by Update-WizardStatusLayout.
    $statusLabel = New-WizardLabel -Text 'Create or resume a run.' -X 0 -Y 0 -Width 850 -Height 44
    $progressLabel = New-WizardLabel -Text 'No active run' -X 860 -Y 0 -Width 350 -Height 44
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $progressLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(0, 46)
    $progress.Size = New-Object System.Drawing.Size(1210, 18)
    $statusText = New-Object System.Windows.Forms.TextBox
    $statusText.Location = New-Object System.Drawing.Point(0, 70)
    $statusText.Size = New-Object System.Drawing.Size(1210, 65)
    $statusText.Multiline = $true
    $statusText.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $statusText.ReadOnly = $true
    $statusPanel.Controls.AddRange(@($statusLabel, $progressLabel, $progress, $statusText))
    $form.Controls.Add($statusPanel)
    $form.Controls.Add($vmGrid)
    $form.Controls.SetChildIndex($header, 3)
    $form.Controls.SetChildIndex($statusPanel, 2)
    $form.Controls.SetChildIndex($vmGrid, 1)
    $form.Controls.SetChildIndex($tabs, 0)

    $script:Wizard.Controls = @{
        Title = $title
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
        ReviewButton = $reviewButton
        NewRunButton = $newRun
        StatusLabel = $statusLabel
        ProgressLabel = $progressLabel
        ProgressBar = $progress
        StatusText = $statusText
    }

    # Fields that take up leftover space when the window is wider/taller than the zoom needs.
    $script:Wizard.Stretch = @{}
    foreach ($control in @($vcText, $vmHint, $vmText, $outputText, $certificateHint, $runPathLabel, $installHint, $rebootHint, $verifyHint)) { $script:Wizard.Stretch[$control] = 'Width' }
    foreach ($control in @($loadFile, $browseOutput)) { $script:Wizard.Stretch[$control] = 'Right' }
    $form.Add_Shown({
        $script:Wizard.BaseClientSize = $script:Wizard.Form.ClientSize
        $script:Wizard.BaseFont = $script:Wizard.Form.Font
        Set-WizardGridMinimumWidths
        Save-WizardLayout -Parent $script:Wizard.Form
        Update-WizardStatusLayout
        $script:Wizard.OutlineSizing = New-Object PatchWizardOutlineSizing($script:Wizard.Form)
    })
    # Zoom when the size changes: after a resize drag (outline only) ends, on maximize and on restore.
    $form.Add_Resize({ Update-WizardScale })
    # A hidden tab page gets its new size only when shown, so place its content again then.
    $tabs.Add_SelectedIndexChanged({
        $script:Wizard.Controls.VmGrid.Visible = ($script:Wizard.Tabs.SelectedIndex -ne 0)
        Update-WizardScale
    })

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
