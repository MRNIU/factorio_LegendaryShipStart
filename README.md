# Legendary Ship Start

A Factorio 2.0 mod that pre-builds a fleet of legendary space platforms around Nauvis when a new game starts.

## Features

- **Instant fleet**: on the first game load the mod creates multiple pre-configured space platforms over Nauvis — a starter ship, several late-game freighters, a white-science platform, calcite transports, a shop ship, and a biter-egg platform.
- **Idempotent**: if a platform with the same name already exists on the player force the mod skips it, so reloading or migrating saves is safe.
- **Forced placement**: blueprints are applied with `build_mode.forced`, so tile-connectivity checks and other build-time restrictions don't break platforms that legitimately span gaps.
- **Item requests honoured**: modules, filters, fuel, and other embedded requests encoded in the blueprints are delivered directly into the revived entities.

## Disclaimer

Blueprints bundled with this mod come from the Factorio community. All credit belongs to the original blueprint authors.

## Compatibility

- Factorio 2.0.55 or newer.
- Requires `base`, `space-age`, `quality`.

## License

MIT — see [LICENSE](LICENSE).

## Author

- **NZH** — zhihong@nzhnb.com
- Repository: <https://github.com/MRNIU/factorio_LegendaryShipStart>

## Changelog

See [changelog.txt](changelog.txt).
