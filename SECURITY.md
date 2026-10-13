# Security model

pitainer limits what the pi coding agent, and the commands it runs, can read,
change and contact. It is a personal sandbox, not a certified security product.

## What is enforced

| Guarantee | Mechanism |
|---|---|
| pi sees only configured folders | Only those folders are mounted. The launcher refuses the home folder, credential folders and its own files |
| All traffic leaves through one proxy | Default-drop firewall; only the `pxy` user may send packets off the container |
| pi reaches only allowed hosts | The proxy checks the hostname of each HTTPS CONNECT against the provider list and resolves it itself |
| Commands pi runs are offline | They run as `tools`, which the firewall gives no network, no DNS and no access to the proxy |
| The Mac and local network are unreachable | Private address ranges and the host gateway are rejected for every user, the proxy included |
| pi cannot change these rules | pi's settings are root-owned and immutable; firewall and immutability capabilities are dropped before pi starts |
| pi cannot be made to run code outside the offline shell | User extensions and MCP configuration are locked empty; `models.json` is frozen as imported |
| Project folders cannot reconfigure pi | `defaultProjectTrust: never` and `--no-approve`: project `.pi` settings and extensions are not loaded |
| Rules are in place before pi runs | The entrypoint fails closed and runs a self-test on every start |

`pitainer test` checks each of these inside a real container.

## What is not protected

- **Everything pi reads is sent to the model provider you chose.** That is how
  an agent works. Mount only what you are willing to send.
- **Mounted folders are fully writable** (unless `:ro`). An agent can delete or
  corrupt files there. Use git, and review changes before you commit.
- **A file changed in a mount can be dangerous when you later run it on the
  Mac**: a build script, a git hook, a Makefile. The container cannot protect
  the host from files you execute yourself.
- **Allowed hosts are a data channel.** Anything running as `pi` can send data
  to an allowed provider host. A provider host that serves other tenants on
  the same address (a shared CDN) cannot be told apart by hostname alone.
- **`pitainer deps` runs third-party install code** with write access to the
  mounts and network access to `deps_hosts`. Package indexes accept uploads,
  so treat that path as able to leak what it can read. It never has pi's
  credentials.
- **The pi process itself is trusted with its own credentials.** Code that
  manages to run as `pi` can read pi's saved logins. Its network is still
  limited to the provider list. A `!command` value in a `models.json` you
  import runs as `pi`; the launcher warns when it sees one.
- **Startup reachability is advisory.** If an allowed host is down, pi starts
  with a warning. Every refusal check is still enforced before pi starts.
- **System packages are not version-pinned.** Base images are pinned by digest
  and pi by checksum, but `apt-get install` takes the current Debian packages.
- **The source checkout guard is a guardrail, not a boundary.** If you run a
  tampered `./pitainer install` without reviewing it, it runs on your Mac.
- **Kernel or hypervisor escapes** are out of scope. Each Apple container is
  its own virtual machine, which is a strong boundary, but not a proven one.
- **DNS queries** from the proxy go to the configured public resolver.

## Not verified

- Providers that use a websocket transport through pi's `httpProxy` setting.
  Tested: HTTPS to Anthropic.
- Browser-callback sign-in flows. pi supports pasting the redirect URL or code.
- Providers other than Anthropic end to end. `providers.manual` entries for
  Bedrock, Vertex and GitHub Copilot are best effort.

## Loosening

Two config keys weaken a rule. Each prints a warning on every start.

- `allow_unsafe_mounts = yes` permits a mount the launcher normally refuses.
- `private_endpoint = ip:port` lets pi reach one address and port on a private
  network, for a self-hosted model server. Only that exact pair is opened, only
  to pi through the proxy; commands pi runs still have no route to it. The
  connection is whatever the server offers: plain HTTP is not encrypted by
  pitainer. Anything running as `pi` can send data there.

## Reporting

Open an issue describing the bypass and how to reproduce it.
