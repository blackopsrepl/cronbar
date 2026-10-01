# CLI and panel

All commands accept `--config <path>`. Data commands support `--format json`
and `--pretty`.

| Command | Contract |
| --- | --- |
| `config init` | Write a default configuration |
| `config validate` | Validate the resolved configuration |
| `refresh` / `snapshot` | Collect sources and replace the snapshot |
| `waybar render` | Emit one cached-state Waybar JSON document |
| `daemon [--once]` | Refresh once or on the configured interval |
| `panel` | Set UI open and launch the native panel |
| `ui open/close/toggle/status` | Control or inspect UI state |
| `run <id> --yes` | Prompt for the run passphrase and execute |
| `run <id> --pass ... --dry-run` | Gated preview, no history entry |
| `runs` | Read the manual-run history |

Use IDs from the collected snapshot rather than guessing them. Duplicate IDs
receive a suffix. Run JSON is a flat record with `status`, `exitCode`, `stdout`,
`stderr`, `jobId`, and a boolean `dryRun`; errors can instead be diagnostics on
stderr with a nonzero exit status.

The panel offers surface metrics, text and surface filters, source/schedule
information, command detail, run confirmation, and manual history. Amber means a
commented schedule; cyan highlights anacron; unreadable surfaces show diagnostics.
Click **History** to inspect manual outcomes, **Jobs** to return, **Refresh** to
collect, or **Close**/the actual backdrop to dismiss.

Left/right click on the chip opens the panel; middle click refreshes. Signal 14
is reserved for CronBar in the SolverForge Linux family. The chip is read-only
and does not silently start a daemon; enable `cronbar.service` for periodic scans.
