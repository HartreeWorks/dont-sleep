# dont-sleep

Keep your MacBook awake while Claude Code or Codex is working—even on battery with the lid closed—and let it sleep when the agent stops.

> [!WARNING]
> **Beta software. Use at your own risk.** `dont-sleep` changes system sleep behaviour and has been physically tested on just one Apple Silicon MacBook M4 running macOS Sequoia 15.7.

## Quickstart

Install `dont-sleep` as a root LaunchDaemon so it starts automatically after every reboot:

```bash
mkdir -p "$HOME/code"
git clone https://github.com/HartreeWorks/dont-sleep.git "$HOME/code/dont-sleep"
cd "$HOME/code/dont-sleep"

sudo mkdir -p /usr/local/libexec
sudo install -o root -g wheel -m 755 dont-sleep.sh /usr/local/libexec/dont-sleep.sh

sed \
  -e 's|/ABSOLUTE/PATH/TO/dont-sleep.sh|/usr/local/libexec/dont-sleep.sh|' \
  -e "s|YOUR_USERNAME|$USER|g" \
  dont-sleep.plist > /tmp/com.example.dont-sleep.plist

sudo install -o root -g wheel -m 644 \
  /tmp/com.example.dont-sleep.plist \
  /Library/LaunchDaemons/com.example.dont-sleep.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.dont-sleep.plist
```

Check that it is running:

```bash
sudo launchctl print system/com.example.dont-sleep
tail -f "$HOME/Library/Logs/dont-sleep.log"
```

The default battery threshold is 50%. To change it, edit the `50` in `ProgramArguments` in the installed plist, then reload the daemon.

## What it does

Every 15 seconds, `dont-sleep` checks agent activity, battery level, lid state and thermal pressure:

- It enables `pmset disablesleep` while a Claude Code or Codex agent is active and the battery is at least 50%.
- It recognises long, quiet tool calls as active work. Tools waiting for human input do not count after the five-minute activity grace.
- When the agent stops or the battery falls below 50%, it releases the override. If the lid is shut on battery, it forces sleep because macOS does not retry a suppressed lid-close event.
- If a lid-shut Mac reaches Heavy thermal pressure twice in succession, it releases the override and forces sleep.

The override is armed while the lid is still open. This matters because macOS can sleep before the daemon's next poll if it waits to observe the lid closing.

Agent activity comes from `.jsonl` transcripts under `~/.claude/projects` and `~/.codex/sessions`. Recent transcript writes cover normal work; unmatched tool calls cover long steps without output.

## Updating

```bash
cd "$HOME/code/dont-sleep"
git pull
sudo install -o root -g wheel -m 755 dont-sleep.sh /usr/local/libexec/dont-sleep.sh
sudo launchctl kickstart -k system/com.example.dont-sleep
```

## Running manually

```bash
./dont-sleep.sh            # default 50% battery threshold
./dont-sleep.sh 70         # custom threshold
./dont-sleep.sh --dry-run  # log decisions without changing sleep state
```

The script needs root access for `pmset disablesleep` and thermal-pressure readings, so manual runs prompt once for `sudo`.

## Configuration and logs

Advanced settings—including the five-minute activity grace, thermal trigger, polling interval and five-minute post-sleep cooldown—are constants near the top of `dont-sleep.sh`.

State changes are logged to `~/Library/Logs/dont-sleep.log`. Logs older than 14 days are pruned at startup.

Do not run a LaunchDaemon script directly from `~/Documents`, `~/Desktop`, `~/Downloads` or iCloud Drive: macOS privacy controls can block root daemons from those folders. The quickstart avoids this by installing a root-owned copy under `/usr/local/libexec`.

## Tests

```bash
./tests/test-dont-sleep.sh
```

The test suite covers Claude and Codex transcript states plus lid, power, battery, thermal, cooldown and sleep decisions. A supervised physical test confirmed that a lid-shut Mac stayed awake through a quiet tool call, then slept after the agent became idle.

## Requirements

- macOS; developed and tested on Apple Silicon
- Claude Code and/or Codex
- `/usr/bin/jq`

## Credits and licence

Inspired by JP Addison's [keep-awake.sh](https://github.com/jpaddison3/dotfiles/blob/master/keep-awake.sh). Licensed under the [MIT Licence](LICENSE).
