# Reusable base image: Nix tooling layered onto a pinned FHS CUDA base (nvidia/cuda) so the NVIDIA
# runtime can inject the driver + libcuda for PyTorch. torch/cuRobo install via pixi inside the box.
{ pkgs, name ? "claudebox-base", tag ? "latest" }:
let
  # FHS base supplies glibc + the ELF loader + ldconfig so injected GPU libs load. Pinned by digest;
  # `hash` is TOFU — first build reports the real value to paste in.
  cudaBase = pkgs.dockerTools.pullImage {
    imageName = "nvidia/cuda";
    imageDigest = "sha256:520292dbb4f755fd360766059e62956e9379485d9e073bbd2f6e3c20c270ed66";
    finalImageName = "nvidia/cuda";
    finalImageTag = "12.8.1-devel-ubuntu24.04";
    hash = "sha256-eMo1+SfCjMh2zwXvfagw0v8QppUBdcJdhAct0f8MKlY=";
    os = "linux";
    arch = "amd64";
  };
  # coreutils/bash/binSh included so /bin is self-sufficient over the Ubuntu base (merged-/usr safety).
  tools = with pkgs; [
    coreutils bashInteractive gnused gnugrep gawk gnutar gzip findutils which
    git gh
    ripgrep fd bat fzf tree lsd dust procs tldr
    ast-grep yq-go jq
    lazygit neovim tmux btop
    shellcheck shfmt
    starship zoxide
    curl wget cacert
    nodejs
    pixi
    claude-code
  ];
  rootfsSetup = pkgs.runCommand "rootfs-setup" { } ''
    mkdir -p $out/etc/claude-code $out/etc/claudebox $out/home/dev
    chmod 0777 $out/home/dev
    echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
    echo "dev:x:1000:1000:dev:/home/dev:/bin/bash" >> $out/etc/passwd
    echo "root:x:0:" > $out/etc/group
    echo "dev:x:1000:" >> $out/etc/group
    echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > $out/etc/claude-code/managed-settings.json
    cp ${../assets/banner.sh} $out/etc/claudebox/banner.sh
    cp ${../assets/bashrc}    $out/home/dev/.bashrc
    chmod 0644 $out/etc/claudebox/banner.sh $out/home/dev/.bashrc
  '';
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag;
  fromImage = cudaBase;
  contents = tools ++ [ pkgs.dockerTools.binSh rootfsSetup ];
  config = {
    User = "dev";
    Env = [
      "PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/usr/local/cuda/bin"
      "LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/nvidia/lib:/usr/local/nvidia/lib64"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "HOME=/home/dev"
      "LANG=C.UTF-8"
      "PIXI_HOME=/home/dev/.pixi"
      # /home/dev is read-only (Nix store); cache/data/history go to the writable .cache bind mount.
      "XDG_CACHE_HOME=/home/dev/.cache"
      "XDG_DATA_HOME=/home/dev/.cache/data"
      "XDG_STATE_HOME=/home/dev/.cache/state"
      "HISTFILE=/home/dev/.cache/bash_history"
      "NVIDIA_VISIBLE_DEVICES=all"
      "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
    ];
    WorkingDir = "/home/dev";
    Cmd = [ "/bin/bash" ];
    Labels = { "org.opencontainers.image.source" = "claudebox (Nix on nvidia/cuda)"; };
  };
}
