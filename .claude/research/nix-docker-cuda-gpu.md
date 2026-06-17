# NVIDIA GPU in a Nix `dockerTools` (non-FHS) image — ranked recommendations

Research date: 2026-06-17. Host context: Docker 29.5.2, NVIDIA Container Toolkit 1.17.8,
driver 580, RTX 5090 (Blackwell, sm_120, needs CUDA >= 12.8). Goal: PyTorch (pixi/conda
inside) uses the GPU. Failure observed: injected `/usr/bin/nvidia-smi` dies with
`exec: no such file or directory`.

## Why it fails (root cause)

The NVIDIA Container Toolkit/runtime injects host driver files (incl. `nvidia-smi`,
`libcuda.so.1`) into the container at start. The injected `nvidia-smi` is a **host ELF binary
whose interpreter is the absolute path `/lib64/ld-linux-x86-64.so.2`**. A `dockerTools`
image is non-FHS: that path does not exist, so `execve` returns ENOENT, which the kernel/Docker
surface as `exec ...: no such file or directory`. This is a missing-loader error, not a
missing-file error. Canva hit exactly this: *"nvidia-smi binary uses an absolute path reference
to this linker file we failed to provide"*
(https://www.canva.dev/blog/engineering/supporting-gpu-accelerated-machine-learning-with-kubernetes-and-nix/).
Same class of bug as nixpkgs#78739 (open since 2020): nvidia-docker on a dockerTools image
fails to exec `nvidia-smi` (https://github.com/NixOS/nixpkgs/issues/78739).

Key relief for your case: **PyTorch wheels (pip/conda/pixi) bundle their own CUDA runtime
(cudart, cuDNN, NCCL, cuBLAS).** The only thing PyTorch needs from the host is `libcuda.so.1`
(the driver stub), which the toolkit injects. You do **not** need a working `nvidia-smi`, nor
host CUDA toolkit, nor `cudaSupport=true` in Nix for PyTorch to use the GPU — you need (a)
`libcuda.so.1` injected and findable, and (b) the ELF loader present so any injected/host-linked
binary can run. Canva confirms PyTorch bundles CUDA/cuDNN while TF/JAX do not
(same blog).

---

## Ranked recommendations

### 1. (BEST for your constraints) Layer Nix onto an FHS base via `dockerTools` `fromImage`

Use an official `nvidia/cuda:12.8.x-cudnn-runtime-ubuntu24.04` (or `pytorch/pytorch:*-cuda12.8-*`)
image as the base and add your pixi/Nix tooling on top. The base provides `/lib64/ld-linux-x86-64.so.2`,
`ldconfig`, `/usr/lib`, glibc — so toolkit injection "just works" exactly as it does for any
normal CUDA image, and Blackwell/sm_120 is handled by the base's CUDA 12.8 stack.

```nix
let
  base = dockerTools.pullImage {
    imageName = "nvidia/cuda";
    imageDigest = "sha256:<pin-the-digest>";   # pin for reproducibility
    finalImageTag = "12.8.1-cudnn-runtime-ubuntu24.04";
    sha256 = "<nix-prefetch-docker output>";    # nix-prefetch-docker nvidia/cuda <tag>
  };
in dockerTools.buildLayeredImage {
  name = "claudebox-gpu";
  fromImage = base;          # FHS base; your Nix layers go on top
  contents = [ pixi /* ...tools... */ ];
  config.Env = [ "NVIDIA_DRIVER_CAPABILITIES=compute,utility" "NVIDIA_VISIBLE_DEVICES=all" ];
}
```

- Pin the base with `nix-prefetch-docker nvidia/cuda <tag>` to get `imageDigest` + `sha256`
  (reproducible; the manual also warns against `created = "now"` —
  https://github.com/NixOS/nixpkgs/blob/master/doc/build-helpers/images/dockertools.section.md).
- `pullImage` + `fromImage` is the documented, supported pattern; nixpkgs#78739 itself layered
  on `nvcr.io/nvidia/pytorch` this way.
- Robustness: highest. You inherit a battle-tested FHS CUDA userland; toolkit injection,
  `--gpus all`, and CDI all behave normally. Lowest fragility for "can't easily iterate."
- Cost: larger image, less "pure Nix." But it removes the entire non-FHS failure surface.
- Blackwell: pick a base with CUDA >= 12.8 (e.g. `nvidia/cuda:12.8.*` or
  `pytorch/pytorch:2.7.0-cuda12.8-*` / newer; PyTorch >= 2.7.0 ships sm_120 wheels —
  https://docs.salad.com/container-engine/tutorials/machine-learning/pytorch-rtx5090).

### 2. (BEST pure-Nix path; production-proven) Add FHS shims to the `dockerTools` image

Keep `FROM scratch` (pure Nix) but patch in the three things the toolkit's injection assumes.
This is exactly what Canva runs in production for GPU ML on EKS (CUDA 11.2), and what the
Discourse thread + Seán Murphy's CI images do. The fixes:

1. **ELF loader at the FHS path** — symlink the dynamic linker so injected/host binaries exec:
   ```nix
   extraCommands = ''
     mkdir -p lib64
     ln -s ${glibc.out}/lib64/ld-linux-x86-64.so.2 lib64/ld-linux-x86-64.so.2
   '';
   ```
   (Discourse: `ln -s ${glibc.out}/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2` —
   https://discourse.nixos.org/t/how-to-use-dockertools-buildlayeredimage-and-cuda/14593;
   Canva: included `/lib64/ld-linux-x86-64.so.2` symlinked to standard location.)

2. **`/tmp` (mode 1777)** — the runtime needs it to stage injected libs:
   ```nix
   # in buildLayeredImage use fakeRootCommands / enableFakechroot, or in buildImage runAsRoot:
   mkdir -p tmp && chmod -R 1777 tmp
   ```
   (Seán Murphy used `fakeRootCommands` with `mkdir -p tmp; chmod 1777 tmp`; Canva also created
   `/tmp` — https://seanrmurphy.medium.com/building-cuda-images-on-github-runners-with-nix-9b5daa2f6f92.)

3. **`LD_LIBRARY_PATH` pointing at the injection dir** so the loader finds `libcuda.so.1`:
   ```nix
   config.Env = [
     "NVIDIA_VISIBLE_DEVICES=all"
     "NVIDIA_DRIVER_CAPABILITIES=compute,utility"  # MUST be set or libs are not mounted
     "LD_LIBRARY_PATH=/usr/lib64"                   # where the runtime mounts host driver libs
   ];
   ```
   (Working example sets `LD_LIBRARY_PATH=/usr/lib64/` + the two NVIDIA_* vars —
   /tmp/nix-cuda-docker-example/buildCudaImage.nix; Canva extended `LD_LIBRARY_PATH` to include
   `/usr/lib64`; `NVIDIA_DRIVER_CAPABILITIES` being absent is why libs silently aren't mounted.)

Footguns / caveats:
- The injection mount path is version/mode-dependent. With **CDI** (now the default in toolkit
  1.17+, https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/release-notes.html)
  driver libs may land under `/usr/lib/x86_64-linux-gnu/...` rather than `/usr/lib64`. Confirm
  the actual path inside a running container (`find / -name 'libcuda.so*'`) and set
  `LD_LIBRARY_PATH` accordingly. Multiple reports show CDI not configuring the legacy search
  paths, fixed only by adding the right dir to `LD_LIBRARY_PATH`
  (https://github.com/NVIDIA/nvidia-container-toolkit/issues/1456;
  https://github.com/NixOS/nixpkgs/issues/366109).
- No `ldconfig`/`ld.so.cache` in a Nix image, so `dlopen("libcuda.so.1")` relies on
  `LD_LIBRARY_PATH` (or rpath) rather than the cache — hence (3) is mandatory, not optional.
- For PyTorch you can skip Nix `cudaSupport`/`cudatoolkit` entirely (pip/conda wheels bundle
  CUDA); that avoids >1GB of redundant libs (Discourse + Canva both note pre-built wheels make
  `cudatoolkit` redundant).
- Robustness: proven at Canva scale, but you are reproducing runtime-internal assumptions that
  drift across toolkit versions (notably the legacy->CDI default switch). More fragile to
  upgrades than option 1.

### 3. CDI device mode explicitly (orthogonal to FHS; pair with option 1 or 2)

CDI is the modern, declarative injection path and the default for toolkit 1.17+
(https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/release-notes.html).
It does **not** fix the non-FHS loader problem by itself — CDI still mounts host ELF binaries
that need `/lib64/ld-linux-x86-64.so.2`. Its value is reproducible, inspectable injection:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml   # regenerate after driver updates
docker run --device nvidia.com/gpu=all <image>               # or --gpus all on 1.17+
```

- The generated spec lists exactly which driver libs/symlinks (incl. `libcuda.so.1` and a
  `libcuda.so` symlink) get mounted and where — read `/etc/cdi/nvidia.yaml` to learn the real
  in-container path and set `LD_LIBRARY_PATH` to match (DeepWiki CDI overview:
  https://deepwiki.com/NVIDIA/nvidia-container-toolkit/3.2-container-device-interface-(cdi)).
- Known regression: containers that worked in legacy mode broke after the CDI default switch in
  1.18.0 because lib search paths changed; fix is adding the path to `LD_LIBRARY_PATH`
  (https://github.com/NVIDIA/nvidia-container-toolkit/issues/1456). You are on 1.17.8 (CDI is
  default but pre-1.18), so legacy is still available as a fallback via
  `--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all`.
- Caveat: regenerate the CDI spec after every host driver update or the spec points at a stale
  driver version (https://github.com/NixOS/nixpkgs/issues/451912).

### 4. nixGL / nix-gl-host — NOT the right tool here

`nixGL`/`nixglhost` exist to run Nix-built GPU binaries on a **non-NixOS host directly** (no
container), by discovering and exposing the host's `libcuda.so.1` to a Nix closure
(https://danieldk.eu/Nix-CUDA-on-non-NixOS-systems; https://github.com/akssri-sony/nixGL).
Inside a container the NVIDIA Container Toolkit already performs the driver-injection role that
nixGL performs on bare metal, so nixGL is redundant and adds complexity. Skip it for the
containerized PyTorch goal. (It would only matter if you ran PyTorch on the host without a
container.)

---

## Verdict (single best choice)

For "working PyTorch-GPU with minimal fragility, limited Docker iteration": **use option 1 —
`dockerTools.buildLayeredImage` with `fromImage` = a pinned `nvidia/cuda:12.8.*-runtime` (or
`pytorch/pytorch:*-cuda12.8-*`) base.** It eliminates the entire non-FHS loader problem
(loader, ldconfig, `/usr/lib`, glibc all present), guarantees Blackwell/sm_120 support via the
CUDA 12.8 base, and still lets you keep all your tooling defined in Nix on top. Set
`NVIDIA_DRIVER_CAPABILITIES=compute,utility` + `NVIDIA_VISIBLE_DEVICES=all`, install PyTorch via
pixi (its wheels bundle CUDA), and `--gpus all` will work. You give up "pure Nix from scratch,"
which is not worth the iteration risk given limited Docker access.

Pure-Nix-from-scratch + GPU is genuinely practical (Canva ships it), but only via option 2's
three shims, and it remains sensitive to toolkit version changes (legacy->CDI path drift). Choose
it only if a `FROM scratch` image is a hard requirement; otherwise it is more fragile for no
PyTorch-functional gain, since PyTorch needs only `libcuda.so.1` either way.

## Version-sensitive notes

- Toolkit >= 1.17 defaults to CDI (just-in-time spec); legacy hook still selectable. 1.18.0
  flipped more behavior to CDI and broke some lib paths — you're on 1.17.8, below that line.
  (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/release-notes.html,
  https://github.com/NVIDIA/nvidia-container-toolkit/issues/1456)
- Blackwell RTX 5090 = sm_120, requires CUDA >= 12.8 and PyTorch >= 2.7.0 (first stable sm_120
  wheels). Use a `-cuda12.8-` (or newer) base/wheel.
  (https://docs.salad.com/container-engine/tutorials/machine-learning/pytorch-rtx5090)
- Driver 580 on host is new enough for CUDA 12.8 user-space; `libcuda.so.1` is injected from the
  host, so the in-container CUDA runtime version is what matters for sm_120, not the host toolkit.
- After any host driver upgrade, regenerate CDI spec (`nvidia-ctk cdi generate`) if using CDI
  (https://github.com/NixOS/nixpkgs/issues/451912).

## Sources

- Canva production GPU-ML on Nix dockerTools (FHS shims, ld-linux, /tmp, NVIDIA_DRIVER_CAPABILITIES, PyTorch bundles CUDA): https://www.canva.dev/blog/engineering/supporting-gpu-accelerated-machine-learning-with-kubernetes-and-nix/
- nixpkgs#78739 dockerTools nvidia-docker nvidia-smi exec failure (open): https://github.com/NixOS/nixpkgs/issues/78739
- Discourse: dockerTools.buildLayeredImage + CUDA (ld-linux symlink, LD_LIBRARY_PATH, NVIDIA_* env): https://discourse.nixos.org/t/how-to-use-dockertools-buildlayeredimage-and-cuda/14593
- Seán Murphy, CUDA images on CI with Nix (pure Nix, /tmp 1777 via fakeRootCommands, LD_LIBRARY_PATH=/usr/lib64): https://seanrmurphy.medium.com/building-cuda-images-on-github-runners-with-nix-9b5daa2f6f92
- Sebastian Staffa, nvidia-docker with Nix (prestart-hook injection mechanism, LD_LIBRARY_PATH): https://sebastian-staffa.eu/posts/nvidia-docker-with-nix
- Staff-d/nix-cuda-docker-example (buildImage wrapper, env vars): https://github.com/Staff-d/nix-cuda-docker-example
- dockerTools manual (pullImage/fromImage, reproducible `created`): https://github.com/NixOS/nixpkgs/blob/master/doc/build-helpers/images/dockertools.section.md
- NVIDIA Container Toolkit release notes (1.17 CDI default, 1.18 changes): https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/release-notes.html
- CDI overview (which driver libs/symlinks get mounted): https://deepwiki.com/NVIDIA/nvidia-container-toolkit/3.2-container-device-interface-(cdi)
- nvidia-container-toolkit#1456 (CDI 1.18 broke lib paths; LD_LIBRARY_PATH fix): https://github.com/NVIDIA/nvidia-container-toolkit/issues/1456
- nixpkgs#366109 (CUDA libs need extra LD_LIBRARY_PATH; libcuda.so symlink mismatch): https://github.com/NixOS/nixpkgs/issues/366109
- nixpkgs#451912 (regenerate CDI spec after driver load/update): https://github.com/NixOS/nixpkgs/issues/451912
- nixpkgs#337873 (toolkit works in Podman, not Docker on NixOS; runtime registration): https://github.com/NixOS/nixpkgs/issues/337873
- PyTorch RTX 5090 / sm_120 / CUDA 12.8 requirement: https://docs.salad.com/container-engine/tutorials/machine-learning/pytorch-rtx5090
- nixGL / nix-gl-host (host-driver discovery on non-NixOS, bare metal not containers): https://danieldk.eu/Nix-CUDA-on-non-NixOS-systems , https://github.com/akssri-sony/nixGL
