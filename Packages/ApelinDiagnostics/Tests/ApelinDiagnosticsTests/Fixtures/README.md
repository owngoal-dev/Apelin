`icli-responses.json` holds one dictionary per IcliKit call, in the shapes
icli 0.8.6's source writes them (`Logging.m`, `Accessibility.m`, `Launch.m`,
`Runtime.m`, `RunningApps.m`, `respring()`, `crashLogs`; `processes` and
`installedApps` in 1.0.0's `listProcesses` and `listApps`),
written by hand for the decoder tests. Nothing here came off a device; every
pid and path is made up.
