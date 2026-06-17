# Reusable base image. No CUDA — that installs via pixi inside the box; never bake the NVIDIA driver.
{ pkgs, name ? "claudebox-base", tag ? "latest" }:
let
  cliTools = with pkgs; [
    git gh
    ripgrep fd bat fzf tree lsd dust procs tldr
    ast-grep yq-go jq
    lazygit neovim vim tmux btop
    shellcheck shfmt
    starship zoxide
    curl wget
  ];
  buildTools = with pkgs; [
    bashInteractive coreutils gnused gnugrep gawk gnutar gzip findutils which
    cacert gnumake gcc binutils
    pixi
    claude-code
  ];
  # Generic user + world-writable home: the box runs as the host uid/gid at runtime (nothing hardcoded).
  # Auto-mode via managed policy (system path, not ~/.claude) so it never shadows the bound memory.
  rootfsSetup = pkgs.runCommand "rootfs-setup" { } ''
    mkdir -p $out/etc/claude-code $out/home/dev $out/tmp
    chmod 0777 $out/home/dev $out/tmp
    echo "root:x:0:0:root:/root:/bin/bash" > $out/etc/passwd
    echo "dev:x:1000:1000:dev:/home/dev:/bin/bash" >> $out/etc/passwd
    echo "root:x:0:" > $out/etc/group
    echo "dev:x:1000:" >> $out/etc/group
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
      "PIXI_HOME=/home/dev/.pixi"
    ];
    WorkingDir = "/home/dev";
    Cmd = [ "/bin/bash" ];
    Labels = { "org.opencontainers.image.source" = "claudebox (Nix base)"; };
  };
}
