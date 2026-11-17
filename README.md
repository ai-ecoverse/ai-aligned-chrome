# ai-aligned-chrome

Keeps test browsers out of the macOS login keychain. It wraps every Chrome for
Testing and Chromium build that Playwright, Puppeteer, slicc-cdp and the like
download, so a browser launched with a throwaway profile always gets
`--use-mock-keychain`. That holds even when the harness that launched it forgot
the flag. You don't need a `CLAUDE.md` section or a per-repo fix, and no
harness has to be patched. Every launcher runs the browser it was always going
to run.

## Why

Chrome for Testing is ad-hoc signed, so the keychain sees every build as a new
app (a new cdhash). When a build starts without `--use-mock-keychain`, it reads
**"Chromium Safe Storage"** and macOS shows a password prompt:

> Google Chrome for Testing wants to use your confidential information stored
> in "Chromium Safe Storage" in your keychain.

On one Mac running agents all day:

| observation | count |
| --- | --- |
| Keychain prompts from test browsers in one hour | 31 |
| Apps on the "Chromium Safe Storage" access list, one per build someone clicked *Always Allow* for | 28 |
| Test harnesses found starting the browser without the flag | 2 (`slicc-shared-web` harness, `slicc-cdp` integration tests), each found only after an outage |
| `gh` keychain lookups queued behind one unanswered prompt | 839 |

The prompt is the smaller problem. While it waits for an answer, every other
keychain client queues behind it, including `gh`, git credential helpers and
bb's own GitHub polling. Nobody answers while the screen is locked, so the
lookups pile up and the next outage starts.

Fixing it in each harness works until someone writes the next harness. Two
other fixes look obvious but don't work:

- **A `PATH` shim**, like the other ai-aligned tools, never runs here.
  Harnesses start the browser by absolute path.
- **An "allow all applications" ACL** on the item still prompts. The item's
  partition list is checked per cdhash, and an ad-hoc build has no team ID that
  could be listed once.

Every launcher, however, ends at the same place: the bundle's main executable.

## What it does

1. **Wraps the executable.** `Contents/MacOS/Google Chrome for Testing` is
   hard-linked aside to `.Google Chrome for Testing.real`. A small launcher
   then takes its place in one atomic rename, so the path is never missing.
2. **Adds the flags only for throwaway profiles.** The launcher adds
   `--use-mock-keychain --password-store=basic` when `--user-data-dir` is
   under a temp directory (`$TMPDIR`, `/tmp`, `/var/folders`). Persistent
   profiles keep the real keychain and their saved cookies. So do launches
   without `--user-data-dir`. If the flag is already there, it isn't added
   twice.
3. **Wraps new downloads before their first launch.** A LaunchAgent watches
   the browser caches through FSEvents and wraps each build while it is still
   being unpacked. It uses no CPU while nothing is being downloaded.
4. **Names the offender.** `ai-aligned-chrome prompts` lists keychain prompts
   raised by test browsers. For each one still running, it shows the process
   tree and working directory that launched it.

The launcher uses `exec -a` to keep `argv[0]`, so `ps`, `pgrep` and anything
else that matches on the browser's path see the same command line as before.

## Install

```bash
git clone https://github.com/ai-ecoverse/ai-aligned-chrome
cd ai-aligned-chrome
./install.sh
```

The installer copies the tool to `~/.local/bin` and wraps every test browser
already on disk. It then starts the LaunchAgent `com.ai-ecoverse.ai-aligned-chrome`
and runs `doctor`.

To undo everything:

```bash
ai-aligned-chrome agent uninstall && ai-aligned-chrome unwrap
```

## Usage

```
ai-aligned-chrome status            test browsers and whether each is wrapped
ai-aligned-chrome wrap [APP…]       wrap everything under the roots, or the APPs given
ai-aligned-chrome unwrap [APP…]     restore the original executables
ai-aligned-chrome prompts [--last 1h]
                                    keychain prompts from test browsers, with launchers
ai-aligned-chrome agent install|uninstall|status
ai-aligned-chrome doctor            agent running, everything wrapped, recent prompts
```

The tool scans these cache roots:

- `~/Library/Caches/slicc-cdp/browsers`
- `~/Library/Caches/ms-playwright`
- `~/Library/Caches/puppeteer`
- `~/.cache/puppeteer`
- `~/.cache/selenium`
- `~/.cache/slicc-cft`

Only bundles with the identifier `com.google.chrome.for.testing` or
`org.chromium.Chromium` are touched. Google Chrome itself, Firefox and WebKit
are never wrapped.

| environment | |
| --- | --- |
| `AI_ALIGNED_CHROME_ROOTS=<a:b>` | cache roots to scan, replacing the defaults |
| `AI_ALIGNED_CHROME_DISABLE=1` | in a launch environment: start the browser without adding the flags |
| `AI_ALIGNED_CHROME_POLL=1` | watch by polling instead of FSEvents |
| `AI_ALIGNED_CHROME_HOME` | state directory (default `~/.ai-aligned-chrome`) |

## Limits

- **The bundle's code seal is broken on purpose.** `codesign --verify` on a
  wrapped `.app` fails, because its main executable is now a script. The real
  binary keeps its own valid signature, and both `spawn` and `open -a` launch it
  normally. Downloaded test browsers carry no quarantine, so Gatekeeper doesn't
  check them.
- **Only the cache roots are covered.** A browser unpacked somewhere else
  needs `ai-aligned-chrome wrap <path>`, or that path added to
  `AI_ALIGNED_CHROME_ROOTS`.
- **Persistent profiles still use the keychain.** A test browser started with
  a `--user-data-dir` outside temp asks for the keychain as before. That is
  deliberate: its cookies are encrypted with the real key.
- **Harnesses should still pass the flag.** On Linux CI it doesn't matter, but
  on another developer's Mac it does. This tool is a safety net, not a reason
  to drop the flag.

## Testing

```bash
./test.sh
```

The suite builds fake browser bundles under a throwaway root. Their
"browser" is a tiny Mach-O that records its argv. The suite never touches the
real caches, the LaunchAgent or the keychain.
