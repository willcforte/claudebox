# claudebox — agent operating guide

Sandboxed Docker dev boxes for Claude Code in no-prompt auto-mode. One reusable Nix base image;
per-project profiles; a `claudebox` CLI. Design rationale: `spec/claudebox-design.md`. GPU/FHS
research: `.claude/research/nix-docker-cuda-gpu.md`.

## Architecture

```
bin/claudebox            bash CLI — build/up/attach/down/status; reads profiles/<name>/profile.toml
flake.nix                Nix flake; exports .#baseImage
nix/base-image.nix       dockerTools.buildLayeredImage — FHS CUDA base + Nix tooling
profiles/<name>/         profile.toml, devcontainer.json, [pixi/gpu-feature.toml]
templates/               project.toml.template + devcontainer.json.template
assets/                  banner script baked into the image
```

The CLI is the only user-facing entry point. It reads `profiles/<name>/profile.toml` (via `yq`)
and constructs the `docker run` args. No config file outside of profiles and `flake.nix`.

## Conventions

- **Commits:** Conventional Commits. Never self-attributed. Commit freely; **push only when the
  owner asks**.
- **Bash:** shellcheck-clean. `set -euo pipefail`. Comments only at file/definition head — no
  mid-implementation comments. Terse, self-documenting code.
- **Nix:** keep base image pin reproducible — digest + TOFU hash in `nix/base-image.nix`.
- **Profiles:** user/host-specific (absolute paths) and git-ignored. Don't commit real profiles; the
  `example` profile is the committed reference, not a template.

## Key gotchas

- **FHS base is required for NVIDIA GPU injection.** A pure `dockerTools` image (non-FHS) fails
  because the injected `nvidia-smi` and `libcuda.so` are host ELFs expecting
  `/lib64/ld-linux-x86-64.so.2`, which doesn't exist in a scratch Nix image. The fix is
  `fromImage = <nvidia/cuda FHS base>` in `buildLayeredImage`. See
  `.claude/research/nix-docker-cuda-gpu.md` for full analysis.
- **Runtime uid match + VS Code attach.** The box runs as `--user "$(id -u):$(id -g)"` (CLI) or
  `updateRemoteUserUID: true` (VSCode). `/home/dev` must be genuinely world-writable: a `chmod` in
  the `runCommand` store path is canonicalized back to root:root 0755 and silently does nothing, so
  it is set via `fakeRootCommands` in `buildLayeredImage`. For VS Code "Attach to Running Container"
  the runtime uid must *also* resolve to a named user — a nameless uid makes VS Code fall back to
  `/root` and fail (`mkdir: cannot create directory '/root'`). The CLI therefore generates a per-box
  `/etc/passwd`+`/etc/group` mapping the host uid to `dev` (home `/home/dev`) and binds them RO. Keep
  the uid out of the image (`$(id -u)` in the CLI), never a literal. Extensions auto-install on attach
  via the `devcontainer.metadata` image label (`nix/base-image.nix`) — no per-project
  `devcontainer.json` needed; settings come from `assets/vscode-machine-settings.json` (CLI-seeded).
  **The label must NOT set `remoteUser`.** On attach there is no `updateRemoteUserUID`, so a baked
  `remoteUser = "dev"` resolves (`docker exec -u dev`) to the *image's* baked dev uid (1000), not the
  host uid the CLI ran the box as. If the host uid differs (e.g. 1001) the VS Code server runs as
  1000 and cannot write the host-owned binds (workspace, `.claude`, `.vscode-server`) →
  `Permission denied`. With no `remoteUser`, VS Code attaches as the container's numeric `User` (the
  host uid), which owns those binds; the bound `/etc/passwd` still names it `dev`, so `/root` is
  avoided. The `devcontainer.json` "Reopen in Container" flow is the exception — it keeps
  `remoteUser: "dev"` because its `updateRemoteUserUID: true` remaps `dev` to the host uid there.
- **Per-box seeded `~/.claude.json`.** The CLI seeds `~/.cache/claudebox/<name>/claude.json`
  once from the host `~/.claude.json`, then binds it at `/home/dev/.claude.json`. This keeps the
  host and box from clobbering each other's hot config file while still giving Claude a valid
  starting config.
- **Auto-mode via system path.** `/etc/claude-code/managed-settings.json` sets
  `bypassPermissions` at the system level — it is inside the image, never touches `~/.claude`,
  and never leaks to the host. Do not implement auto-mode via `~/.claude`.
- **Pin the base by digest + TOFU hash.** Use `nix-prefetch-docker nvidia/cuda <tag>` to get
  both. Set `hash = pkgs.lib.fakeHash` to let Nix report the real hash on first build.
- **Build via `claudebox build`, not `docker build`.** The build path is
  `nix build .#baseImage` → `docker load < result`.
- **Headless GL (EGL/GLX) is an opt-in toggle, and needs two things beyond the device.** `--gpus all`
  passes the device, but the NVIDIA runtime injects the *graphics* userspace (`libEGL_nvidia`,
  `libGLX_nvidia`) only when `NVIDIA_DRIVER_CAPABILITIES` includes `graphics`. That alone is still
  insufficient: the glvnd dispatch loader (`libEGL.so.1`, e.g. from a project's pixi env) enumerates
  vendors via `/usr/share/glvnd/egl_vendor.d/*.json`, which the runtime does **not** inject — so the
  image bakes `10_nvidia.json` (pointing at `libEGL_nvidia.so.0`) in `rootfsSetup` unconditionally
  (inert without the caps + libs). Capabilities are composed from two per-profile booleans under
  `[gpu]` — `cuda` (default true → `compute,utility`) and `graphics` (default false → adds
  `graphics`) — and the CLI passes their union as `-e NVIDIA_DRIVER_CAPABILITIES=...` at `docker run`
  (one base image serves every mode; `gpu.passthrough` only attaches the device via `--gpus all`).
  The image bakes `compute,utility` as a standalone fallback for direct `docker run`. Symptom when
  graphics is off or a piece is missing:
  MuJoCo `MUJOCO_GL=egl` fails with "driver does not support the PLATFORM_DEVICE extension" /
  `eglInitialize` result 0, even though `nvidia-smi` works.

- **Pixi env auto-activates via `BASH_ENV`.** `pixi`'s `[activation.env]` (e.g. `PYTHONPATH=$PIXI_PROJECT_ROOT/src`)
  reaches a process only through an evaluated `shell-hook`. Interactive `.bashrc` alone misses Claude's Bash
  tool and VS Code tasks, which run non-interactive `bash -c` (no `.bashrc`). The image sets
  `BASH_ENV=/etc/claudebox/activate.sh` (read by non-interactive bash) and `.bashrc` sources the same script
  (interactive bash ignores `BASH_ENV`). The script evals `pixi shell-hook` from CWD, guarded by an exported
  `CLAUDEBOX_PIXI_ACTIVATED` set *before* the hook runs so bash spawned by pixi short-circuits (no recursion).
  No-op outside a pixi project. Existing boxes must be recreated (`claudebox down/up`) to pick this up.
  `pixi shell-hook` also defines a `pixi()` wrapper that calls `"$PIXI_EXE"`; Claude's Bash tool sources
  a shell *snapshot* that captures functions but not env vars, so without `PIXI_EXE` set the wrapper runs
  an empty command (exit 127) and its trailing `return 0` masks the failure (silent no-op `install` etc.).
  `PIXI_EXE=${pkgs.pixi}/bin/pixi` is therefore baked into `config.Env` (`nix/base-image.nix`) so it is
  always present, snapshot or not.

## Current state

Built and working: CLI, GPU base (nvidia/cuda:12.8.1-devel-ubuntu24.04), shell banner, example
profile (Rerun viz on ports 9090/9876, two RO data-repo mounts).
