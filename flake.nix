{
  description = "Reusable Nix base image for sandboxed Claude Code dev containers (CUDA via pixi inside).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "claude-code" ];
        };
        baseImage = pkgs.callPackage ./nix/base-image.nix {
          name = "claudebox-base";
          tag = "latest";
        };
      in {
        packages = {
          inherit baseImage;
          default = baseImage;
        };
      });
}
