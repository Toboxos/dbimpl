{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils}: 
  let
    mkPkgs = system: import nixpkgs {
      inherit system;
    };
  in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = mkPkgs system;
      in {
        devShells.default = pkgs.mkShell {
          name = "impldb";

          buildInputs = with pkgs; [
            zig
          ];
        };
      }
  );
}
