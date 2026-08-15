# QUORADOR (native C++ build)

A native, single-codebase C++17 port of the Quorador web prototype, using
SDL2 for windowing/input/audio/rendering. Same rules, same AI, same
splash → menu → game flow, same animations (pawn slide, wall pop, victory
particles), same procedural-tone sound effects, same settings/resume
persistence — now compiled to a real macOS `.app` and a real Windows `.exe`
from one source tree.

No external assets are shipped: the UI font is an original 5x7 bitmap font
baked into `src/FontData.hpp`, and all sound is synthesized at runtime
(no `.wav`/`.mp3` files, no SDL_mixer dependency).

## Quick start (on a Mac with MacPorts)

```bash
./build.sh
```

That's it. The script installs what it needs via MacPorts (`libsdl2`,
`mingw-w64`, `pkgconfig` — it'll prompt for your password via `sudo port
install` if any are missing), downloads the official SDL2 Windows dev
package the first time it's needed, and produces:

```
dist/mac/Quorador.app        <- double-click to play on macOS
dist/windows/Quorador.exe    <- copy to any Windows 7 SP1+ / 8 / 10 / 11 PC
```

Both binaries are self-contained:
- `Quorador.app` bundles `libSDL2.dylib` inside `Contents/Frameworks`, so it
  runs even on a Mac without Homebrew/SDL2 installed.
- `Quorador.exe` is statically linked (`-static -static-libgcc
  -static-libstdc++` + SDL2's static libs), so it needs no `SDL2.dll` or
  MinGW runtime DLLs on the target PC — just copy the one `.exe` and run it.

## Project layout

```
src/
  Core.hpp       game rules, pathfinding (BFS), AI (easy/medium/hard) -- no
                 platform dependencies, unit-tested in isolation
  Types.hpp      shared Color struct
  Draw.hpp       rounded rects / gradients / glow, built from plain SDL2
                 fill-rect + fill-circle calls (no SDL2_gfx dependency)
  FontData.hpp   generated bitmap-font glyph table (see tools below)
  Font.hpp       text rendering using FontData.hpp
  Audio.hpp      procedural tones via a raw SDL audio callback (no
                 SDL_mixer, no sound files)
  Particles.hpp  victory-burst particle system
  Storage.hpp    settings + in-progress-game persistence (plain text file
                 under the OS-standard per-user config directory)
  App.hpp        screens, input, layout, rendering, AI turn orchestration
  main.cpp       entry point
  tests/
    test_core.cpp  standalone unit tests for Core.hpp (see below)
CMakeLists.txt   optional: for IDE integration / non-macOS builds
build.sh         the macOS build described above
```

## Running the unit tests

`Core.hpp` has zero platform dependencies, so its rules/pathfinding/AI logic
can be tested without SDL2 at all:

```bash
g++ -std=c++17 -O2 -o test_core src/tests/test_core.cpp
./test_core
```

This checks: initial path lengths, legal-move generation, the "a wall may
never fully block a player's only path" rule (including a constructed
4-wall trap scenario where the 4th wall is correctly rejected), straight and
side jumps over an adjacent opponent, and several full AI-vs-AI self-play
games across all three difficulties asserting every move/wall the AI plays
is legal.

All of this was run and passed during development of this build, along with
headless rendering smoke tests (SDL2 running under Xvfb, screenshotted and
inspected) that caught and fixed two real bugs before shipping:

1. The AI's "step along the shortest path" logic could suggest moving onto
   the square the opponent currently occupies (BFS ignores pawn occupancy),
   which isn't a legal plain move. Fixed with a `safeMoveTowardGoal`
   resolver that falls back to whichever legal move (i.e. the jump) most
   shortens the AI's path.
2. A HUD layout bug where the turn-indicator text and the move/wall mode
   toggle buttons occupied the same screen region, causing button corners
   to show slivers of text underneath. Fixed by giving the bottom bar two
   properly-spaced rows.

## A note on Windows 7

Windows 7 (SP1) is included in the target list, and the build is set up to
support it as far as the toolchain allows:

- We deliberately avoid any C# / .NET build path, because .NET 5+ dropped
  Windows 7 support outright, and .NET Framework can't be cross-compiled
  from macOS without extra tooling (Mono/Wine). SDL2 + mingw-w64 is the
  combination that actually lets you cross-compile a real Win7-compatible
  binary from a Mac.
- The SDL2 version pinned in `build.sh` (2.30.6) still targets Windows
  Vista/7+ at the API level.
- That said, Windows 7 is out of Microsoft's support lifecycle, and we have
  no way to test on real Windows 7 hardware/VMs from this environment. If
  you can test on an actual Windows 7 SP1 machine, please treat that as the
  final word — if it doesn't launch there, the most likely culprit is a
  missing Windows Update (Win7 needs the [Platform Update /
  KB2670838](https://www.microsoft.com/en-us/download/details.aspx?id=36805)
  for full DirectX/graphics support) rather than something in this code.
- Windows 8, 8.1, 10, and 11 are all well within modern SDL2/mingw-w64's
  supported range and should work with no caveats.

## How the mingw-w64 threading variant matters

`Audio.hpp` uses `std::mutex`/`std::thread` primitives, which require the
**posix-threads** variant of mingw-w64 (not the default `win32-threads`
variant some Linux distros ship). MacPorts' `mingw-w64` port builds the
posix-threads variant, so `build.sh` should just work. If you ever see
compiler errors mentioning `__gthread_cond_t` while cross-compiling, your
`x86_64-w64-mingw32-g++` is a win32-threads variant -- try `sudo port
reinstall mingw-w64` or check `port variants mingw-w64` for a
posix-threads-enabled variant to select.

## Controls

- Mouse/touch: click a highlighted square to move, or switch to Wall mode
  and click a wall slot to place a wall.
- Arrow keys / WASD: move.
- `R`: rotate wall orientation (while in Wall mode).
- Right-click: also rotates wall orientation.
- `Esc`: open the menu.

## Customizing

- Palette lives in the `quorador::palette` namespace at the top of
  `App.hpp`.
- Font glyphs are generated data in `FontData.hpp` — regenerate/extend them
  by editing the Python generator described in the comment at the top of
  that file's source history, or just hand-edit the bit patterns (7 rows,
  5 bits each, MSB = leftmost pixel).
- To ship an app icon, add a `.icns` (mac) / `.ico` (Windows) and wire it
  into `Info.plist` / the mingw resource-compiler step — left out here
  since the brief asked for no external asset files.
