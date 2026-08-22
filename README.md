# Poolaris Node GUI

Poolaris Node GUI is an independent Windows desktop manager for Keryx nodes.

This branch is intentionally isolated from the Keryx node source code. It contains a fresh WPF/.NET 8 application built from scratch.

## Goals

- Start, stop, restart and attach to `keryxd.exe`
- Configure Keryx with simple controls instead of command-line flags
- Monitor sync, peers, CPU, memory, disk I/O and logs
- Identify the active IBD source peer
- Safely update the node with backup and rollback
- Keep the GUI independent: closing Poolaris must never stop Keryx automatically

## Safety rules

- Never modify RocksDB directly
- Never delete the Keryx app directory
- Never launch two nodes against the same app directory
- RPC binds to loopback by default
- Force-kill always requires explicit confirmation

## Build

```powershell
dotnet restore PoolarisNodeGUI.sln
dotnet build PoolarisNodeGUI.sln -c Release
dotnet test PoolarisNodeGUI.sln -c Release
```

## Current phase

`GUI-GH-001` — clean WPF/MVVM foundation.
