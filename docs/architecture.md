# Runtime architecture

CronBar is a Ruby CLI, a cached-state Waybar chip, and a native QuickShell panel.
It has no web application or web server. Lumen is only an optional external
headless-compositor test viewer.

## Collection

The collector reads the current user's `crontab -l`, `/etc/crontab`, files under
`/etc/cron.d`, and `/etc/anacrontab`. Anacron timestamp files under
`/var/spool/anacron` provide last-run dates. Missing and inaccessible surfaces
remain represented in the snapshot; noninteractive sudo read fallback never
turns a read privilege into a command execution privilege.

Valid commented schedule lines are retained as manual-only jobs. Ordinary prose
comments are not executable entries. Cron schedule projections are local-time
estimates; anacron projections describe period/delay rather than fixed clock times.
This is not an inventory of other users' private crontabs or systemd timers.

## State and execution

Default config: `~/.config/cronbar/config.json`.
Default state: `~/.local/state/cronbar`.
Snapshots, UI state, events, and manual-run history are separate JSON documents.
State writes are atomic; refresh and manual execution have separate locks.
Waybar rendering reads the cached snapshot and never scans sources itself.
The daemon refreshes every 300 seconds and sends Waybar `RTMIN+14`.

Manual execution runs the stored command through `runtime.runnerShell` as the
current user. It does not impersonate a system cron row's user, recreate cron's
environment assignments, or wait through anacron's delay. Explicit sudo in a
command retains its own policy; there is no automatic privilege escalation.
Runs time out after an hour; captured output is truncated for history display.
A dry run is a preview and is not appended to execution history.

## Panel

QuickShell watches snapshot, UI, and run-history files. Commands are queued so
refresh/close/run requests are not lost while a process is busy. Manual execution
requires a passphrase and a second confirmation click. No credential is embedded
in the shipped panel.

The panel is a bounded bar drop-down that drops below the bar edge: the layer
window (a bounded PanelWindow surface) is exactly the card's rect (plus the
shadow's drop band) hung from the top bar edge, its height counted from the
parts actually laid out and capped to the viewport — never a full-screen
overlay. The desktop beside the strip stays
interactive; apps are never covered unless the card is over them. A bounded
Wayland surface is opaque to input, so the retired full-screen modal's
"click anywhere outside closes" behavior cannot survive: dismissal is Esc, the
Close button, or a click inside the strip but outside the card's radius.
