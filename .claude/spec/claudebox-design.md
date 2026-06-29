# claudebox — design

Reusable, sandboxed devcontainer for running Claude Code in auto-mode. Remote-in flow:
`your laptop → ssh the GPU host → VSCode Dev Containers attach → Claude (auto-mode) + GPU + live viz`.
Claude is confined to the container; the host is untouched. First consumer: `~/dev/dynret`.

## Goal

- One reusable Nix base image; per-project profiles; a `claudebox` CLI to build/run/attach.
- **Portable** — nothing hardcodes a uid or username; works on any machine/user.
- Memory + project files **survive entering the box** (bind mounts + correct path/uid wiring).

## Components

1. **Nix base image** — `flake.nix` + `nix/base-image.nix`, `dockerTools.buildLayeredImage`.
   - Contents: claude-code, pixi, git, gh, ripgrep/fd/bat/etc., build glue (gcc/make/cacert).
   - Generic `dev` user (uid 1000), `/home/dev` world-writable. **No hardcoded host uid.**
   - Bakes `/etc/claude-code/managed-settings.json` = `{"permissions":{"defaultMode":"bypassPermissions"}}`
     — container-only auto-mode (system path, NOT `~/.claude`), so it never shadows bound memory
     and never leaks to the host. Fallback: `claude --dangerously-skip-permissions`.
   - CUDA/torch/cuRobo are **absent** — they install in the pixi layer inside the container.
2. **`claudebox` CLI** — one bash script, `bin/claudebox`. Subcommands:
   - `build` → `nix build .#baseImage` → `docker load`.
   - `up <project>` → start the box (wiring below). **Fully non-interactive** — resumes an existing box,
     or creates one (no `--rm`, so an accidental stop / host reboot just resumes; no commands needed).
   - `attach <project>` → `docker exec -it <project> bash`.
   - `down <project>` → remove the box. `status` → list boxes (running + stopped).
   - Reads `profiles/<project>/profile.toml` (via `yq`).
3. **Per-project profile** — `profiles/<name>/`:
   - `profile.toml` — image, workspace host path, ports, gpu flag, RO data mounts, `[claude] bind`
     (default true; binds host `~/.claude` RW — **a setting, never a prompt**).
   - `pixi/gpu-feature.toml` — CUDA≥12.8 / torch cu128 / cuRobo overlay to merge into the project
     `pyproject.toml` (adds a `gpu` pixi environment).
   - `devcontainer.json` — VSCode config (copy to `<repo>/.devcontainer/`).
4. **Templates** — generic `project.toml` + `devcontainer.json` for new projects.

## Wiring (portable)

- **uid:** `--user "$(id -u):$(id -g)"` (CLI) / `updateRemoteUserUID: true` (VSCode). Never a literal uid.
  CLI keeps `--cap-drop ALL`; the VSCode config omits it (uid remap at setup needs caps).
- **repo:** bind **1:1 at its host path** (`source==target`). The project-memory slug derives from the
  workspace path, so 1:1 makes the in-box slug match the host (`-home-<user>-dynret`) → existing memories resolve.
- **`~/.claude`:** bind **RW** at the container HOME (`${HOME}/.claude → /home/dev/.claude`). Same bytes as host
  → memory present; RW → Claude writes session/memory back and shares across boxes + host.
- **pixi cache:** bind `~/.cache/claudebox/<project>/pixi → /home/dev/.pixi` (host-owned → writable under the
  matched uid; persisted across respins).
- **data (dynret):** RO binds of two related repos (`~/dev/data-repo-a`, `~/dev/data-repo-b`), **1:1**
  so the project's absolute paths (e.g. `configs/*.local.toml`) resolve unchanged.
- **sandbox:** `--cap-drop ALL`, `--security-opt no-new-privileges`, **no docker socket**, non-privileged.
- **GPU:** `--gpus all` (host nvidia runtime injects the driver; image ships CUDA toolkit only via pixi).
- **viz:** publish `9090`/`9876` on `0.0.0.0`; in-box Rerun binds `0.0.0.0` → the host's tailscaled serves the tailnet.

## Memory survival (the durability requirement)

Bind mounts are the same files on disk — there is no clone, nothing is lost. The repo working tree
(committed or not) and all of `~/.claude` (incl. `projects/-home-<user>-dynret/memory/`) are present in-box.
1:1 workspace path → Claude finds the right project memory. RW → updates propagate back. (Git commit/push
remains a separate backup/history concern, not the transition mechanism.)

## Durability (restart / shutdown)

All state lives in HOST bind mounts (repo, `~/.claude`, pixi cache) — never in the container.

- **Container stopped/killed:** no loss; `claudebox up` resumes the same box (no `--rm`).
- **Host rebooted:** no loss; files are on the host's disk. `claudebox up` re-creates/resumes the box.
- **Real loss vectors:** host disk/hardware failure with **unpushed commits** (→ push to GitHub), or work
  saved to a container path that isn't a mount (→ keep work in the mounted repo). The pixi env is rebuildable.

## First consumer: dynret

GPU on; ports 9090/9876; two RO data repos. cuRobo (no cu128 wheel) is the main risk → gate on
`torch.cuda.get_device_name()` → `RTX 5090` before any cuRobo integration; cuRobo left commented in the overlay.

## Verify

1. `claudebox build` → image builds, loads (`claudebox-base:latest`).
2. `claudebox up dynret && claudebox attach dynret`.
3. In-box: `nvidia-smi` → RTX 5090; `pixi run -e gpu python -c "import torch; print(torch.cuda.get_device_name())"` → RTX 5090.
4. In-box: `claude` starts in auto-mode and sees the dynret memory.
5. Rerun serves to your laptop over the tailnet.

## Out of scope

gh/x11 overlays, multi-user, host-specific data paths, cuRobo source-build (separate task), pushing repos,
per-box branch isolation (would use git worktrees).
