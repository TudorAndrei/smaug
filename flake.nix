{
  description = "Smaug dev shell (node + bird CLI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPkgs = system: import nixpkgs { inherit system; };

      mkBird = system:
        let
          pkgs = mkPkgs system;
        in
          # bird is distributed on npm; nixpkgs doesn't currently package it.
          # Provide a `bird` command via bunx so Smaug's setup wizard finds it.
          pkgs.writeShellScriptBin "bird" ''
            exec ${pkgs.bun}/bin/bunx @steipete/bird@0.8.0 "$@"
          '';
    in
    {
      packages = forAllSystems (system:
        let
          bird = mkBird system;
        in
        {
          inherit bird;
          default = bird;
        });

      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs system;
          bird = mkBird system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nodejs_20
              pkgs.bun
              bird
            ];
          };
        });
    };
}
