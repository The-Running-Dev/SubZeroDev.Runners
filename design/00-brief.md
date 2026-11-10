# Brief

SubZeroDev.Runners runs the private self-hosted GitHub Actions runners for the AbsoluteZeroDev organization: Linux
runners as BuildAgent-based containers and Windows runners as native per-user instances. The pool work lets each host
run a configurable number of Linux and Windows runners (default 2 each, set per machine), owned through a host
inventory and changed only by journaled operations under one host lock.

Who it is for: the owner's own hosts (first beast, Windows 11 with Docker Desktop and auto sign-in) and the
AbsoluteZeroDev repositories that target `[self-hosted, subzerodev, Linux|Windows]`.

Must keep working: the existing Linux runner and its registration, the Windows instances, every org workflow
unchanged, SubZeroDev.Dashboard telemetry v1 (both existing `-Json` outputs byte for byte), and
`Manage-WindowsRunner.ps1 -Action Start` as an explicit resume. BuildAgent is not changed.

Out of scope: changes to BuildAgent, moving any repository's jobs into BuildAgent (separate work in each repository),
editing `.wslconfig`, auto sign-in or Docker Desktop settings, and Windows VMs.
