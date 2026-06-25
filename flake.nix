{
  description = "Ladybird browser development environment";

  inputs = {
    nixpkgs.url     = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        isDarwin = builtins.match ".*-darwin" system != null;
        isLinux  = builtins.match ".*-linux"  system != null;

        llvm = pkgs.llvmPackages_21;

        mimalloc227 = pkgs.mimalloc.overrideAttrs (_: rec {
          version = "2.2.7";
          src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo  = "mimalloc";
            rev   = "v${version}";
            hash  = "sha256:0gdsf5n44kad22x53nkrm6p237s3kwqmr8chjmdl94866wwqrnng";
          };
          patches = [];
        });

        wuffsSinglefile = pkgs.stdenv.mkDerivation {
          name = "wuffs-singlefile-0.3.4";
          src  = pkgs.fetchFromGitHub {
            owner = "google";
            repo  = "wuffs-mirror-release-c";
            rev   = "v0.3.4";
            hash  = "sha256:1agwj1p7mhga0mb1qg0l0ry61fhyszzgyhgnfc00xvc7k9cagf2p";
          };
          dontBuild    = true;
          installPhase = ''
            mkdir -p $out/include/wuffs
            install -m444 release/c/wuffs-v0.3.c $out/include/wuffs/wuffs-v0.3.c
          '';
        };

        hstsPreload = pkgs.fetchurl {
          url  = "https://raw.githubusercontent.com/chromium/chromium/main/net/http/transport_security_state_static.json";
          hash = "sha256-YuiotSk0Lf3IHz/UjgCmU/brdB1lszob6DN4DXyjiWU=";
        };

        ladybirdSkia = pkgs.skia.overrideAttrs (prev: {
          gnFlags = prev.gnFlags ++ [
            "extra_cflags+=[\"-DSKCMS_API=[[gnu::visibility(\\\"default\\\")]]\"]"
          ];
          patches = (prev.patches or []) ++ [
            (pkgs.fetchpatch {
              url  = "https://github.com/microsoft/vcpkg/raw/64e1fbee7d9f40eab5d112aaff648c4dcffe9e47/ports/skia/skpath-enable-edit-methods.patch";
              hash = "sha256-r5+HqSjACINn8igXqBANQsq0K+fn+Ut8L2VRs40FkTM=";
            })
          ];
        });

        libPkgs = with pkgs; [
          curlFull ffmpeg.lib fontconfig.lib libavif angle libjxl libwebp libxcrypt
          openssl sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzz libjpeg libpng libxml2 sqlite zlib ladybirdSkia
          fmt simdutf simdjson libtommath libpsl libedit
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          libdrm vulkan-loader
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ]);

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzz.dev openssl.dev curlFull.dev sdl3.dev fmt.dev
          fontconfig.dev libavif.dev libjxl.dev libpng.dev libxml2.dev zlib.dev
          woff2.dev ffmpeg.dev libedit.dev libpsl.dev libjpeg.dev sqlite.dev
          mimalloc227.dev
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          vulkan-loader.dev vulkan-headers
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
        ]);

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          packages = libPkgs
            ++ [ llvm.clang llvm.clang-unwrapped ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              libtommath curlFull.dev fast-float ffmpeg.dev fmt fmt.dev fontconfig.dev
              libavif.dev libjxl.dev openssl.dev sdl3.dev simdutf brotli.dev lcms2.dev
              zstd.dev libidn2.dev woff2.dev icu78.dev simdjson mimalloc227.dev
              wuffsSinglefile libedit libedit.dev libpsl libpsl.dev harfbuzz.dev libjpeg.dev
              libpng.dev libxml2.dev sqlite.dev zlib.dev
              unicode-character-database unicode-emoji unicode-idna publicsuffix-list
              dejavu_fonts liberation_ttf cacert
            ])
            ++ pkgs.lib.optionals isLinux (with pkgs; [
              patchelf
              libdrm.dev vulkan-headers vulkan-loader.dev glslang
              libGL.dev libpulseaudio.dev qt6Packages.qtmultimedia qt6Packages.qtwayland
            ]);

          shellHook = ''
            export CC=${llvm.clang}/bin/clang
            export CXX=${llvm.clang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${pkgs.angle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export LADYBIRD_CERTIFICATE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            alias Ladybird="./Build/release/bin/Ladybird --certificate=$LADYBIRD_CERTIFICATE"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            ${if isDarwin then ''
              export LIBRARY_PATH="${pkgs.fontconfig.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export NIX_LDFLAGS="''${NIX_LDFLAGS} -lGL -lfontconfig"
            ''}

            ulimit -s unlimited
            export RUST_MIN_STACK=16777216

            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              if [ ! -f "$PWD/Caches/HSTSPreload/transport_security_state_static.json" ]; then
                mkdir -p "$PWD/Caches/HSTSPreload"
                cp --no-preserve=mode ${hstsPreload} "$PWD/Caches/HSTSPreload/transport_security_state_static.json"
              fi
              if [ ! -f "$PWD/Caches/UCD/version.txt" ]; then
                mkdir -p "$PWD/Caches/UCD"
                cp --no-preserve=mode -r ${pkgs.unicode-character-database}/share/unicode/. "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-emoji}/share/unicode/emoji/emoji-test.txt "$PWD/Caches/UCD/"
                cp --no-preserve=mode ${pkgs.unicode-idna}/share/unicode/idna/IdnaMappingTable.txt "$PWD/Caches/UCD/"
                printf '%s' '${pkgs.unicode-character-database.version}' > "$PWD/Caches/UCD/version.txt"
              fi
              if [ ! -f "$PWD/Caches/PublicSuffix/public_suffix_list.dat" ]; then
                mkdir -p "$PWD/Caches/PublicSuffix"
                cp --no-preserve=mode ${pkgs.publicsuffix-list}/share/publicsuffix/public_suffix_list.dat \
                   "$PWD/Caches/PublicSuffix/"
              fi
            fi
          '';
        };
      }
    );
}
