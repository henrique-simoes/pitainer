# pitainer: run the pi coding agent in a sandbox on your Mac

**pitainer** runs the [pi coding agent](https://github.com/earendil-works/pi)
inside an [Apple `container`](https://github.com/apple/container) instead of
directly on macOS. The AI agent gets a locked-down Linux sandbox: it can edit
the project folders you pick and talk to the model provider you pick, and that
is all. No Docker Desktop needed.

If you want an AI coding agent to work on your code without giving it your
whole Mac, your network and your credentials, this is for you.

```bash
cd ~/code/my-project
pitainer
```

## Why use it

Running a coding agent directly on your Mac means it runs with your account:
your files, your SSH keys, your network. pitainer narrows that down.

| Without pitainer | With pitainer |
|---|---|
| pi can read your whole home folder | pi sees only the folders you list |
| Commands pi runs can reach any website | Commands pi runs have no network at all |
| pi can reach devices on your home network | Your Mac and local network are blocked |
| Node, pi and toolchains installed on macOS | Everything lives in the container |
| A background VM uses memory all day (Docker Desktop) | Nothing runs when pi is closed |

It also works with **your own model server**: a llama.cpp or other
OpenAI-compatible endpoint on your home network, VPN or Tailscale tailnet.

pi itself is unmodified: no extensions, patches or forks.

Read [SECURITY.md](SECURITY.md) before trusting it with anything important. It
says plainly what is protected and what is not.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Everyday use](#everyday-use)
- [Configuration reference](#configuration-reference)
- [Your own model server (llama.cpp and others)](#your-own-model-server)
- [Good to know](#good-to-know)
- [Questions and answers](#questions-and-answers)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)

## How it works

Each `pitainer` run starts a small Linux virtual machine with four users:

| User | What runs as it | Network |
|---|---|---|
| `pxy` | a small allow-list proxy | the internet, HTTPS only |
| `pi` | pi | the proxy, model-provider hosts only |
| `deps` | dependency installs you start | the proxy, package hosts only |
| `tools` | every command pi launches | none |

A firewall enforces that table. It is set up before pi starts, checked on every
start, and cannot be changed from inside. If any check fails, pi does not start.

## Requirements

- A Mac with Apple silicon, running macOS 26 or later
- Apple `container` 1.5.0 or later

## Install

### 1. Apple `container`

Skip this if `container --version` already works.

Download the signed installer:

```bash
curl -L -o ~/Downloads/container-installer.pkg https://github.com/apple/container/releases/download/1.5.0/container-1.5.0-installer-signed.pkg
```

Confirm Apple signed it:

```bash
pkgutil --check-signature ~/Downloads/container-installer.pkg
```

Install it (asks for your password):

```bash
sudo installer -pkg ~/Downloads/container-installer.pkg -target /
```

Start the service, and answer yes when it offers the default Linux kernel:

```bash
container system start
```

### 2. pitainer

Clone this repository, read the scripts if you like, then run:

```bash
./pitainer install
```

That puts the command at `~/.local/bin/pitainer` and creates your config at
`~/.config/pitainer/pitainer.conf`. Make sure `~/.local/bin` is on your `PATH`.

### 3. Configure

Open `~/.config/pitainer/pitainer.conf` and set the two required lines:

```
mount = ~/code
providers = anthropic
```

`mount` is a folder pi may work in. `providers` is who pi may talk to. To see
exactly what your config allows:

```bash
pitainer config
```

### 4. Build and check

Build the image (a few minutes the first time):

```bash
pitainer build
```

Run the tests against your own config. The last line should be
`ALL TESTS PASSED`:

```bash
pitainer test
```

## Everyday use

Go to a project inside one of your mounted folders and start pi:

```bash
pitainer
```

The first time, type `/login` inside pi and sign in to your provider. Your
login is stored in the container, not on your Mac.

Anything after `--` is passed to pi:

```bash
pitainer -- --model sonnet
```

**Git stays on your Mac.** pi edits files, but the container has no git
credentials and no network for `git push` or `git pull`. Commit and push
yourself, after reviewing what changed.

### Installing project dependencies

Because pi's commands are offline, `pip install` fails inside pi. Install
packages yourself, from the project folder:

```bash
pitainer deps
```

This creates a virtual environment for the project inside the container and
installs from `requirements.txt` or `pyproject.toml`. It can reach only the
hosts in `deps_hosts`. From then on, pi's commands use that environment.

To run any other install command:

```bash
pitainer deps -- pip install pytest
```

It works whether or not a pi session is open.

## Configuration reference

All settings go in `~/.config/pitainer/pitainer.conf`, one `key = value` per
line. The file is read as data and never executed.

| Key | What it does | Default |
|---|---|---|
| `mount` | A folder pi may see, at `/work/<folder name>`. Repeat for more. Add `:ro` for read-only | required |
| `providers` | `all`, or names such as `anthropic openai` | required |
| `memory` | Memory limit, such as `1g` or `512m` | `1g` |
| `cpus` | Number of CPUs | Apple's default |
| `toolchains` | Languages added to the image, such as `python-3.14` | none |
| `deps_hosts` | Hosts `pitainer deps` may reach | none |
| `extra_hosts` | Extra public hosts pi may reach | none |
| `private_endpoint` | `ip:port` of a model server on your own network | none |
| `env` | Environment variables to hand to pi, if set on your Mac | none |
| `dns` | Public DNS server the proxy uses | `1.1.1.1` |

[profiles/python.conf](profiles/python.conf) is a complete working example.

Some folders are always refused as mounts: your home folder, `~/.ssh` and other
credential folders, `~/Library`, and pitainer's own files.

### Model providers

`providers = all` allows every provider that the pinned pi version ships. A
list such as `providers = anthropic openai` allows only those. The host names
come from pi itself and are recorded in [providers.lock](providers.lock).

If a provider will not connect, see what the proxy refused:

```bash
pitainer denied
```

Then add the missing host to `extra_hosts`.

### Your own model server

A model server on your home network or VPN is blocked by default, like
everything else on a private network. Two steps open it.

**1. Allow the address.** Add its IP and port to your config:

```
private_endpoint = 100.64.0.5:8080
```

pi can then reach that one address and port, and nothing else on that network.
pitainer prints a reminder each time it starts. Your Mac's own address is never
allowed.

**2. Tell pi about the model.** Copy one of the examples, edit it, and import
it:

- [examples/llama-cpp.models.json](examples/llama-cpp.models.json): a plain
  llama.cpp server
- [examples/llama-cpp-thinking.models.json](examples/llama-cpp-thinking.models.json):
  a model with switchable thinking and effort levels

```bash
pitainer models import my-models.json
```

What to change in the example:

| Field | Where to find the right value |
|---|---|
| `baseUrl` | your server's address, ending in `/v1` |
| `id` | the model name from `http://<server>/v1/models` |
| `contextWindow` | `n_ctx` from that same response |
| `maxTokens` | the longest reply you want; thinking shares this budget |
| `thinkingLevelMap` | the effort names your model's chat template accepts; `null` marks a level it does not |

For a thinking model, check its chat template (`http://<server>/props`) for
`enable_thinking` and `reasoning_effort` before using the second example. Start
`llama-server` with `--jinja` so tool calling works.

To see what is currently imported:

```bash
pitainer models
```

### Your pi preferences

pi's settings file is read-only inside the container, so changes made with
`/settings` do not stick. Put preferences such as theme, default model or
thinking budgets in `~/.config/pitainer/settings.json` on your Mac, using pi's
normal settings format. pitainer's own security settings always win.

### Languages and tools

The base image has Node and git only. Add more with `toolchains`:

```
toolchains = python-3.14
```

Then run `pitainer build` again. To add your own, write a Containerfile
fragment at `~/.config/pitainer/toolchains/<name>.Containerfile` and name it in
`toolchains`. See [toolchains/python-3.14.Containerfile](toolchains/python-3.14.Containerfile)
for the shape.

## Good to know

- **One session at a time.** A second `pitainer` refuses to start while one is
  open.
- **No pi extensions or MCP servers.** Both are switched off inside the
  container, because they would run outside the offline shell.
- **Builds made inside are Linux builds.** A `node_modules` or virtual
  environment created in the container will not run on macOS, and the reverse.
- **1 GB can be tight** for a large test suite. Raise `memory` if a command is
  killed.
- **Everything pi reads goes to your model provider.** Mount only what you are
  willing to send.

## Updating pitainer

Pull the latest changes, look over what changed, then install again:

```bash
./pitainer install
```

The installed copy is the one that runs. A clone that sits inside a mounted
folder refuses to run directly, since pi could have edited it. Installing again
is your moment to review.

## Upgrading pi

The pi version is pinned in `Containerfile`, along with its checksum. To move
to a newer pi, in a clone you have reviewed:

1. Change `PI_VERSION` and `PI_INTEGRITY` in `Containerfile`.
2. Run `PITAINER_DEV=1 ./pitainer update-providers`.
3. Read `git diff providers.lock`. These are the hosts pi gains or loses.
4. Commit, run `./pitainer install`, then `pitainer build`.

A build stops if pi's provider hosts do not match `providers.lock`, so a pi
upgrade can never widen network access without you seeing it.

## Questions and answers

**Do I need Docker to run pi in a container on a Mac?**
No. pitainer uses Apple's own `container` tool, which starts a small virtual
machine per container and stops it when you quit. There is no always-on
background VM.

**How much memory does it use?**
The container is capped at 1 GB by default (`memory` in the config) and uses
nothing once pi is closed.

**Can the AI agent access the internet?**
pi itself can reach only the model-provider hosts you allow. The commands it
runs (shell, git, `pip`, `curl`, test runners) cannot reach anything.

**Can the agent read my SSH keys, browser data or other files?**
No. Only the folders you list are mounted. Your home folder and credential
folders are refused even if you ask for them.

**Can I use a local model, such as llama.cpp on another machine?**
Yes. Allow its address with `private_endpoint` and import a `models.json`. See
[Your own model server](#your-own-model-server). llama.cpp is tested; other
OpenAI-compatible servers (Ollama, vLLM, LM Studio) use the same pi settings
but have not been tried here.

**Can I run the model inside the container?**
Not practically. The container has no GPU access and a small memory cap. Run
the model server elsewhere and point pi at it.

**How do I install Python packages if pi is offline?**
Run `pitainer deps` yourself. It can reach only the package index.

**Does it work on Intel Macs, Linux or Windows?**
No. Apple `container` needs Apple silicon and macOS 26 or later.

**Which pi version does it run?**
The one pinned in `Containerfile`, verified by checksum. See
[Upgrading pi](#upgrading-pi).

## Troubleshooting

| Problem | What to do |
|---|---|
| `no config at ...` | Run `./pitainer install`, then edit the config |
| `the container service is not running` | Run `container system start` |
| `refusing to mount ...` | Choose a folder that is not your home folder or a credentials folder |
| `this copy lives in ...` | You ran the clone directly. Use the installed `pitainer` command |
| `a pitainer session is already running` | Quit the other session first |
| A provider will not connect | Run `pitainer denied` and add the host to `extra_hosts` |
| `pip install` fails inside pi | Expected. Use `pitainer deps` |
| pi starts with a "not reachable right now" warning | That host is down or you are offline; pi still starts |

## Uninstall

Remove the command, the installed copy and your config:

```bash
rm -rf ~/.local/share/pitainer ~/.local/bin/pitainer ~/.config/pitainer
```

Remove pi's logins, sessions and installed project packages:

```bash
container volume delete pitainer-agent pitainer-deps
```
