# Contract

| Item | Value |
| --- | --- |
| Desired state | host: `runners.json` < `runners.local.json`. Windows clone: `runners.json` < `runners.host.json` (manager-written, hash-checked) < `runners.local.json` (Install-written). One writer per file. |
| Host state | `%LOCALAPPDATA%\SubZeroDev\Runners\host\inventory.json`, `operation.json`, schema + version, atomic writes |
| Host lock | `Local\SubZeroDev.Runners.Host`; joined through `SZR_HOST_OPERATION` |
| Counts | `linux.count`, `windows.count`: null (keep what exists) or 0–16; `Init` writes 2/2 |
| Linux slot `nn` | runner `subzerodev.runner.linux.<hostId>.<nn>`, container `subzerodev-runner-linux-<nn>`, directory `linux/runner-<nn>`, volumes `…-<nn>`; slot 01 legacy: `subzerodev.runner.linux`, `linux/runner`, existing volumes, container `subzerodev-runner-linux-01` |
| Windows instance | `win<nn>`, runner `subzerodev.runner.windows.<hostId>.win<nn>` |
| Held | the maintenance record exists (unreadable included); no listener while held |
| Ends maintenance | `Manage-RunnerHost -Action Resume` and `Manage-WindowsRunner -Action Start`; an operation ends only maintenance it started (`heldBefore` false) |
| Windows changes | per instance, never through `Setup-WindowsRunners.ps1`; a held instance is never changed (`deferred: held`) |
| Compose | project `subzerodev-runners`, file `linux/compose.local.yaml`, `restart: always`, always with service names and `--no-deps` |
| Deletion | only by recorded identity (runner ID + name + scope; container full ID + name, plus labels for containers the manager created), never by name or prefix; unknown ≠ absent |
| Labels | unchanged: `subzerodev` + `subzerodev-linux` / `subzerodev-windows` + custom; host labels from `hostId` |
| Exit codes | Plan and Apply: 0 no change, 3 changes or surplus without `-Retire`; refusals nonzero with the reason |
| Unchanged | `Invoke-BuildAgent.ps1` parameters, `SZR_SCRIPTS`, both existing `-Json` shapes, `Manage-WindowsRunner -Action Start`, `Setup-WindowsRunners -Count` range, pinned digests, never `:latest` |
