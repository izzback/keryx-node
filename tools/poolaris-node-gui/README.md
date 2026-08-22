# Poolaris Node GUI

Windows desktop GUI for launching, updating and monitoring a Keryx node.

## Goals

- Start and stop `keryxd.exe` without using a terminal.
- Expose common node options as simple toggles and numeric fields.
- Keep advanced CLI arguments visible but out of the normal path.
- Detect an already-running Keryx node without interrupting it.
- Show synchronization state, estimated blocks remaining, ETA, BPS, peers, CPU, RAM, disk and logs.
- Update the node executable safely with backup and rollback support.
- Keep the GUI separate from consensus and node data.

## Initial stack

- .NET 8
- WPF
- MVVM-friendly structure
- Windows 10/11 x64

## Safety

The GUI does not modify consensus data. Node updates are staged outside the active data directory and are only swapped when the node is stopped.
