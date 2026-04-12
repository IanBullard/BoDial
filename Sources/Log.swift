// Log.swift — Shared os.Logger for BoDial.
//
// Unified logging means messages are:
//   - viewable live via Console.app (filter: subsystem contains "bodial")
//   - queryable after the fact via `log show --predicate 'subsystem == "com.github.ibullard.bodial"' --info --last 1h`
//   - persisted automatically by the system
//
// Levels used:
//   notice — normal lifecycle events (startup, shutdown, device connect, permission state)
//   error  — unexpected failures
//   debug  — verbose diagnostics (off by default in Console; enable with `log config`)

import os

let log = Logger(subsystem: "com.github.ibullard.bodial", category: "BoDial")
