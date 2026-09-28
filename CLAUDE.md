# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project guidelines (from the owner)

- **Simplicity is the main rule.** Do not complicate simple things. Before implementing, ask whether the task can be done more simply than the request assumes, and say so (push back) when it can.
- No tests or safeguards for unrealistic scenarios, nor for realistic ones that are unlikely and need several specific conditions at once.
- Tests only for real needs: the six key behaviours of the original plan – selecting the right VM, excluding cluster members, installing only approved `UpdateID + RevisionNumber` pairs, writing errors and the summary, independent certificate options, and no second install or reboot after resume. Do not add checks beyond them without a clear reason.
- Do not guess syntax or API behaviour: check Microsoft documentation or Context7 (or verify empirically in a scratch script) before relying on it.
- Patching happens in explicit operator steps and must stay as simple and readable as possible, both functionally and visually, for the supervising engineer.
- Commit after each fix.
- `README.md` describes the current behaviour. The original plan (Polish) is kept locally in `docs/Plan.md`, which is git-ignored and may be absent. Everything in the implementation is in English: code, GUI texts, messages, logs, reports and documentation.

## Commands

All scripts require **64-bit Windows PowerShell 5.1** (`powershell.exe`, not `pwsh`). PowerCLI (`VMware.VimAutomation.Core`) must be importable.

```powershell
& .\Start-PatchWizard.ps1                 # run the GUI
& .\Start-PatchWizard.ps1 -SmokeUi        # build the form and exit (quick UI sanity check)
& .\tests\Invoke-CoreChecks.ps1           # all offline checks (no vCenter/WUA); exit 1 on failure
```

There is no per-test filter; the suite has six checks and runs in seconds. `-NoUi` dot-sources the launcher without showing the form (useful for scratch harnesses that call GUI functions).

The guest agent can be run locally in read-only Scan mode to validate it (writes to `%ProgramData%\WindowsPatchWizard\<runId>`):

```powershell
& .\guest\PatchAgent.ps1 -Mode Scan -RunId ([guid]::NewGuid()) -StepId ([guid]::NewGuid())
```

Git: the `.git` folder is owned by another Windows account, so plain `git` fails with "dubious ownership". Use `git -c safe.directory="F:/Apki/Patching Automation v2" ...` (do not change global config unless asked). Local `master` tracks `origin/main`; push with `git push origin HEAD:main` (plain `git push` fails because the branch names differ).

## Architecture

Four scripts, one run folder per patch run:

- `Start-PatchWizard.ps1` – WinForms GUI (six tabs = six steps: Settings, Scan, Select updates, Install, Reboot, Verify). Dot-sources the controller. Long work runs in a background runspace (`Start-WizardWorker`); a 500 ms timer (`Refresh-WizardUi`) re-reads `run.json` **only while an action runs** – when idle the in-memory state is authoritative (re-reading behind an open modal dialog used to lose operator decisions).
- `scripts/RunController.ps1` – run state and orchestration. Dot-sources `GuestOps.ps1`. Entry points: `New-PatchRun`, `Resolve-PatchVms`, `Invoke-PatchAction` (Scan/Install/Reboot/Verify), `Write-PatchSummary`.
- `scripts/GuestOps.ps1` – vSphere adapter: VM lookup (`Get-PatchVM`), Guest Operations (process start/list, file transfer URLs) and `curl.exe` transfers.
- `guest/PatchAgent.ps1` – uploaded to and started in each guest (modes Scan, Install, Reboot). Uses the local WUA COM API and `GetNodeClusterState`; writes `status.json` and `agent.log` under `%ProgramData%\WindowsPatchWizard\<runId>\<stepId>`. It never reboots except in Reboot mode.

Key design points that span files:

- **State**: `runs/<runId>/run.json` (atomic temp+move writes), `run.log`, `errors.log`, `summary.md/.csv`, plus downloaded `status-*.json` / `agent-*.log`. `Write-PatchRun` serializes the state directly (compact JSON) and throws if any field **name** matches `password|credential|secret|securestring|token` – do not name state fields that way (this is why the per-VM credential group field is `accountGroup`). Put arrays into the state as plain `@(...)`: PS 5.1 writes an array wrapped in a PSObject (e.g. a function result returned with `Write-Output -NoEnumerate`) as `{"value":[...],"Count":n}`.
- **Credentials** are never persisted. `Resolve-PatchVms` (vCenter credential only) binds each VM entry to its vCenter object ID and sets `accountGroup` from the DNS suffix reported by VMware Tools (`corp.local`), or `vm:<name>` when there is none (DMZ, local admin). The GUI asks one guest credential per group and passes a hashtable group→PSCredential to `Invoke-PatchAction`. A guest rejection is detected by the vSphere `InvalidGuestLogin` fault → `InvalidCredentialException` → status `GuestCredentialRejected` → Retry/Skip/Stop dialog.
- **Several vCenters**: `run.json` holds `vCenters`; `Resolve-PatchVms` searches every vCenter and binds each VM to one (`vCenter` field); a name found on two vCenters is blocked. vCenter credentials are a hashtable name→PSCredential where `'*'` is the shared one; a vCenter that rejects it (`Test-PatchLoginRejected`) is returned in `rejectedVCenters` and the GUI asks for its own credential and reruns the step. PowerCLI runs in `DefaultVIServerMode Multiple`.
- **VM entries**: `name`, `fqdn` or `name|fqdn`; the FQDN is checked only when given; an FQDN-shaped entry is retried as the short VM name.
- **Steps**: each VM has `steps` with `stepId`, `startAttempted` (persisted *before* starting the agent) and a status. A step is finished only by a matching final `status.json` (runId, stepId, mode, `finishedAt` – enforced in `Read-GuestStatus`) or by the operator's **Mark steps reviewed**. Resume observes started steps instead of starting them again; an unresolved install/reboot blocks further installs/reboots of that VM and new rounds.
- **Reboot**: baseline boot time saved before sending, reboot sent once, confirmed only by a newer boot time (`Wait-PatchReboot`). A reboot that was sent (`startAttempted`) but not confirmed stops later reboot batches; any other failure affects only its own VM. Cluster members (last agent status not `NotMember`) are skipped as `ExcludedCluster` before install or reboot.
- **Certificate options are independent**: the vCenter option only sets PowerCLI `InvalidCertificateAction` for the session; the ESXi option only adds `--insecure` to `curl.exe`. All guest file transfers (including the boot-time read) go through `curl.exe` – do not use `Invoke-VMScript`/`Copy-VMGuestFile`, whose ESXi transfer follows the vCenter option.
- **Concurrency**: VMs are processed in batches (scan/install concurrency, reboot batch size): start every VM in the batch, then wait for each.
- **GUI zoom**: `Save-WizardLayout` remembers all control bounds at first show; `Update-WizardScale` (on every resize and tab switch) sets bounds = reference × factor plus stretch rules from `$script:Wizard.Stretch`, and scales fonts. Do not add WinForms anchors – they fight this layout.

## Gotchas

- The controller sets `Set-StrictMode -Version 2.0`, which also applies to the dot-sourced launcher and tests: `.Count` on a single object throws – wrap results in `@(...)`.
- Test doubles are functions defined after dot-sourcing the controller. PowerShell scoping is dynamic, so a double must use `$script:` variables, not names that callers also use as locals (e.g. `$context`).
- `Invoke-PatchCurl` uses `%SystemRoot%\System32\curl.exe` (Git for Windows puts a second curl on PATH) and sets `ErrorActionPreference = 'Continue'` locally: in PS 5.1 redirected stderr of a native program is a terminating error under `Stop`.
- Nothing touching vSphere can be verified offline; behaviour that depends on a real vCenter/ESXi belongs in the pilot described in `README.md`.
