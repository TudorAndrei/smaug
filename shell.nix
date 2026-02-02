{ pkgs ? import <nixpkgs> { } }:

let
  bird = pkgs.writeShellScriptBin "bird" ''
    exec ${pkgs.bun}/bin/bunx @steipete/bird@0.8.0 "$@"
  '';
in
pkgs.mkShell {
  packages = [
    pkgs.nodejs_20
    pkgs.bun
    bird
  ];
}
