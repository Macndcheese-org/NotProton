# NotProton (MnC Wine fork)

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This fork runs games on **MnC Wine**, the Wine build behind MacNdCheese, instead of
CrossOver. MacNdCheese itself does not need to be installed or open. MnC Wine ships its
own D3DMetal (Apple Game Porting Toolkit 3.0 and 4.0b2) and DXMT, and per game you pick:

- **Graphics**: Automatic (D3DMetal), D3DMetal (GPTK), DXMT, or OpenGL (WineD3D)
- **MSync** on or off
- Metal HUD, DLSS (D3DMetal or DXMT), AVX2 for Rosetta, high resolution

All of these sit in the game's Properties > Compatibility page in Steam.

## Setting it up

1. Download the MnC Wine release `wine-unified-osx64.tar.xz` into `~/Downloads`.
2. Open NotProton. Its Status pane lists the tarball under **MnC Wine**. Press **Set Up**,
   which unpacks it into `~/Library/Application Support/notproton/runners/` and patches
   its ntdll so games can reach Steam through lsteamclient. A tarball kept elsewhere can be
   added with **Add Release…**.
3. Install NotProton into Steam, restart Steam, and pick **MnC Wine 11.18** in a Windows
   game's Compatibility settings.

MnC Wine is an x86_64 build that runs under Rosetta. It loads FreeType, fontconfig and
GnuTLS at runtime, so it needs x86_64 copies of them: Intel Homebrew
(`arch -x86_64 /usr/local/bin/brew install freetype fontconfig gnutls`), or the
`deps/mnc-fonts` and `deps/mnc-tls` folders a MacNdCheese install leaves behind. The Status
pane warns when they are missing.

Only the MnC Wine builds pinned in `app/Sources/NotProtonApp/Model/SupportedRunner.swift`
are accepted, because the ntdll hook sites are fixed offsets. A new MnC Wine release is
pinned with `make ntdll-resolve MNC_ROOT=<unpacked tree>` and
`MNC_ROOT=<unpacked tree> ntdll-patch/build-ntdll.sh`.

## Layout

The macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9. ```ntdll-patch``` patches the copy of MnC Wine that the app
unpacks into ```~/Library/Application Support/notproton/runners/``` so that lsteamclient
is loaded. ```dylib/feats/compat_run.sh``` is the compatibility tool Steam runs: it builds
each game's prefix, stages the D3DMetal/DXMT DLLs MnC Wine routes between, and launches
the game.

Please read NOTICE for license information.
