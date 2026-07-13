# Ladybird Nix Dev Shell

Cross-distro development environment for [Ladybird](https://github.com/LadybirdBrowser/ladybird) using `nix develop`.

Tested on:
- NixOS (x86_64-linux)
- Any Linux distribution with Nix installed (tested on CachyOS, x86_64-linux)
- macOS 15.x Intel (x86_64-darwin)

Tested with Ladybird commit `1fb86929fd` (2026-07-13). Other commits may work but are untested.

> **macOS note:** nixpkgs 26.05 has several known issues on x86_64-darwin (broken test suites, wrong deployment target, SDK misalignment). This flake works around all of them transparently.

## Install Nix

```bash
curl -L https://nixos.org/nix/install -o install-nix.sh
sh install-nix.sh
```

Restart your shell:

```bash
exec $SHELL
```

Then enable flakes:

```bash
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

## Build Ladybird

**1. Clone Ladybird**

```bash
git clone https://github.com/LadybirdBrowser/ladybird.git
cd ladybird
```

**2. Enter the dev shell**

```bash
nix develop github:Sm00shed/ladybird-flake
```

**3. Configure**

Linux:
```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches
```

macOS (x86_64 Intel only — Apple Silicon untested):
```bash
cmake -B Build/release -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_LTO_FOR_RELEASE=OFF \
  -DICU_ROOT="$ICU_ROOT" \
  -DENABLE_NETWORK_DOWNLOADS=OFF \
  -DLADYBIRD_CACHE_DIR=Caches \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
```

**4. Compile**

```bash
ninja -j$(nproc) -C Build/release
```

**5. Run**

```bash
Ladybird
```

> The `Ladybird` shell function handles platform differences automatically:
> Linux runs `bin/Ladybird`, macOS (x86_64 Intel) runs `Ladybird.app` with `--disable-sandbox`.
> CA certificate is passed automatically. Override with `LADYBIRD_CERTIFICATE=/your/cert.pem Ladybird`.

## What this flake provides

- Clang 21 (explicit, never system compiler)
- All dependencies pinned via `flake.lock`
- `CMAKE_PREFIX_PATH` set to Nix store paths — cmake never reads `/usr/lib`
- Unicode, Public Suffix List, HSTS Preload and CA certificates pre-populated
- `$CLANGD_PATH` exported for VSCode integration
- macOS: apple-sdk_15, correct deployment target alignment

## macOS notes

- Requires macOS 15.4 or later (apple-sdk_15 is used)
- Uses a nixpkgs fork (`Sm00shed/nixpkgs`) with `darwinMinVersion = "15.4"` — this aligns the deployment target with the SDK and fixes build failures in gnulib-based packages (`strchrnul` availability)
- x86_64-darwin (Intel Mac) is supported; aarch64-darwin (Apple Silicon) is untested
