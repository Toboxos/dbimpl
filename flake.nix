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
        zigDeps = pkgs.callPackage ./deps.nix {};
      in {
        devShells.default = pkgs.mkShell {
          name = "impldb";

          buildInputs = with pkgs; [
            lldb
            zig
            zon2nix
          ];
        };

        packages = {
          default = pkgs.stdenv.mkDerivation {
            name = "dbimpl";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];

            buildPhase = ''
              zig build -Doptimize=Release --system ${zigDeps}
            '';
            installPhase = ''
              mkdir -p $out/bin
              cp zig-out/bin/dbimpl $out/bin/
            '';
          };

        };

        apps = {
          benchmark = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/benchmark";
          };
        };
      }
  );
}
