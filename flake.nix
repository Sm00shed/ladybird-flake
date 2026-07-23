# SPDX-License-Identifier: GPL-2.0-only
{
  description = "Ladybird browser development environment";

  inputs = {
    # TEST FLAKE — no nixpkgs fork. Standard nixpkgs on every platform.
    # Hypothesis: keeping apple-sdk_15 out of the global overlay (so the
    # bootstrap keeps the default SDK) plus a per-shell darwinMinVersionHook
    # avoids the gnum4/strchrnul bootstrap failure that the fork worked around.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-utils.url = "github:numtide/flake-utils";

    # Pinned Ladybird source, tracked in versions.json. Not built here (the dev
    # shell only provides deps) — this only records which revision is "current"
    # and is overridden at runtime by `lb new` / `lb use` via --override-input.
    ladybird = {
      url = "github:LadybirdBrowser/ladybird/94a55b0e9045b1e96307c5e4f0242309c589ecd4";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ladybird }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        isDarwin = builtins.match ".*-darwin" system != null;
        isLinux  = builtins.match ".*-linux"  system != null;

        # No fork, and deliberately NO global apple-sdk overlay: the bootstrap
        # (gnum4 etc.) keeps the default SDK, so strchrnul stays unavailable and
        # -Werror=unguarded-availability-new never fires. apple-sdk_15 is added
        # only to the dev shell below, together with darwinMinVersionHook "15.4".
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowDeprecatedx86_64Darwin = true;
          };
        };

        llvm = pkgs.llvmPackages_21;

        mimalloc227 = pkgs.mimalloc.overrideAttrs (_: rec {
          version = "2.2.7";
          src = pkgs.fetchFromGitHub {
            owner = "microsoft";
            repo  = "mimalloc";
            rev   = "v${version}";
            hash  = "sha256-z9qMOTcGkURblZChXDGfQ58hrql52lG6EE1NQmxxuj0=";
          };
          patches = [];
        });

        # Apple Clang does not define __STDC_IEC_559__ even on IEEE-754-compliant x86_64,
        # so mp_set_double is compiled out despite being declared in the header.
        # Patch the guard to always true.
        libtommath130 = pkgs.libtommath.overrideAttrs (prev: {
          postPatch = (prev.postPatch or "") + ''
            substituteInPlace bn_mp_set_double.c \
              --replace-fail \
                '#if defined(__STDC_IEC_559__) || defined(__GCC_IEC_559)' \
                '#if 1 /* forced: x86_64 is IEEE754 compliant */'
          '';
        });

        wuffsSinglefile = pkgs.stdenv.mkDerivation {
          name = "wuffs-singlefile-0.3.4";
          src  = pkgs.fetchFromGitHub {
            owner = "google";
            repo  = "wuffs-mirror-release-c";
            rev   = "v0.3.4";
            hash  = "sha256-V7inWJqH7Q4Ac/ZB//7XHrpgfAYUPBxWBerBem6Q/Kk=";
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
          version = "148-unstable-2026-06-12";
          src = pkgs.fetchgit {
            url  = "https://skia.googlesource.com/skia.git";
            rev  = "46f2e16555cac1211f4087cf24728fd741ac6495";
            hash = "sha256-vpd/W0C8zT+wzShdJYdd18GmNp/TklqF7bGZxfIaDDM=";
          };
          gnFlags = prev.gnFlags ++ [
            "extra_cflags+=[\"-DSKCMS_API=[[gnu::visibility(\\\"default\\\")]]\"]"
          ];
          patches = [];
        });

        # On Linux, build angle with Clang 20 stdenv: Clang 21 ICEs while parsing
        # rx::vk::ImageHelper::SubresourceUpdate in vk_helpers.h (complex nested union type).
        # angle.pc is generated correctly since nixpkgs PR #528602 (merged 2026-06-09).
        ladybirdAngleBase = if isLinux
          then pkgs.angle.override { stdenv = pkgs.llvmPackages_20.stdenv; }
          else pkgs.angle;
        # On macOS, ANGLE ships three libGLESv2 variants (standard, _with_capture,
        # _vulkan_secondaries) that all define the ObjC class ANGLESwapCGLLayer.
        # The duplicate-class crash was reported for _with_capture vs each of the
        # other two, so _with_capture is the stray copy to drop. Keep the standard
        # libGLESv2.dylib AND libGLESv2_vulkan_secondaries.dylib: the standard lib
        # depends on ./libGLESv2_vulkan_secondaries.dylib, so the Compositor fails
        # to load ("Library not loaded") if that one is removed too.
        ladybirdAngle = if isDarwin
          then ladybirdAngleBase.overrideAttrs (prev: {
            postFixup = (prev.postFixup or "") + ''
              rm -f "$out/lib/libGLESv2_with_capture.dylib"
            '';
          })
          else ladybirdAngleBase;

        libPkgs = with pkgs; [
          curlFull ffmpeg.lib fontconfig.lib libavif ladybirdAngle libjxl libwebp libxcrypt
          openssl sdl3 brotli.lib libhwy lcms2 zstd libidn2 woff2.lib icu78
          mimalloc227 harfbuzz libjpeg libpng libxml2 sqlite zlib ladybirdSkia
          fmt simdutf simdjson libtommath130 libpsl libedit
        ] ++ pkgs.lib.optionals isLinux (with pkgs; [
          libdrm vulkan-loader vulkan-memory-allocator
          libGL libpulseaudio qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
          stdenv.cc.cc.lib
        ]);

        cmakePrefixParts = with pkgs; [
          icu78.dev harfbuzz.dev openssl.dev curlFull.dev sdl3.dev fmt.dev
          fontconfig.dev libavif.dev libjxl.dev libpng.dev libxml2.dev zlib.dev
          woff2.dev ffmpeg.dev libedit.dev libpsl.dev libjpeg.dev sqlite.dev
          mimalloc227.dev
        ] ++ [ libtommath130 ]
          ++ pkgs.lib.optionals isLinux (with pkgs; [
          vulkan-loader.dev vulkan-headers vulkan-memory-allocator
          libpulseaudio.dev libGL.dev
          qt6Packages.qtbase qt6Packages.qtmultimedia qt6Packages.qtwayland
        ]);

        cmakePrefixPath = pkgs.lib.concatStringsSep ":" (map toString cmakePrefixParts);

        # nixpkgs source actually in use for this system (banner only).
        nixpkgsSrc = nixpkgs;

        # Tracked Ladybird revisions. Reverse-lookup the current rev's date for
        # the banner; falls back to "untracked" when overridden to a loose rev.
        versions     = builtins.fromJSON (builtins.readFile ./versions.json);
        ladybirdRev  = ladybird.rev or "unknown";
        ladybirdDate =
          let names = builtins.attrNames
            (pkgs.lib.filterAttrs (_: h: h == ladybirdRev) versions);
          in if names == [] then "untracked" else builtins.head names;

        # `lb`: manage which Ladybird revision the dev shell is pinned to.
        #   lb new              fetch current upstream HEAD, enter shell on it
        #   lb use <date|hash>  enter shell on a versions.json entry
        #   lb ok               record the active rev in versions.json + commit/push
        #   lb list             show tracked revisions
        lb = pkgs.writeShellScriptBin "lb" ''
          set -euo pipefail
          export PATH="${pkgs.lib.makeBinPath (with pkgs; [ jq curl git coreutils ])}:$PATH"

          REPO="LadybirdBrowser/ladybird"
          FLAKE_REPO="Sm00shed/ladybird-flake"

          # Maintainers keep a local clone next to the Ladybird source; testers
          # just use the published flake. Use the local clone when present, else
          # fall back to the GitHub reference.
          FLAKE_DIR="''${LADYBIRD_FLAKE_DIR:-$PWD/../ladybird-flake}"
          if [ -d "$FLAKE_DIR/.git" ]; then
            FLAKE_REF="$FLAKE_DIR"; LOCAL=1
          else
            FLAKE_REF="github:$FLAKE_REPO"; LOCAL=0
          fi

          # versions.json from the local clone when available, else raw GitHub.
          versions() {
            if [ "$LOCAL" = 1 ]; then
              cat "$FLAKE_DIR/versions.json"
            else
              curl -fsSL "https://raw.githubusercontent.com/$FLAKE_REPO/main/versions.json"
            fi
          }

          override() {
            exec nix develop "$FLAKE_REF" \
              --override-input ladybird "github:$REPO/$1"
          }

          case "''${1:-}" in
            new)
              hash=$(curl -fsSL "https://api.github.com/repos/$REPO/commits/HEAD" \
                       | jq -r .sha)
              echo "upstream HEAD is ''${hash:0:8}"
              override "$hash"
              ;;
            use)
              key="''${2:-}"
              [ -n "$key" ] || { echo "usage: lb use <date|hash>" >&2; exit 1; }
              v=$(versions)
              hash=$(printf '%s' "$v" | jq -r --arg k "$key" '.[$k] // empty')
              if [ -z "$hash" ]; then
                hash=$(printf '%s' "$v" | jq -r --arg k "$key" \
                  'to_entries[] | select(.value | startswith($k)) | .value' \
                  | head -n1)
              fi
              [ -n "$hash" ] || { echo "not in versions.json: $key" >&2; exit 1; }
              echo "using ''${hash:0:8}"
              override "$hash"
              ;;
            ok)
              [ "$LOCAL" = 1 ] || {
                echo "lb ok is maintainer-only: needs a local clone (set LADYBIRD_FLAKE_DIR)" >&2
                exit 1
              }
              rev="''${LADYBIRD_REV:-}"
              [ -n "$rev" ] || {
                echo "LADYBIRD_REV unset — run inside the ladybird dev shell" >&2
                exit 1
              }
              today=$(date +%F)
              tmp=$(mktemp)
              jq --arg d "$today" --arg h "$rev" '. + {($d): $h}' \
                "$FLAKE_DIR/versions.json" > "$tmp"
              mv "$tmp" "$FLAKE_DIR/versions.json"
              git -C "$FLAKE_DIR" add versions.json
              git -C "$FLAKE_DIR" commit -m "versions: pin $today (''${rev:0:8})"
              git -C "$FLAKE_DIR" push
              echo "recorded $today -> ''${rev:0:8}"
              ;;
            list)
              versions | jq -r 'to_entries[] | "\(.key) \(.value)"' \
                | while read -r d h; do
                    mark=" "
                    [ "$h" = "''${LADYBIRD_REV:-}" ] && mark="*"
                    printf ' %s %s  %s\n' "$mark" "$d" "''${h:0:8}"
                  done
              ;;
            *)
              echo "usage: lb {new | use <date|hash> | ok | list}" >&2
              exit 1
              ;;
          esac
        '';

      in {
        devShells.default = pkgs.mkShell {
          name = "ladybird-dev";

          NIX_ENFORCE_NO_NATIVE = "0";

          packages = libPkgs
            ++ [ llvm.clang llvm.lld ]
            ++ [ lb ]
            ++ [ libtommath130 ]
            ++ (with pkgs; [
              cmake ninja pkg-config python3 perl cargo rustc ccache git coreutils
              curlFull.dev fast-float ffmpeg.dev fmt fmt.dev fontconfig.dev
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

          # apple-sdk_15 + hook as buildInputs (target role), NOT nativeBuildInputs:
          # the apple-sdk setup-hook is role-dependent — as a buildInput it should
          # activate SDK 15 for the compile, which packages/nativeBuildInputs did not.
          buildInputs = pkgs.lib.optionals isDarwin [
            pkgs.apple-sdk_15
            (pkgs.darwinMinVersionHook "15.4")
          ];

          shellHook = ''
            export LADYBIRD_REV=${ladybirdRev}
            export CC=${llvm.clang}/bin/clang
            export CXX=${llvm.clang}/bin/clang++
            export CMAKE_BUILD_TYPE=Release
            export CMAKE_PREFIX_PATH="${cmakePrefixPath}''${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
            export ICU_ROOT=${pkgs.icu78.dev}
            export PKG_CONFIG_PATH="${ladybirdSkia}/lib/pkgconfig:${ladybirdAngle}/lib/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            # CVDisplayLinkRelease is outside its pragma diagnostic block in VSyncScheduler.cpp:177.
            # Reported upstream: https://github.com/LadybirdBrowser/ladybird/issues/10657
            export CXXFLAGS="-Wno-deprecated-declarations''${CXXFLAGS:+ $CXXFLAGS}"
            export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = with pkgs; [ dejavu_fonts liberation_ttf ]; }}
            export CLANGD_PATH=${llvm.clang-unwrapped}/bin/clangd
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            # Copy CA cert into Caches/CACERT: Landlock sandbox on Linux blocks direct
            # Nix store paths for RequestServer (see SandboxLinux.cpp).
            # Override: set LADYBIRD_CERTIFICATE=/your/cert.crt before launching.
            if [ -f "$PWD/Meta/CMake/check_for_dependencies.cmake" ]; then
              mkdir -p "$PWD/Caches/CACERT"
              cp --no-preserve=mode ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
                 "$PWD/Caches/CACERT/ca-bundle.crt"
              # The confirm_canceling_downloads lambda in TabController.mm has no
              # explicit return type. On x86_64 macOS (BOOL = signed char) auto
              # return-type deduction fails to reconcile `bool` and `BOOL`; this is a
              # hard error, so no -W flag can suppress it. Patch in an explicit -> bool.
              # Reported upstream: https://github.com/LadybirdBrowser/ladybird/issues/10658
              tabcontroller="$PWD/UI/AppKit/Interface/TabController.mm"
              if [ -f "$tabcontroller" ] && grep -q 'confirm_canceling_downloads = \[&\]() {' "$tabcontroller"; then
                perl -pi -e 's/\Qconfirm_canceling_downloads = [&]() {\E/confirm_canceling_downloads = [&]() -> bool {/' \
                  "$tabcontroller"
              fi
            fi
            LADYBIRD_SRC_DIR="$PWD"
            export LADYBIRD_CERTIFICATE="''${LADYBIRD_CERTIFICATE:-$PWD/Caches/CACERT/ca-bundle.crt}"
            unset VCPKG_ROOT
            unset CMAKE_TOOLCHAIN_FILE

            ${if isDarwin then ''
              export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion)"
              # Point SDKROOT at apple-sdk_15 via its sdkroot attr.
              export SDKROOT="${pkgs.apple-sdk_15.sdkroot}"
              export LIBRARY_PATH="${pkgs.fontconfig.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              # Runtime lib path for the GPU Compositor (ANGLE libEGL/libGLESv2),
              # which live in the Nix store, not next to the binary. macOS analog
              # of the Linux LD_LIBRARY_PATH below — without it the Compositor
              # fails with "Library not loaded: ./libEGL.dylib".
              #
              # Use the FALLBACK path, not DYLD_LIBRARY_PATH: the latter takes
              # precedence over a library's install name and thus injects Nix
              # libpng into Apple system tools (iconutil, ImageIO). That crashes
              # PNGReadPlugin at 0xbad4007 during the icns conversion in the link
              # step and again when Ladybird loads its default favicon. The
              # fallback path is only consulted when a lib is not found normally,
              # so system libpng keeps priority while ANGLE's libEGL is still found.
              export DYLD_FALLBACK_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
              export LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${LDFLAGS:+ $LDFLAGS}"
              export NIX_LDFLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics''${NIX_LDFLAGS:+ $NIX_LDFLAGS}"
              export CMAKE_EXE_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              export CMAKE_SHARED_LINKER_FLAGS="-framework CoreText -framework CoreFoundation -framework CoreGraphics"
              # macOS builds Ladybird.app bundle; sandbox requires codesigning so disable it
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird.app/Contents/MacOS/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" --disable-sandbox "$@"; }
            '' else ''
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath libPkgs}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export CMAKE_EXE_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_EXE_LINKER_FLAGS:+ $CMAKE_EXE_LINKER_FLAGS}"
              export CMAKE_SHARED_LINKER_FLAGS="-lGL -lfontconfig''${CMAKE_SHARED_LINKER_FLAGS:+ $CMAKE_SHARED_LINKER_FLAGS}"
              Ladybird() { "$LADYBIRD_SRC_DIR/Build/release/bin/Ladybird" --certificate="$LADYBIRD_CERTIFICATE" "$@"; }
            ''}

            ${if isLinux then "ulimit -s unlimited" else "ulimit -s hard"}
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

            echo ""
            echo "Ladybird Dev Shell"
            echo "   Source: ${builtins.substring 0 8 ladybirdRev} (${ladybirdDate})"
            echo "   Env:    nixpkgs ${builtins.substring 0 8 nixpkgsSrc.rev}"
            echo ""
            echo "   lb new | lb use <date> | lb ok | lb list"
            echo ""
          '';
        };
      }
    );
}
