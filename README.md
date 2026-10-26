# Auction — a Bot Party mod

A game mode for [Bot Party](https://github.com/AnCarsenat/bot-party)'s party
mode: instead of grabbing cards first come, first served, the cards are sold
one at a time. Everyone gets 5 coins a round (30 at most); jump to bid one coin
more. Cards nobody buys go to whoever has none.

## Install

In the game: **Mods → Explore → Auction**. Or download `auction.pck` from the
[latest release](../../releases/latest) and put it in the game's mods folder
(**Mods → Open mods folder**), then switch it on in **Mods**.

Then pick it in **Party → Rules → Mode**. Online, the host sends the mod to
players who don't have it.

## How it works

`auction.gd` extends the game's `PartyMode` and sets `custom_pick = true`, so it
hands out the cards itself in `pick_started` / `process_pick`. See
[MODDING.md](https://github.com/AnCarsenat/bot-party/blob/main/MODDING.md#game-modes).

Releases are made by GitHub Actions: raise `version` in `mod.json`, then
`git tag v1.1 && git push origin v1.1`.

## License

[GNU GPL version 3](LICENSE), like Bot Party's code.
