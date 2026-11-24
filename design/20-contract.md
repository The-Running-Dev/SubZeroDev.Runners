# Contract

| Item | Value |
| --- | --- |
| Desired state | host: `runners.json` < `runners.local.json`. Windows clone: `runners.json` < `runners.host.json` (manager-written, hash-checked) < `runners.local.json` (Install-written). One writer per file. |
| Host state | `%LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json`, `operation.json`, schema + version, atomic writes |
| Host lock | `Local\SubZeroDev.Runners.Host.<hash of the state directory>`. A joinable holder records a token in `lock.json` and `SZR_HOST_OPERATION`; a child joins when its `SZR_HOST_OPERATION` matches and the recorded holder is alive |
| Counts | `linux.count`, `windows.count`: null (keep what exists) or 0–16; `Init` writes 2/2 |
| Slot states | `provisioning` → `active` → `retiring` → `retired` → `pruned`. `unowned` is a registration Adopt could not prove: its number is reserved and nothing changes it |
| Linux slot `nn` | runner `subzerodev.runner.linux.<hostId>.<nn>`, container `subzerodev-runner-linux-<nn>`, directory `linux/runner-<nn>`, volumes `…-<nn>`. Slot 01 legacy: `subzerodev.runner.linux`, `linux/runner`, existing volumes, and after `migrate-legacy-linux` the container `subzerodev-runner-linux-01`; the pre-pool containers are kept stopped (`keptForRollback`) until `Apply -Prune` |
| Windows instance | `win<nn>`, runner `subzerodev.runner.windows.<hostId>.win<nn>`, clone `InstallRoot\win<nn>`. The checkout's own pre-pool install is `windows-legacy`, outside numbering, and is retired only with `-Retire` once `win01` is online |
| Held | the maintenance record exists (unreadable included); no listener while held |
| Ends maintenance | `Manage-RunnerHost -Action Resume` and `Manage-WindowsRunner -Action Start`; an operation ends only maintenance it started (`heldBefore` false) |
| Windows changes | per instance, never through `Setup-WindowsRunners.ps1`; a held instance is never changed (`deferred: held`) |
| Compose | project `subzerodev-runners`, file `linux/compose.local.yaml`, `restart: always`, networks and volumes external and created beforehand, always with service names and `--no-deps`, never `down` |
| Update | `Update -Version x.y.z` resolves the BuildAgent release to its digest and writes `buildAgent.image` to `runners.local.json` and the inventory before anything is recreated; floating tags are refused. A replaced digest is recorded with its version, and an older version in settings is a downgrade that Apply refuses |
| Deletion | only by recorded identity (runner ID + name + scope; container full ID + name, plus labels for containers the manager created), never by name or prefix; unknown ≠ absent |
| Labels | unchanged: `subzerodev` + `subzerodev-linux` / `subzerodev-windows` + custom; host labels from `hostId` |
| Exit codes | Plan: 0 no changes; 3 changes, or a drift or blocked finding; 1 when the host state or anything Plan needs cannot be read. Apply and Update: 0 done; 3 a retire skipped without `-Retire`, or a slot deferred (held, busy, or `windows-legacy` before `win01`); 1 refused or failed, with the reason |
| Unchanged | `Invoke-BuildAgent.ps1` parameters, `SZR_SCRIPTS`, both existing `-Json` shapes, `Manage-WindowsRunner -Action Start`, `Setup-WindowsRunners -Count` range, pinned digests, never `:latest` |
