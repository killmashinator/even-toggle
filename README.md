> **Fork note (RussReadsBooks/even-toggle):** default branch `security-hardening` adds, on top of upstream `65489ad`:
> menu-bar icon shows on/off state; server stops on quit; no copy of the pairing token (even-terminal reads `~/.even-terminal/config.json`, never `-t`/defaults);
> token/QR redaction in the log panel; caffeinate tied to the server; no orphaned server (signals + reap on relaunch);
> trusted-path launch, validated settings and an allowlisted child environment; build output untracked.
> Intended to be offered upstream as a PR once tested.

# EvenToggle 👓

A tiny macOS menu bar app that turns your **Claude Code + Even Realities G2**
server on and off with one click. It lives up by your Wi-Fi/battery icons, starts
at login, and keeps the **same token and port every time** — so you pair your
glasses **once** and never reconfigure again.

It's a *supervisor*: clicking **Turn On** launches the `even-terminal` server with
your saved settings; **Turn Off** (or quitting the app) stops it. Nothing is lost
when it stops — a stopped server is just off, not broken.

---

## What you need first (one time)

1. **Claude Code**, installed and logged in with your Claude Pro/Max account:
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   claude          # log in via the browser once
   ```
2. **even-terminal**:
   ```bash
   npm install -g @evenrealities/even-terminal   # needs Node 18+
   which even-terminal                            # note this path for Settings
   ```
3. **Tailscale** on your Mac and phone (same account) — recommended, this is what
   makes "same server forever" true even off your home Wi-Fi.
4. **Xcode** (free, Mac App Store) — needed once, to build the app. Or just the
   command line tools: `xcode-select --install`.
5. Even Realities app updated (v2.2.1+), G2 + R1 ring firmware updated.

---

## Build & install it into /Applications

You have two ways. Both end with a real `EvenToggle.app` you drag into Applications.

### Way 1 — one command (recommended)

```bash
git clone https://github.com/YOUR-NAME/even-toggle.git
cd even-toggle
chmod +x scripts/*.sh
./scripts/build-app.sh
```

This compiles everything and produces `build/EvenToggle.app`. Then:

- Open the `build` folder in Finder, **drag `EvenToggle.app` into `/Applications`**.
- Double-click it. The 👓 appears in your menu bar. (No Dock icon — that's normal
  for a menu bar app.)

> Want a custom app icon? Drop a 1024×1024 PNG at `build/icon.png` before running
> the script and it'll be baked in.

### Way 2 — the Xcode GUI (if the script ever misbehaves)

1. Open Xcode → **File ▸ New ▸ Project ▸ macOS ▸ App**. Name it `EvenToggle`,
   Interface **SwiftUI**.
2. Delete the two files Xcode generated, then drag the five files from
   `Sources/EvenToggle/` into the project.
3. In the target's **General**, set **Minimum Deployments** to macOS 14.
4. In **Signing & Capabilities**, remove **App Sandbox** if present (the app
   launches a CLI and opens a folder picker, which the sandbox blocks).
5. In **Info**, add a row: **Application is agent (UIElement) = YES**.
6. Press ▶ to run. To make a standalone app: **Product ▸ Archive ▸
   Distribute App ▸ Custom ▸ Copy App**, then drag it to `/Applications`.

---

## First-time pairing (do this once)

The pairing QR code needs to be scanned once. Easiest is to run the server in a
normal Terminal a single time so you can see the QR:

```bash
even-terminal --tailscale --provider claude -t YOURTOKEN -p 3456 -d ~/path/to/project
```

On your phone: **Even Realities app ▸ Settings ▸ enable Terminal Mode ▸ Add host ▸
scan** the QR. Quit that terminal.

Now open **EvenToggle ▸ Settings**, and enter the **same** token and port (3456),
choose the same folder, keep Tailscale on. From here on, the app reuses that exact
config, so the host on your glasses keeps connecting — you never scan again.

---

## Daily use

1. Sit down at your Mac (awake + online). If Launch-at-Login is on, EvenToggle is
   already in the menu bar.
2. Click **👓 ▸ Turn On**.
3. Put the glasses on, enable **Terminal Mode** in the Even app, tap your saved
   host — your Claude Code session is on the HUD. Tap-and-hold to talk.
4. Done for the day? **👓 ▸ Turn Off** (or just quit).

---

## Settings explained

| Setting | What it does |
|---|---|
| **Pairing token** | Not stored by this app. even-terminal keeps it in `~/.even-terminal/config.json` (set it with `even-terminal config`); EvenToggle never passes it on the command line. |
| **Port** | The number the server listens on (default 3456). Keep it fixed. |
| **Use Tailscale** | Makes the address permanent so it works from anywhere and never needs re-pairing. |
| **Keep Mac awake** | Stops the Mac sleeping while the server runs (`caffeinate`). |
| **Project folder** | The folder Claude Code works in. **Choose…** opens the normal macOS folder picker. |
| **Model** | Which Claude model the glasses use. The app makes this the saved default for you (writes it to `~/.claude/settings.json` and sets `ANTHROPIC_MODEL`), so it works even though you can't type `/model` by voice. "Default" hands control back to Claude Code. Use **Custom…** for an exact id like `claude-opus-4-8`. Sonnet 5 needs Claude Code v2.1.197+ and Opus 4.8 needs v2.1.154+ — run `claude update` if a model won't take. |
| **Path to even-terminal** | Leave blank — the app auto-detects it from your shell. Only fill it in to override (find it with `which even-terminal`). |
| **Advanced log** | Shows the server's output, including the QR the first time. |

---

## "I broke it / reinstalled the app — how do I get back?"

This is the whole point of the fixed-token design:

- **Same token + same port + Tailscale on → the glasses host still works.** Just
  reopen Settings, re-enter those values, Turn On. No re-pairing.
- You only ever re-scan the QR if the **token changed** (e.g. you generated a new
  one) or the address changed (which Tailscale prevents). So: **write your token
  down.** That single string is your "always the same bridge."

---

## Troubleshooting

**First, run the doctor.** It checks everything and tells you what's wrong:

```bash
./scripts/doctor.sh
```

Then, whatever the app is doing, open **👓 ▸ Settings ▸ Advanced** and read the
log box — it states the actual reason. Common ones:

| Log says | Meaning | Fix |
|---|---|---|
| `env: node: No such file or directory` | The server can't find Node. Usually an nvm/Volta/asdf setup. | The app now auto-resolves your login shell's PATH, which normally fixes this. If it persists, run `./scripts/doctor.sh` and make sure `node` is found; reinstall even-terminal under your active Node with `npm install -g @evenrealities/even-terminal`. |
| `Couldn't find even-terminal` | The CLI isn't installed or isn't on your shell PATH. | `npm install -g @evenrealities/even-terminal`, or paste the output of `which even-terminal` into Settings ▸ Path to even-terminal. |
| `Set an auth token…` / `Choose a project folder…` | A required field is empty. | Fill it in in Settings. |
| Menu says Running, glasses won't connect | Phone can't reach the Mac. | Put phone + Mac on the **same Wi-Fi** (or set up Tailscale). Make sure the Mac is **awake**. Confirm the app's token/port match what you paired. |
| Claude Code opens in `/` or the wrong folder | The child process defaulted to root. | Fixed in the app by setting the working directory directly. Also make sure **Project folder** is set in Settings, then **Turn Off → Turn On** and start a **fresh** session (old sessions stay pinned to their original folder). |
| Model picker seems ignored | Older behavior: a saved default in `~/.claude/settings.json` outranked the env var. | The app now writes your picked model into `~/.claude/settings.json` on Turn On (and "Default" removes it), so the picker wins — including on the voice-only glasses. Just set it in the app, then Turn Off → Turn On. Don't use `/model` in Terminal afterward, as that re-saves a default. |
| Was working, now `env: node` after a Node upgrade | An nvm version bump moved Node. | Re-run `./scripts/doctor.sh`; reinstalling even-terminal under the new Node fixes it. |

### Why the "node not found" problem happens (background)

A Mac app launched from Finder does **not** inherit your Terminal's `PATH`. Tools
installed by nvm, Volta, asdf, fnm, or even Homebrew live in folders the app can't
see by default — so `node` and `even-terminal` look "missing" even though they work
fine in Terminal. EvenToggle handles this by asking your **login shell** for its
real PATH (exactly what Terminal uses) and launching the server with that. This is
why no manual symlinks or hardcoded paths are needed.

---

## Security notes

- The **token = remote shell** on your Mac via Claude's tools. Keep it secret;
  never commit it to git (it's only ever stored in the app's settings, not in
  this repo).
- Point the **project folder** at something you trust — that's the boundary of
  what the agent can touch.
- Prefer **Tailscale** over any public tunnel for anything left running.
- For stronger storage, move the token from app settings into the macOS
  **Keychain** (a natural next improvement).

---

## Roadmap ideas

- Multiple projects: a small list in Settings, launching one `even-terminal`
  instance per project on its own port (each shows as a separate host).
- A "connected / waiting" indicator by pinging the port.
- Keychain-backed token storage.

MIT licensed. Built to scratch an itch: Claude Code, on your face, one click away.
