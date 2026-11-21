# Sprites

- `den.png`, `den_off.png`: copied unchanged from the web game
  (`Robocog---Frontend/web/public/game`).
- `kelp.png`, `sea-fan.png`: the web game's plants, converted to true pixel art on Garry's grid.
  Originals in `source/`.
- `garry-*.png`, `shell-*.png`: generated with `gemini-3-pro-image` on 15 Nov 2026, using the
  web game's `lobster-1.png` as the character reference, then converted to true pixel art.
  The raw sheets are in `source/` (`garry-sheet.jpg` is the second, 16-frame sheet).

## Regenerating

The raw sheets look like pixel art but are soft and off-grid. `../tools` keys out the magenta
backdrop and the cell rules, finds each frame's real pixel grid, re-samples to one colour per
pixel, limits the palette, aligns the Garry frames on a shared baseline, doubles them with
Scale2x and stamps a clean numeral on the cap. Output is deterministic.

    cd ../tools
    mkdir -p /tmp/garry-src /tmp/garry-out
    sips -s format png ../Sprites/source/garry-sheet.jpg --out /tmp/garry-src/garry-sheet.png
    sips -s format png ../Sprites/source/shell-sheet.jpg --out /tmp/garry-src/shell-sheet.png
    cp ../Sprites/source/kelp.png ../Sprites/source/sea-fan.png /tmp/garry-src/
    xcrun swiftc -O pix.swift main.swift -o /tmp/convert
    /tmp/convert /tmp/garry-src /tmp/garry-out

Then copy `garry-*.png`, `shell-*.png`, `kelp.png` and `sea-fan.png` from the output into this
folder. `check.png` in the output shows every frame at a glance.

Frames with a shell painted in (carry, grip, push) have it removed so `DenView` can draw
whichever shell he picked up. The hold positions the tool prints are the constants in
`DenView`. Frames he uses facing left have a mirrored `-left` copy, stamped after mirroring
so the numeral reads the right way round.

## Web game

The same run writes `web/` in the output folder: Garry's idle and walk frames at the game's
exact 75 x 71 draw size, facing right and left, and the eight shells at 26 x 22. Copy those
into `Robocog---Frontend/web/public/game/`.

## Picker thumbnail

`../thumbnail.png` (90 x 58) and `../thumbnail@2x.png` (180 x 116) are the tile System Settings
shows. They are a crop of the den scene itself, rendered at 4 pixels per scene unit a few
seconds after a burst of test activity events, then scaled down.
