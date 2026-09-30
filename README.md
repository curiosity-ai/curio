# curio

The command line shell for [Curiosity Studio](https://curiosity.ai/studio/): the sandbox Sudo, the
admin assistant, works in, from your terminal.

**Website: [curiosity.sh](https://curiosity.sh)** · Releases: [GitHub releases](https://github.com/curiosity-ai/curio/releases)

```bash
dotnet tool install --global Curiosity.Shell
curio
```

The first run asks for the workspace address, opens the browser to sign you in (any login the
workspace supports, SSO included) and drops you into the two-panel interface. It needs a system
administrator account.

### Without the .NET SDK

Every [release](https://github.com/curiosity-ai/curio/releases) carries self-contained single files:

| Platform | Asset |
|---|---|
| Windows x64 | `curio-win-x64.exe` |
| Linux x64 | `curio-linux-x64` |
| macOS Apple silicon | `curio-osx-arm64` |
| macOS Intel | `curio-osx-x64` |

The executable bit does not survive a GitHub release download, so on Linux and macOS:

```bash
chmod +x curio-linux-x64 && mv curio-linux-x64 ~/.local/bin/curio
```

## Model

- A curio **session** is a Sudo conversation with its own sandbox. It is listed in the admin dock,
  and a dock session is listed in curio.
- `/workspace` is the workspace configuration as files: endpoints, AI tools, agents, schemas,
  scheduled tasks, and so on. Next to it: `/reference`, `/docs`, `/sdk`, `/proc`, `/frontend`.
- Edits stay in the session. `build` checks them against the workspace, `commit` stages them, and
  nothing is applied until the commit is approved. Same diff, same approval as the dock.

## Commands

Every panel action is also a command, for scripts, CI and coding agents:

```
curio login [--server URL] [--store auto|keyring|file|none] [--no-browser] [--approve|--no-approve]
curio logout | whoami
curio sessions [list | new [name] | use <id|name> | rename <name> | rm | reset | stop]
curio run -- <command line>        curio run -f script.sh    (exit code passed through)
curio status | diff
curio commit [show | approve | discard]
curio ls [path] | cat <path> | get <path> [local] | put <local> <path> | rm [-r] <path>
curio upload <files...>
curio skills [list [--all] | search <words> [-n N] | show <name> | install [folder] [--global] [--force]]
```

`--server` and `--session` work on every command.

| Exit code | Meaning |
|---|---|
| sandbox command's own | `curio run` |
| 64 | usage error |
| 75 | conflict (the file changed since you read it) |
| 77 | not signed in |
| 78 | not allowed |

A typical edit loop:

```bash
curio sessions new fix-search
curio get /workspace/code/endpoints/search-orders.cs .
$EDITOR search-orders.cs
curio put search-orders.cs /workspace/code/endpoints/search-orders.cs
curio run -- build
curio run -- commit
curio commit approve
```

## Interface

```
┌ curio  https://acme.curiosity.ai  |  admin  |  session: fix-search  |  2 changed ────────────┐
╔╡ sandbox:/workspace/code/endpoints ╞════════╗╔╡ local:/home/me/defs ╞══════════════════════╗
║  /..                                        ║║  /..                                        ║
║M search-orders.cs         2.1K 09-29 12:04  ║║  notes.md                   1.2K 09-28 17:10║
║A export-invoices.cs        812 09-29 12:10  ║║  search-orders.cs           2.0K 09-29 11:58║
╚═════════════════════════════════════════════╝╚═════════════════════════════════════════════╝
/workspace/code/endpoints$ build
 1Help 2Sessions 3View 4Edit 5Copy 6Move 7Mkdir 8Delete 9Changes 10Quit
```

| Key | Action |
|---|---|
| Tab | switch panel (on the command line: complete) |
| Enter / Backspace | open / parent directory |
| Space, Ins, Ctrl+A | mark files |
| F2 | sessions: switch, create, rename, delete |
| F3 / F4 | view / edit; a save is refused if the file changed since you opened it |
| F5 / F6 | copy / move to the other panel, local and sandbox both ways. Copying into `/home/uploads` attaches the file to the conversation |
| F7 / F8 | make directory / delete |
| Alt+F7 | find text under the current sandbox directory |
| F9 | changes: diff, build, commit, approve (with the apply log), discard, pull, revert |
| Ctrl+O | console output |
| Ctrl+L | switch the panel between the sandbox and this computer |
| Ctrl+U / Ctrl+R | swap panels / refresh |
| F10, Ctrl+Q | quit |

Typing anywhere starts a command. It runs in the sandbox, in the active sandbox panel's directory
(`help` lists them: `build`, `commit`, `graph`, `query`, `type`, `uid`, ...).

## Coding agents

curio is a plain command line, so any agent that can run a shell command can work on a workspace
through it. The agent gets a session and nothing more: its edits wait in the sandbox until a
person approves them.

Sudo's skills (built-in and the workspace's own) stay on the workspace:

```
curio skills list [--all]          what there is (--all adds the ones that travel with another skill)
curio skills search <words>        which skills mention them, best first, with the passage
curio skills show <name>           one skill, as Sudo reads it
```

`curio skills install` writes one `curio` skill into an agent's skills folder: how to work through
curio, an index of Sudo's skills, and the commands to read one on demand. Nothing else is copied,
so the agent always reads the version the workspace runs. Re-run it to refresh the index; a copy
edited by hand is kept unless you pass `--force`.

| Harness | Setup |
|---|---|
| Claude Code | `curio skills install` (`.claude/skills/curio/SKILL.md`), or `--global` for `~/.claude/skills` |
| OpenAI Codex | `curio skills install ./.agents`, then reference it from `AGENTS.md` |
| Mistral Vibe | `curio skills install ./.agents`, then reference it from the project instructions |
| Anything else | `curio skills show curio` prints the same instructions |

## Approving changes

Signing in asks whether curio may approve and apply a staged commit by itself. The checkbox on
the sign-in page decides.

- **Allowed:** `curio commit approve` and Approve in F9 apply the commit and stream the apply log.
- **Not allowed (default):** approving opens the commit on Sudo's review screen in the browser
  (`#/manage/assistant?chatUID=…&review=…`) and curio waits for the approve or discard. The
  workspace enforces this: that curio's session token is refused by the approve routes, including
  after renewal.

Sign in again to change it.

## Authentication

`curio login` runs the OAuth loopback flow with PKCE: curio listens on `127.0.0.1`, the workspace's
`#/manage/connect-cli` page asks you to confirm, and the browser returns a one-time code that is
useless without the verifier curio kept. curio stores a refresh token in:

- the OS keyring: Windows Credential Manager, macOS Keychain, or Secret Service (libsecret) on
  Linux; or, when none is available (containers, SSH sessions),
- `~/.curiosity/curio/credentials.json`, readable only by you.

The token is listed under **Manage > Tokens** as "curio on user@machine". Revoking it there, or
`curio logout`, signs curio out.

## Environment variables

| Variable | Effect |
|---|---|
| `CURIOSITY_SERVER` | workspace address; with `CURIOSITY_TOKEN`, nothing is stored (CI) |
| `CURIOSITY_TOKEN` | session token to use instead of the stored login |
| `CURIO_SESSION` | session to use |
| `CURIO_TRANSPORT=sse` | force the server-sent events fallback instead of the WebSocket |
| `CURIO_NO_INTRO=1` | skip Sudo's entrance when the interface opens |
| `CURIO_SCREENSAVER_SECONDS` | idle delay before the screensaver; `0` turns it off |

## Transport

curio keeps a WebSocket open to the session (`/api/admin-agent/sessions/{id}/ws`). Commands go
over it, and every change to the session comes back over it: Sudo editing files in the dock, a
commit being staged, an approval in the browser. The header shows `live`. If a proxy blocks
WebSockets, curio falls back to server-sent events for changes and plain HTTP for commands, and
the header shows `live (sse)`.
