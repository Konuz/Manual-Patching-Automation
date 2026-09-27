# Windows PowerShell 5.1 Guest Operations adapter.

function Connect-PatchVCenter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,

        [bool]$IgnoreVCenterCertificate = $false
    )

    Import-Module VMware.VimAutomation.Core -ErrorAction Stop

    if ($IgnoreVCenterCertificate) {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false -ErrorAction Stop | Out-Null
    }
    else {
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Fail -Confirm:$false -ErrorAction Stop | Out-Null
    }

    return (Connect-VIServer -Server $ServerName -Credential $Credential -ErrorAction Stop)
}

function Get-GuestFault {
    # Returns the vSphere MethodFault behind a PowerCLI exception, or $null.
    param([System.Exception]$Exception)
    for ($current = $Exception; $null -ne $current; $current = $current.InnerException) {
        if ($current -is [VMware.Vim.VimException]) { return $current.MethodFault }
    }
    return $null
}

function Get-PatchVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Server,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedFqdn,

        [string]$SavedId
    )

    if (-not [string]::IsNullOrWhiteSpace($SavedId)) {
        $found = @(Get-VM -Id $SavedId -Server $Server -ErrorAction Stop)
    }
    else {
        # Get-VM treats -Name as a wildcard pattern. Escape it before the lookup and
        # keep the literal comparison below as the final identity check.
        $escapedName = [System.Management.Automation.WildcardPattern]::Escape($Name)
        $found = @(Get-VM -Name $escapedName -Server $Server -ErrorAction Stop | Where-Object {
                [string]::Equals([string]$_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)
            })
    }

    if ($found.Count -ne 1) {
        throw ('Expected exactly one VM named {0}; found {1}.' -f $Name, $found.Count)
    }

    $vm = $found[0]
    if (-not [string]::Equals([string]$vm.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Saved VM identity does not match the requested name {0}.' -f $Name)
    }

    $actualId = $null
    $idProperty = $vm.PSObject.Properties['Id']
    if ($null -ne $idProperty) {
        $actualId = [string]$idProperty.Value
    }
    if (-not [string]::IsNullOrWhiteSpace($SavedId) -and -not [string]::IsNullOrWhiteSpace($actualId) -and
        -not [string]::Equals($actualId, $SavedId, [System.StringComparison]::Ordinal)) {
        throw ('Saved VM id {0} resolved to a different VM id {1}.' -f $SavedId, $actualId)
    }

    $guest = $vm.ExtensionData.Guest
    $guestHostName = [string]$guest.HostName
    $normalizedExpected = $ExpectedFqdn.Trim().TrimEnd('.')
    $normalizedActual = $guestHostName.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($normalizedActual) -or
        -not [string]::Equals($normalizedActual, $normalizedExpected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('VM {0} does not have the expected guest FQDN {1}. VMware Tools reported: {2}' -f $Name, $ExpectedFqdn, $guestHostName)
    }

    if ([string]$vm.PowerState -ne 'PoweredOn') {
        throw ('VM {0} is not powered on. Current state: {1}' -f $Name, $vm.PowerState)
    }
    if ([string]$guest.ToolsRunningStatus -ne 'guestToolsRunning') {
        throw ('VMware Tools are not running on {0}. ToolsRunningStatus: {1}' -f $Name, $guest.ToolsRunningStatus)
    }

    return $vm
}

function Get-GuestContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$VM,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$GuestCredential
    )

    $vmView = $VM.ExtensionData
    if ($null -eq $vmView) {
        throw 'The VM does not expose an ExtensionData view.'
    }
    $client = $vmView.Client
    if ($null -eq $client -or $null -eq $client.ServiceContent) {
        throw 'The VM view does not expose its vCenter client.'
    }

    $guestOperationsReference = $client.ServiceContent.GuestOperationsManager
    if ($null -eq $guestOperationsReference) {
        throw 'The vCenter client does not expose Guest Operations.'
    }
    $guestOperations = $client.GetView($guestOperationsReference, $null)
    $processManager = $client.GetView($guestOperations.ProcessManager, $null)
    $fileManager = $client.GetView($guestOperations.FileManager, $null)
    $authManager = $client.GetView($guestOperations.AuthManager, $null)
    if ($null -eq $processManager -or $null -eq $fileManager -or $null -eq $authManager) {
        throw 'The vCenter client could not resolve all Guest Operations managers.'
    }

    $authentication = New-Object VMware.Vim.NamePasswordAuthentication
    $authentication.Username = $GuestCredential.UserName
    $authentication.Password = $GuestCredential.GetNetworkCredential().Password
    $authentication.InteractiveSession = $false
    # ValidateCredentialsInGuest returns no value; a fault is the failure signal.
    try {
        $authManager.ValidateCredentialsInGuest($vmView.MoRef, $authentication)
    }
    catch {
        if ((Get-GuestFault $_.Exception) -is [VMware.Vim.InvalidGuestLogin]) {
            throw (New-Object System.Security.Authentication.InvalidCredentialException('The guest rejected the supplied credential.'))
        }
        throw
    }
    $guestAuthentication = $authentication

    $environmentValues = @($processManager.ReadEnvironmentVariableInGuest($vmView.MoRef, $guestAuthentication, @('ProgramData')))
    $programData = $null
    foreach ($environmentValue in $environmentValues) {
        $environmentText = [string]$environmentValue
        $separator = $environmentText.IndexOf('=')
        if ($separator -gt 0) {
            $environmentName = $environmentText.Substring(0, $separator)
            if ([string]::Equals($environmentName, 'ProgramData', [System.StringComparison]::OrdinalIgnoreCase)) {
                $programData = $environmentText.Substring($separator + 1)
                break
            }
        }
        elseif ($environmentValues.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($environmentText)) {
            $programData = $environmentText
        }
    }
    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw 'The guest ProgramData environment variable could not be read.'
    }

    $hostReference = $vmView.Runtime.Host
    if ($null -eq $hostReference) {
        throw 'The VM view does not expose its ESXi host.'
    }
    $hostView = $client.GetView($hostReference, $null)
    $esxiHostName = [string]$hostView.Name
    if ([string]::IsNullOrWhiteSpace($esxiHostName)) {
        throw 'The VM ESXi host name is empty.'
    }

    return [pscustomobject]@{
        VM = $VM
        VMView = $vmView
        Client = $client
        GuestAuth = $guestAuthentication
        ProcessManager = $processManager
        FileManager = $fileManager
        AuthManager = $authManager
        ProgramData = $programData
        EsxiHostName = $esxiHostName
    }
}

function Resolve-PatchTransferUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$EsxiHostName
    )

    # Through vCenter the URL already holds the ESXi address; a standalone host returns
    # "*" (e.g. https://*:443/guestFile?...), which must be replaced with the host name.
    return ($Url -replace '^https://\*(?=[:/])', ('https://' + $EsxiHostName))
}

function Invoke-PatchCurl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $curl = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction Stop
    $null = & $curl.Source @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Do not include the transfer URL: vSphere embeds a one-time token in it.
        throw ('curl.exe failed with exit code {0}.' -f $LASTEXITCODE)
    }
}

function Send-GuestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$LocalPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$GuestPath,
        [bool]$IgnoreEsxiCertificate = $false
    )

    $localFile = Get-Item -LiteralPath $LocalPath -ErrorAction Stop
    if ($localFile.PSIsContainer) {
        throw ('The local transfer path is a directory: {0}' -f $LocalPath)
    }

    $guestDirectory = Split-Path -Path $GuestPath -Parent
    if ([string]::IsNullOrWhiteSpace($guestDirectory)) {
        throw ('The guest transfer path has no parent directory: {0}' -f $GuestPath)
    }
    try {
        $Context.FileManager.MakeDirectoryInGuest($Context.VMView.MoRef, $Context.GuestAuth, $guestDirectory, $true)
    }
    catch {
        if (-not ((Get-GuestFault $_.Exception) -is [VMware.Vim.FileAlreadyExists])) { throw }
    }

    $attributes = New-Object VMware.Vim.GuestFileAttributes
    $transferUrl = $Context.FileManager.InitiateFileTransferToGuest(
        $Context.VMView.MoRef,
        $Context.GuestAuth,
        $GuestPath,
        $attributes,
        [int64]$localFile.Length,
        $true
    )
    $resolvedUrl = Resolve-PatchTransferUrl -Url ([string]$transferUrl) -EsxiHostName $Context.EsxiHostName

    $curlArguments = @('--disable')
    if ($IgnoreEsxiCertificate) {
        $curlArguments += '--insecure'
    }
    $curlArguments += @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        '30',
        '--request',
        'PUT',
        '--upload-file',
        $LocalPath,
        $resolvedUrl
    )
    Invoke-PatchCurl -Arguments $curlArguments

    return [pscustomobject]@{
        LocalPath = $LocalPath
        GuestPath = $GuestPath
        Bytes = [int64]$localFile.Length
    }
}

function Receive-GuestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$GuestPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$LocalPath,
        [bool]$IgnoreEsxiCertificate = $false
    )

    $localDirectory = Split-Path -Path $LocalPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($localDirectory) -and
        -not (Test-Path -LiteralPath $localDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $localDirectory -Force | Out-Null
    }

    $transferInfo = $Context.FileManager.InitiateFileTransferFromGuest(
        $Context.VMView.MoRef,
        $Context.GuestAuth,
        $GuestPath
    )
    $resolvedUrl = Resolve-PatchTransferUrl -Url ([string]$transferInfo.Url) -EsxiHostName $Context.EsxiHostName

    $curlArguments = @('--disable')
    if ($IgnoreEsxiCertificate) {
        $curlArguments += '--insecure'
    }
    $curlArguments += @(
        '--silent',
        '--show-error',
        '--fail',
        '--max-time',
        '30',
        '--output',
        $LocalPath,
        $resolvedUrl
    )
    Invoke-PatchCurl -Arguments $curlArguments

    return [pscustomobject]@{
        LocalPath = $LocalPath
        GuestPath = $GuestPath
    }
}

function Start-GuestAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$GuestAgentPath,
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install', 'Reboot')][string]$Mode,
        [Parameter(Mandatory = $true)][Guid]$RunId,
        [Parameter(Mandatory = $true)][Guid]$StepId,
        [string]$SelectionPath
    )

    $escapedAgentPath = $GuestAgentPath.Replace('"', '\"')
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1} -RunId "{2}" -StepId "{3}"' -f `
        $escapedAgentPath, $Mode, $RunId.ToString('D'), $StepId.ToString('D')
    if (-not [string]::IsNullOrWhiteSpace($SelectionPath)) {
        $escapedSelectionPath = $SelectionPath.Replace('"', '\"')
        $arguments = '{0} -SelectionPath "{1}"' -f $arguments, $escapedSelectionPath
    }

    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = $arguments
    $programSpec.WorkingDirectory = 'C:\Windows\System32'
    return [int64]$Context.ProcessManager.StartProgramInGuest($Context.VMView.MoRef, $Context.GuestAuth, $programSpec)
}

function Get-GuestProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [Parameter(Mandatory = $true)][Alias('Pid')][long]$ProcessId
    )

    return @($Context.ProcessManager.ListProcessesInGuest($Context.VMView.MoRef, $Context.GuestAuth, [long[]]@($ProcessId)))
}

function Read-GuestStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [Parameter(Mandatory = $true)][Guid]$RunId,
        [Parameter(Mandatory = $true)][Guid]$StepId,
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Install', 'Reboot')][string]$ExpectedMode,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$LocalPath,
        [bool]$IgnoreEsxiCertificate = $false
    )

    $guestStepDirectory = Join-Path (Join-Path (Join-Path $Context.ProgramData 'WindowsPatchWizard') $RunId.ToString('D')) $StepId.ToString('D')
    $guestStatusPath = Join-Path $guestStepDirectory 'status.json'
    try {
        Receive-GuestFile -Context $Context -GuestPath $guestStatusPath -LocalPath $LocalPath -IgnoreEsxiCertificate:$IgnoreEsxiCertificate | Out-Null
    }
    catch {
        # The agent has not written status.json yet.
        if ((Get-GuestFault $_.Exception) -is [VMware.Vim.FileNotFound]) { return $null }
        throw
    }

    if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) {
        return $null
    }
    $status = Get-Content -LiteralPath $LocalPath -Raw -ErrorAction Stop | ConvertFrom-Json
    if (-not [string]::Equals([string]$status.runId, $RunId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Guest status runId does not match the requested run {0}.' -f $RunId.ToString('D'))
    }
    if (-not [string]::Equals([string]$status.stepId, $StepId.ToString('D'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Guest status stepId does not match the requested step {0}.' -f $StepId.ToString('D'))
    }

    if (-not [string]::Equals([string]$status.mode, $ExpectedMode, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Guest status mode {0} does not match the expected mode {1}.' -f $status.mode, $ExpectedMode)
    }

    $statusState = [string]$status.status
    $terminalStates = if ($ExpectedMode -eq 'Reboot') { @('RebootRequested', 'Failed') } else { @('Completed', 'Failed') }
    if ($statusState -eq 'Started') {
        return $status
    }
    if ($terminalStates -notcontains $statusState) {
        throw ('Guest status state {0} is invalid for mode {1}.' -f $statusState, $ExpectedMode)
    }

    $finishedAtText = [string]$status.finishedAt
    [datetime]$finishedAt = [datetime]::MinValue
    if ([string]::IsNullOrWhiteSpace($finishedAtText) -or
        -not [datetime]::TryParse($finishedAtText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$finishedAt)) {
        throw ('Guest status {0} for mode {1} has no parseable finishedAt.' -f $statusState, $ExpectedMode)
    }
    return $status
}

function Read-GuestBootTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()]$Context,
        [bool]$IgnoreEsxiCertificate = $false
    )

    # Same channels as the agent: vCenter starts a guest process, curl.exe downloads its file.
    # (Invoke-VMScript is avoided: its ESXi transfer follows the vCenter certificate option.)
    $guestPath = Join-Path (Join-Path $Context.ProgramData 'WindowsPatchWizard') 'boottime.txt'
    $command = '$p = ''{0}''; New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null; (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString(''o'') | Set-Content -Path $p -Encoding ASCII' -f $guestPath
    $programSpec = New-Object VMware.Vim.GuestProgramSpec
    $programSpec.ProgramPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $programSpec.Arguments = '-NoProfile -NonInteractive -Command "{0}"' -f $command
    $processId = [int64]$Context.ProcessManager.StartProgramInGuest($Context.VMView.MoRef, $Context.GuestAuth, $programSpec)

    $process = $null
    for ($second = 0; $second -lt 60; $second++) {
        $process = @(Get-GuestProcess -Context $Context -ProcessId $processId)[0]
        if ($null -ne $process -and $null -ne $process.EndTime) { break }
        Start-Sleep -Seconds 1
    }
    if ($null -eq $process -or $null -eq $process.EndTime -or $process.ExitCode -ne 0) {
        throw 'The guest boot time query did not finish successfully.'
    }

    $localPath = [System.IO.Path]::GetTempFileName()
    try {
        Receive-GuestFile -Context $Context -GuestPath $guestPath -LocalPath $localPath -IgnoreEsxiCertificate $IgnoreEsxiCertificate | Out-Null
        $text = (Get-Content -LiteralPath $localPath -Raw).Trim()
    }
    finally {
        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
    }
    $bootTime = [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    return $bootTime.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}
