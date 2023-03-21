{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv.url = "github:cachix/devenv";
    nix-dart.url = "github:farcaller/nix-dart";
    nix-dart.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, devenv, nix-dart, flake-utils, ... } @ inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
      in
      rec {
        dockerImage.chatbot = pkgs.dockerTools.buildImage {
          name = "ghcr.io/farcaller/mucklet-chatbot";
          tag = "latest";

          config = {
            Cmd = [ "${packages.chatbot}/bin/chatbot" ];
            config.Labels."org.opencontainers.image.source" = "https://github.com/farcaller/mucklet-chatbot";
          };
        };

        packages.chatbot = nix-dart.builders.${system}.buildDartPackage
          rec {
            pname = "chatbot";
            version = "1.1.0";

            src = ./.;

            specFile = "${src}/pubspec.yaml";
            lockFile = ./pub2nix.lock;

            meta = with lib; {
              description = "Mucklet chatbot.";
              homepage = "https://github.com/farcaller/mucklet-chatbot";
              license = licenses.asl20;
            };
          };

        devShells.default = devenv.lib.mkShell {
          inherit inputs pkgs;
          modules = [
            {
              scripts.update-deps.exec = "nix run github:tadfisher/nix-dart#pub2nix-lock";
              languages.dart.enable = true;
            }
          ];
        };
      });
}
