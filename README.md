# Windows Patch Wizard

Windows Patch Wizard is a PowerShell 5.1 WinForms operator tool for scanning, selecting, installing, rebooting, and verifying Windows Server updates on vSphere virtual machines through vCenter Guest Operations. It keeps each run's decisions and evidence in a dedicated run folder and never writes credentials to that folder.

## Requirements and launch

Run the launcher from **64-bit Windows PowerShell 5.1** on the control workstation:

```powershell
Set-Location 'F:\Apki\Patching Automation v2'
& .\Start-PatchWizard.ps1
```

The workstation needs:

- VMware PowerCLI, including `VMware.VimAutomation.Core`, importable in Windows PowerShell 5.1.
- The Windows `curl.exe` client for ESXi Guest Operations file transfers.
- VMware Tools running in every target VM.
- vCenter and guest credentials with the permissions required for inventory, Guest Operations, file transfer, process start, and the requested update actions.

The guest must have Windows PowerShell 5.1 and the local Windows Update Agent available. The tool does not use WinRM and does not change the configured Windows Update source.

## VM input

Type VM entries into the Settings page, or use **Load text file**. One VM per line, in any of these forms:

```text
APP-01
app-02.example.test
DMZ-WEB|dmz-web.dmz.local
```

A name must resolve to exactly one VM on the selected vCenter. An FQDN that is not a VM name is looked up by its short name (`app-02`). The FQDN is optional; when one is given, VMware Tools must report it, otherwise the VM is blocked.

## Guest credentials

Before the first action, the wizard finds the VMs in vCenter (vCenter credential only) and groups them by the DNS suffix VMware Tools reports:

- VMs with the same suffix (e.g. `example.test`) share one prompt: **Guest credential for domain example.test**.
- A VM without a suffix, typically a DMZ server with its own local administrator, gets its own prompt.
- If a domain credential is rejected on only some VMs of that domain (e.g. DMZ servers that share the DNS suffix), **Retry** asks for those VMs one by one. If it is rejected on all of them, the domain password is asked again.

The groups are shown in the **Account group** column and saved in `run.json`; the credentials are kept in memory only and asked again after **Resume run**.

## Operator workflow

The wizard presents six steps. Actions that can change a guest require a separate explicit approval in the corresponding step.

1. **Settings** — choose the vCenter, vCenter credential, VM entries, run folder, and concurrency. Create a new run or choose **Resume run**.
2. **Scan** — start the scan. The guest reports offered updates, pending reboot state, and cluster membership.
3. **Select updates** — review the per-VM list, including optional updates and drivers, then approve the selected `UpdateID + RevisionNumber` values for installation.
4. **Install** — approve installation. The agent searches again and installs only the still-offered selected revisions. The agent does not reboot the guest.
5. **Reboot** — review the VMs with fresh reboot evidence and approve the reboot batch separately. The next batch waits for a newer boot time and running VMware Tools.
6. **Verify** — start a fresh scan, then start another operator-selected round or finish the run with the remaining updates listed.

The wizard does not automatically repeat a round, resend an uncertain install, or send a second reboot after an interrupted run. A final agent result must match its `runId`, `stepId`, mode, and have a parseable `finishedAt`. A reboot counts as done only when the guest reports a boot time newer than the one saved before the reboot was sent.

A failed or excluded VM (wrong name, FQDN mismatch, cluster member) is recorded and skipped; the other VMs continue. Only an unconfirmed reboot stops the next reboot batches.

If a started install or reboot has no final result (for example, the guest was restarted during installation), that VM is blocked for further installs and reboots, and **Start another round** stays disabled. Check the guest manually (agent log, Windows Update history, last boot time), then use **Mark steps reviewed** on the Verify tab.

If the guest rejects the credential, the wizard asks: **Retry** with a new credential, **Skip these VMs** for the rest of the run, or **Stop**.

## Certificate choices

Settings contains two independent, unchecked-by-default options:

- **Ignore vCenter certificate** changes PowerCLI's certificate handling for the current vCenter session.
- **Ignore ESXi certificates for file transfers** adds the insecure curl option only to ESXi transfer calls. All guest file transfers, including the boot-time check, use `curl.exe`.

Enabling one option does not enable the other. Ignoring a certificate means the server identity is not verified. The choices are saved in the run state and summary so a resumed run keeps the same settings.

## Runs, logs, resume, and credentials

Each run is stored under `runs/<runId>/` (or the output folder selected in Settings). A new run starts with `run.json`. During actions, `run.log` is appended, `errors.log` is created when an error is recorded, per-VM status and agent log files appear when an agent step runs, and `summary.md` and `summary.csv` are created or refreshed whenever the controller writes a summary. A skipped VM or a newly created run therefore may not have every file. Use **Open logs** in the wizard or open the run folder directly.

Use **Resume run** to continue an interrupted run. Credentials are requested again and kept in memory only; passwords, secure strings, and credential objects are excluded from `run.json`, logs, and summaries.

## Offline verification

Run the focused checks from 64-bit Windows PowerShell 5.1:

```powershell
& .\tests\Invoke-CoreChecks.ps1
```

The six checks cover the key behaviours named in the plan: selecting the right VM, excluding cluster members, installing only approved `UpdateID + RevisionNumber` pairs, writing errors and the summary, independent certificate options, and no second install or reboot after resume. They use local doubles only and do not connect to vCenter, query WUA, install updates, or reboot a VM.

## Safe nonproduction pilot

Before production use:

1. Confirm the PowerShell 5.1 bitness, PowerCLI import, curl availability, vCenter access, guest permissions, and running VMware Tools.
2. Select one disposable, nonproduction VM and enter its exact name and expected FQDN.
3. Run Scan, review the offered updates and cluster state, select a small approved set, then approve Install.
4. Review per-update results and approve Reboot only when the wizard reports fresh pending reboot evidence.
5. Complete Verify and inspect the files written for the run, including `run.log`, any `errors.log`, per-step `status-*.json` and `agent-*.log`, `summary.md`, and `summary.csv`.
6. Repeat the pilot after closing the GUI during Install and after reboot dispatch; use Resume run and confirm that the existing step is observed instead of started again.
7. Enter a wrong guest password once and confirm that the Retry / Skip these VMs / Stop dialog appears.

Do not use a production VM for the first pilot. Cluster members and VMs with an unknown cluster state remain blocked for install and reboot.
