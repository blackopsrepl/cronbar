# CronBar

<p align="center">
  <img src="docs/assets/cronbar-mascot.png" width="200" alt="Tick, CronBar’s clockwork owl, holding an amber sleeping job">
</p>

**Tick** keeps watch over the schedule. The amber sleeping job is a commented
entry, ready to wake only when you deliberately run it.

A SolverForge Linux companion: cached Waybar chip plus a native QuickShell panel
for the current user's cron jobs, system crontab, `/etc/cron.d`, and anacron.
Valid commented schedule lines are retained for deliberate manual execution.
Locked or missing sources stay visible rather than disappearing.

## Install

Requires Ruby 3.4+, Bash, and cron tools. Waybar and QuickShell are required for
the desktop surfaces. No Ruby gems are needed. Release development additionally
requires Node.js, npm and Git for `commit-and-tag-version`.

```sh
make check
make install-user
make install-solverforge
cronbar config init
cronbar refresh
cronbar waybar render
cronbar panel
```

`install-user` installs under `~/.local/share/cronbar` and links
`~/.local/bin/cronbar`. `install-solverforge` installs the wrapper; it does not
rewrite the desktop layout. Add the module from `examples/waybar.json` to the
framework's source config, and insert `custom/cronbar` immediately before `cpu`
in `modules-right`. Merge `examples/waybar.css` into the framework stylesheet.
Do not replace a SolverForge Linux managed symlink with a standalone config.

To keep cached data fresh, install the supplied user service:

```sh
mkdir -p ~/.config/systemd/user
cp examples/cronbar.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now cronbar.service
```

## Manual runs

Select a job, enter the run passphrase, then click **run now** and **confirm run**.
The CLI equivalent is `cronbar run <job-id> --yes` (masked terminal prompt).
`--dry-run` previews without executing. The root-owned gate file
`/etc/cronbar/run.pass` stores SHA-256 of `cronbar-run:<passphrase>`, not plaintext.

```sh
sudo install -d -m 755 /etc/cronbar
ruby -rdigest -rio/console -e 'print "New run passphrase: "; p = STDIN.noecho(&:gets)&.chomp; puts; abort "empty passphrase" if p.to_s.empty?; File.write(ARGV.fetch(0), Digest::SHA256.hexdigest("cronbar-run:#{p}") + "\n")' "$HOME/cronbar-gate.digest"
sudo install -o root -g "$(id -gn)" -m 640 "$HOME/cronbar-gate.digest" /etc/cronbar/run.pass
rm "$HOME/cronbar-gate.digest"
```

The launching user must be able to read the digest. This gate prevents accidental
runs; it is not an OS authorization boundary. `--pass` exposes its value in
process arguments; prefer the CLI's masked prompt for terminal use.
Commands run as the launching user, not automatically as the user named in a
system cron row. Cron environment assignments are not reproduced. Inspect any
privileged command before executing it. CronBar does not enumerate other users'
private crontabs or systemd timers.

## Development and releases

`make help` lists checks, installation, packaging, and release targets.
`make release-check` exercises isolated CLI, install and archive paths without
opening a panel on the host or executing real scheduled workloads.
The QuickShell UI has structural tests; visual testing belongs in the existing
Lumen instance, not a second viewer or the user's working desktop.

Releases use `commit-and-tag-version`: the tool updates this README and the Ruby
version together, generates `CHANGELOG.md`, then commits and tags the release.
Run the documented release targets from a clean committed tree. Push main and
the generated tag to both remotes. GitHub's tag workflow runs the CI gate,
verifies the tag/version contract, and publishes the source archive with
changelog-derived release notes. Build artifacts and local credentials are
never part of the checkout.

- [Architecture and execution boundaries](docs/architecture.md)
- [CLI and panel](docs/cli.md)

## Current release: `v0.1.0`

## License

MIT — see [LICENSE](LICENSE).
