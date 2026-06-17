# claudebox

Reusable, sandboxed Docker dev boxes for running **Claude Code in no-prompt auto-mode** with GPU and
shared memory. The container is the security boundary, so Claude runs unattended without touching the
host. One reusable base image; one `claudebox` CLI; a thin profile per project.

Remote-in flow: **`wpc → ssh p20 → VSCode Dev Containers (or claudebox attach) → Claude + GPU + viz`**.

---

## Quickstart (on p20)

**One-time setup**

```bash
# put the CLI on PATH
ln -sf ~/dev/claudebox/bin/claudebox ~/.local/bin/claudebox      # ensure ~/.local/bin is on $PATH

# build the base image (Nix base + nvidia/cuda; slow first run, then cached)
claudebox build

# (VSCode only) drop the dev-container config into the project repo
cp ~/dev/claudebox/profiles/dynret/devcontainer.json ~/dynret/.devcontainer/devcontainer.json
```

**Each session — terminal**

```bash
claudebox up dynret          # start (or resume) the box
claudebox attach dynret      # shell in
# inside:
claude                       # auto-mode, sees your shared memory
```

**Each session — VSCode** (the primary flow)

1. On wpc: VSCode → Remote-SSH → p20
2. Open `~/dynret` → **Reopen in Container**
3. The box comes up (GPU + shared memory + auto-mode); work normally.

---

## Commands

| Command | Does |
|---|---|
| `claudebox build` | Build the Nix base image → `docker load` (`claudebox-base:latest`) |
| `claudebox up <project>` | Start the box, or resume it if it already exists (no `--rm`) |
| `claudebox attach <project>` | Open a shell in the box (`docker exec -it … bash`) |
| `claudebox down <project>` | Remove the box (state lives on the host, so nothing is lost) |
| `claudebox status` | List boxes (running + stopped) |

---

## How a box is wired

**Mounts** (defined in `profiles/<name>/profile.toml`; example is dynret):

| Host path | In box | Mode | Purpose |
|---|---|---|---|
| `/home/will/dynret` | same (1:1) | RW | the project repo (your live copy, not a clone) |
| `~/.claude` | `/home/dev/.claude` | RW | shared memory + auth (writeback to host) |
| `~/.cache/claudebox/<name>/pixi` | `/home/dev/.pixi` | RW | persisted pixi cache |
| `~/dev/persona_rl`, `~/dev/persona` | same (1:1) | RO | it1 robot model + BVH data dynret needs |

Nothing else of the host is visible.

- **Runs as your host uid/gid** — `--user "$(id -u):$(id -g)"` (CLI) / `updateRemoteUserUID` (VSCode).
  Nothing hardcodes a uid, so it's portable. (`whoami` may say *"I have no name!"* — harmless.)
- **Repo bound 1:1 at its host path** so Claude's project-memory slug matches the host and your
  existing memories resolve.
- **Auto-mode** is baked into the image at `/etc/claude-code/managed-settings.json`
  (`bypassPermissions`) — container-only, never shadows the bound `~/.claude` memory, never leaks to
  the host. Toggle the `~/.claude` bind itself via `[claude] bind` in the profile (default `true`).
- **Sandbox:** non-privileged, `--cap-drop ALL`, `--security-opt no-new-privileges`, **no docker
  socket**. (The VSCode config omits `--cap-drop` because VSCode needs caps to remap the user.)
- **GPU:** `--gpus all`. The base is FHS (`nvidia/cuda:12.8.1-devel-ubuntu24.04`) so the NVIDIA runtime
  injects the host driver + `libcuda`. PyTorch (cu128) brings its own CUDA runtime; the host supplies
  the driver. RTX 5090 / Blackwell (sm_120) needs CUDA ≥12.8 + torch ≥2.7.

---

## Durability — what survives a shutdown

All real state lives in **host bind mounts**, never in the container:

- **Container stopped/killed:** nothing lost; `claudebox up` resumes the same box.
- **p20 rebooted:** nothing lost; files are on p20's disk; `up` re-creates/resumes it.
- **Real loss only from:** p20 disk failure with **unpushed commits** (→ push to GitHub), or work
  saved to a container path that isn't a mount (→ keep work in the repo). The pixi env is rebuildable.

---

## Networking

- **Internet: yes** — default Docker bridge (NAT through p20). `claude`, `pixi install`, `git`,
  cuRobo's source `git clone` all work.
- **Tailscale:** the box is **not** a tailnet node. Viz still reaches the tailnet because the box
  publishes its ports on `0.0.0.0` and **p20's `tailscaled` serves them** — open
  `http://persona-0020-2:9090?url=rerun%2Bhttp%3A%2F%2Fpersona-0020-2%3A9876%2Fproxy` on wpc.

---

## Add a new project

```bash
cp templates/project.toml.template      profiles/<name>/profile.toml      # edit name/workspace/ports/mounts
cp templates/devcontainer.json.template profiles/<name>/devcontainer.json # edit name/ports/data mounts
# GPU projects: add a profiles/<name>/pixi/gpu-feature.toml and merge it into the project's pyproject.toml
claudebox up <name>
```

---

## Layout

```
bin/claudebox                 the CLI (build/up/attach/down/status)
flake.nix, nix/base-image.nix Nix tooling layered on the pinned FHS CUDA base
profiles/<name>/              profile.toml, devcontainer.json, pixi/gpu-feature.toml
templates/                    project.toml + devcontainer.json templates for new projects
spec/claudebox-design.md      full design rationale
.claude/research/             nix-docker-cuda-gpu.md — why the base is FHS, not pure Nix
```

## Notes

- **Git identity in-box:** only `~/.claude` is mounted, not `~/.gitconfig`, so commits made *inside*
  the box have no author. Add a `~/.gitconfig` mount to the profile if you commit from in-box.
- **cuRobo** has no cu128 wheel — install from source *after* `torch.cuda.get_device_name()` confirms
  the RTX 5090: `pixi run pip install --no-build-isolation git+https://github.com/NVlabs/curobo.git`.
- Updating the base CUDA image: change the digest in `nix/base-image.nix`, set `hash` to
  `pkgs.lib.fakeHash`, run `claudebox build` once, paste the reported hash back.
