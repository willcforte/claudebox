# Reusable BASE container image. Content-addressed, layered, parameterizable per project.
# CUDA/torch/cuRobo are intentionally absent — they install in the pixi layer INSIDE the container
# (nixpkgs CUDA lags Blackwell; cuRobo is unpackaged). Never bake the NVIDIA driver: the host's
# nvidia runtime injects it at `docker run --gpus all`.
{ pkgs, name ? "claudebox-base", tag ? "latest" }:
let
  # Will's CLI prefs, mirrored from ~/.dotfiles/home.nix (sensible-for-a-container subset).
  cliTools = with pkgs; [
    git gh
    ripgrep fd bat fzf tree lsd dust procs tldr
    ast-grep yq-go jq
    lazygit neovim vim tmux btop
    shellcheck shfmt
    starship zoxide
    curl wget
  ];
  # Common build tools (pixi pulls the real toolchain per env; these cover host-side glue + git over https).
  buildTools = with pkgs; [
    bashInteractive coreutils gnused gnugrep gawk gnutar gzip findutils which
    cacert gnumake gcc binutils
    pixi
    claude-code
  ];
  # Generic non-root user. The container is launched with the HOST's uid/gid at RUNTIME (claudebox
  # passes --user "$(id -u):$(id -g)"; VSCode remaps via updateRemoteUserUID) — nothing here hardcodes
  # a uid, so it works on any machine. /home/dev is world-writable so an arbitrary runtime uid can use
  # it as HOME (the real data — repo, ~/.claude, pixi cache — arrives as host-owned bind mounts).
  rootfsSetup = pkgs.runCommand "rootfs-setup" { } ''
    mkdir -p $out/etc/claude-code $out/home/dev $out/tmp
    chmod 0777 $out/home/dev $out/tmp
    echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
    echo "dev:x:1000:1000:dev:/home/dev:/bin/bash" >> $out/etc/passwd
    echo "root:x:0:" > $out/etc/group
    echo "dev:x:1000:" >> $out/etc/group
    # Container-only auto-mode via Claude managed policy (system path, NOT ~/.claude) so it never
    # shadows the bind-mounted memory and never leaks to the host. Fallback if a build rejects this:
    # launch `claude --dangerously-skip-permissions`.
    echo '{"permissions":{"defaultMode":"bypassPermissions"}}' > $out/etc/claude-code/managed-settings.json
  '';
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag;
  contents = cliTools ++ buildTools ++ [ pkgs.dockerTools.binSh rootfsSetup ];
  config = {
    User = "dev";
    Env = [
      "PATH=/bin:/usr/bin"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "HOME=/home/dev"
      "LANG=C.UTF-8"
      # pixi env lands in the project mount; cache is a separate persisted bind (set by claudebox / devcontainer.json).
      "PIXI_HOME=/home/dev/.pixi"
    ];
    WorkingDir = "/home/dev";
    Cmd = [ "/bin/bash" ];
    Labels = { "org.opencontainers.image.source" = "claudebox (Nix base)"; };
  };
}
