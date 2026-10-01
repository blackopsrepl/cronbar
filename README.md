# CronBar

A SolverForge Linux companion bar that makes every scheduled job on the machine
visible and runnable from one panel: the user crontab, `/etc/crontab`,
`/etc/cron.d`, and anacron (`/etc/anacrontab`) — including jobs that are
commented out, which can be run manually with one click.

Part of the SolverForge bar family: RepoBar, TrexBar, BackupBar, TokenMaxx
(CodexBar), SolverForge BenchBar.

## Schedules at a glance

| Surface | Readable? | Jobs |
| --- | --- | --- |
| `crontab -l` (user) | yes, `crontab` command | personal jobs |
| `/etc/crontab` | root-only on this host | system jobs (root's own user crontab is readable) |
| `/etc/cron.d` | directory listable, files root-only | packaged jobs |
| `/etc/anacrontab` | readable | machine-wide daily/weekly/monthly |
| `/var/spool/cron/tabs/` | root-only | — |
| `/var/spool/anacron/` | timestamps readable | anacron last-run timestamps |

`/etc/crontab` and `/etc/cron.d` are root-restricted on this host. CronBar reads
them with sudo when sudo is available and shows them as
`locked: run <cmd> as root` when it is not. System surfaces stay visible either
way.

## Install

```sh
make install-user            # app under ~/.local, bin symlink
make install-solverforge     # SolverForge waybar wrapper into ~/.local/share/solverforge/bin
cronbar omarchy install      # Omarchy shell bar module (left: panel, middle: refresh)
```

## Quick start

```sh
cronbar config init          # write ~/.config/cronbar/config.json
cronbar refresh              # scan every surface, write the cached snapshot
cronbar panel                # open the QuickShell panel
cronbar waybar render        # Waybar chip JSON from cached state
cronbar run <id>             # run a job manually (incl. commented ones)
```

Every job gets a stable id: `user`, `sys`, `cron.d:name`, `anacron:name`. Run a
specific job with `cronbar run user` or, for duplicates, `cronbar run cron.d:name@2`.

## Docs

- [WIREFRAME.md](WIREFRAME.md) — product boundary and runtime contract
- [AGENTS.md](AGENTS.md) — repository guidelines for agents
- `docs/architecture.md`, `docs/cli.md`, `docs/ui.md` — shipped docs

## Current release: `v0.1.0`

## License

MIT
