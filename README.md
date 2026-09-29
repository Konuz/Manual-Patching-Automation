# Windows Patch Wizard

A PowerShell 5.1 WinForms operator tool for scanning, selecting, installing, rebooting, and verifying Windows Server updates on vSphere VMs through vCenter Guest Operations. Each run keeps its decisions and evidence in a run folder; credentials are never written there.

## Requirements and launch

Run from **64-bit Windows PowerShell 5.1** on the control workstation:

```powershell
Set-Location '<repository folder>'
& .\Start-PatchWizard.ps1
```

The workstation needs VMware PowerCLI (`VMware.VimAutomation.Core`) importable in PowerShell 5.1 and the Windows `%SystemRoot%\System32\curl.exe` (another curl on PATH is not used). Every target VM needs running VMware Tools, Windows PowerShell 5.1 and the local Windows Update Agent. The vCenter and guest accounts need the rights for inventory, Guest Operations, file transfer, process start, and the update actions. The tool does not use WinRM and does not change the Windows Update source.

## VM input

Type VM entries in Settings or use **Load text file**, one per line:

```text
APP-01
app-02.example.test
DMZ-WEB|dmz-web.dmz.local
```

Enter one or more vCenters, separated by commas. Each VM is looked up on all of them and bound to the one that has it; a name found on more than one vCenter is blocked. Only a powered-on VM with running VMware Tools counts, so a powered-off copy (e.g. a replication placeholder) does not block it. A name must resolve to exactly one VM; an FQDN that is not a VM name is looked up by its short name. An FQDN, when given, must be reported by VMware Tools.

## Credentials

One vCenter credential is used for every vCenter; a vCenter that rejects it gets its own prompt. Before the first action the wizard finds the VMs (vCenter credential only) and groups them by the DNS suffix VMware Tools reports: VMs of one domain share one guest credential prompt, and a VM without a suffix (typically a DMZ server) gets its own. The group is shown in the **Account group** column.

If the guest rejects a credential, the wizard offers **Retry**, **Skip these VMs** for the rest of the run, or **Stop**. If a domain credential is rejected on only some VMs of the domain, Retry asks for those VMs one by one. Every rejected logon counts toward the account's lockout threshold, so a credential rejected on two VMs of its group (and accepted by none) is not tried on the others in that step. Credentials are kept in memory only and asked again after **Resume run**.

## Operator workflow

Six steps; every action that can change a guest needs its own approval. Below the tabs, every step except Settings shows the VM table. The window content scales with the window size. Clicking a column header sorts a list A-Z, then Z-A, then back to the original order; equal values keep their order.

1. **Settings** — vCenter(s), VM entries, run folder, concurrency. Create a new run or **Resume run**.
2. **Scan** — the guest reports offered updates, pending reboot, and cluster membership (**Cluster**: `NotMember`, `Member` or `Unknown`).
3. **Select updates** — the upper list shows each offered KB once with its operating systems and VM count; its check box checks or unchecks the KB on every VM (a mixed state means partly selected). Monthly cumulative updates have a separate KB per Windows version, so excluding a faulty month takes one row per version. An update without a KB (typically a driver) is its own row. The lower list changes single VMs. KB and OS come from the scan; a run scanned by an older agent needs a new scan.
4. **Install** — the agent searches again, installs only the still-offered selected `UpdateID + RevisionNumber` pairs, and never reboots. An install past its time limit may still run: later batches wait (`PendingInstallLimit`) until approving Install again observes it. One install per round (`SkippedInstalledThisRound`); updates found later go to another round. A failed install may be approved again.
5. **Reboot** — only VMs with fresh reboot evidence; the next batch waits for a newer boot time and running VMware Tools.
6. **Verify** — a fresh scan, then another round or finish the run.

The Install and Reboot approvals list every VM with what will happen to it. In the Install approval, clicking a VM shows its selected updates (or that a started install is only observed). Enter does not approve: **Yes** needs its own click.

The wizard never repeats a round, resends an uncertain install, or sends a second reboot on its own. An agent result counts only if it matches its `runId`, `stepId` and mode and has a `finishedAt`; a reboot counts only when the guest reports a newer boot time. A failed or excluded VM (wrong name, FQDN mismatch, cluster member) is skipped and the others continue. Cluster members and VMs with an unknown cluster state (`ExcludedCluster`, also in `errors.log`) are never installed or rebooted. Only a reboot sent but not confirmed stops the next reboot batches.

A started install or reboot without a final result (e.g. the guest restarted during installation) blocks that VM's installs and reboots and **Start another round**. Check the guest (agent log, update history, boot time), then use **Mark steps reviewed** on the Verify tab. A reboot that is only slow to confirm needs no review: approving **Reboot** again only waits again and never sends a second reboot.

## Certificate choices

Two independent options, unchecked by default and saved with the run:

- **Ignore vCenter certificate** — PowerCLI certificate handling for the vCenter session only.
- **Ignore ESXi certificates for file transfers** — adds the insecure option to `curl.exe` ESXi transfers only (all guest file transfers, including the boot-time check, use `curl.exe`).

An ignored certificate means the server identity is not verified.

## Runs, logs and resume

Each run is stored in `runs/<runId>/` (or the chosen output folder): `run.json`, `run.log`, `errors.log` (when an error occurs), per-VM `status-*.json` and `agent-*.log`, and `summary.md` / `summary.csv`. **Open logs** opens the folder. Passwords and credential objects never reach these files.

Each guest keeps the agent, `status.json` and `agent.log` in `%ProgramData%\WindowsPatchWizard\<runId>` as evidence; delete that folder when the run is no longer needed.

**Resume run** continues an interrupted run: installs and reboots already started are observed, not started again; VMs not started yet are `SkippedNotStarted` and need a new approval.

## Offline verification

```powershell
& .\tests\Invoke-CoreChecks.ps1
```

Six checks with local doubles only (no vCenter, WUA, install or reboot): selecting the right VM, excluding cluster members, installing only approved `UpdateID + RevisionNumber` pairs, writing errors and the summary, independent certificate options, and no second install or reboot after resume.

## Nonproduction pilot

Use a disposable, nonproduction VM first, and confirm:

1. PowerShell bitness, PowerCLI import, curl, vCenter access, guest permissions, running VMware Tools.
2. Scan, a small selection, Install, per-update results; Reboot only with fresh reboot evidence; Verify; the files in the run folder.
3. Closing the GUI during Install and after a reboot was sent, then **Resume run**: the started step is observed, not started again.
4. A wrong guest password shows Retry / Skip these VMs / Stop.
5. With two vCenters: each VM shows its vCenter (`summary.csv`), and a vCenter with another password asks for its own credential.
6. Domain VMs mixed with a DMZ VM: the **Account group** column and one prompt per domain plus one for the DMZ VM.
7. The guest account runs the agent with full administrator rights: the first Install reports per-update results, not access denied (UAC may restrict a non-built-in local administrator; not verified yet).
8. File transfers work with **Ignore ESXi certificates** unchecked (curl revocation checks may fail for internal VMCA certificates, exit code 35; not verified yet).
9. Guest policies: `AllSigned` execution policy overrides `-ExecutionPolicy Bypass` (the step ends as NeedsReview without `status.json`; a reboot is not sent), and Constrained Language Mode or AppLocker blocks the cluster check (every VM `Unknown`).
10. Name resolution of the ESXi hosts and HTTPS (443) to them from the workstation; transfers go directly to the VM's host.
11. A VM entered by FQDN only and one whose name contains `[` or `]` are both found.
12. An unreachable vCenter stops the lookup for the whole run; a run's vCenter list cannot be changed.
13. With two vCenters and a long install, the second vCenter's VMs are still observed afterwards (an expired session shows NeedsReview; approving again observes it).
14. After a domain VM reboots, a login before domain logon is ready is not reported as a rejected credential.
15. A reboot on a VM with a restart already scheduled (`shutdown /r /t 3600`): `shutdown.exe` returns 1190 and the step waits for a newer boot time instead of failing.
16. The servers' Windows Update policy: automatic installation or scheduled restarts can act between the wizard's steps; a restart the wizard did not send shows as NeedsReview.
