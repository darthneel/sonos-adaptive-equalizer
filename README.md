# Sonos EQ Daemon (Ruby)

Small local daemon that:
- discovers Sonos players on your Wi-Fi (SSDP),
- reads now-playing metadata,
- infers genre,
- applies `bass`, `treble`, and `loudness` presets per room,
- learns your manual Sonos-app EQ tweaks as song overrides.

Mutable application state is stored in SQLite. `config/settings.yml` is runtime/bootstrap config.
The few remaining YAML writes use atomic replace semantics.

## Requirements

- Ruby 3.2+ recommended
- Sonos devices reachable on the local network

## Setup

First-time setup:

```bash
bundle install
cp config/settings.example.yml config/settings.yml
```

## Run

Then start the daemon:

```bash
chmod +x bin/sonos_eq_daemon
bin/sonos_eq_daemon
```

Single cycle (safe smoke test):

```bash
bin/sonos_eq_daemon --once
```

Custom config:

```bash
bin/sonos_eq_daemon --config /path/to/settings.yml
```

## Test

```bash
rake test
```

## Config

Edit `config/settings.yml`:
- `target_rooms`: empty means all discovered rooms.
- `storage.db_path`: SQLite database path for mutable state.
- `network.poll_interval_sec`: how often to poll now-playing.
- `network.apply_cooldown_sec`: minimum seconds between EQ writes per room.
- `network.manual_override_debounce_sec`: required stability window before a manual change is learned.
- `network.sync_target_rooms_on_startup`: when true, discovered rooms are synced into `target_rooms` at startup (add-only, non-destructive).
- `network.sync_target_device_ids_on_startup`: when true, discovered Sonos IDs (UDN) are synced into `target_device_ids` at startup (add-only).
- `network.sync_devices_registry_on_startup`: when true, `devices` registry is refreshed with `room_name`, `model_name`, and `ip` for readability.
- `home_theater_music.enabled`: when true, track/apply HT music controls on configured rooms.
- `home_theater_music.rooms`: room names where HT controls are active (for example `Living Room`).
- `target_device_ids`: stable Sonos IDs (`uuid:RINCON_...`) used for resilient targeting even if room names change.
- `devices`: discovered device registry keyed by Sonos ID for human-friendly mapping.
- `genre_lookup`: external genre enrichment (`lastfm -> musicbrainz -> itunes`) with local cache.
- `genre_lookup.lastfm.api_key` or `genre_lookup.lastfm.api_key_env` (`LASTFM_API_KEY`) for Last.fm lookups.
- `genre_lookup.max_cache_size_bytes`: max cache size before compaction (default 5MB).
- `genre_lookup.compact_to_ratio`: compaction target fraction (default `0.6`) after max size is exceeded.
- `genres.<name>.match`: keywords for fallback genre inference.
- `genres.<name>.bass|treble|loudness`: EQ preset to apply.
- `overrides`: auto-learned and manually editable high-specificity presets.

`defaults`, `genres`, `devices`, and `overrides` in YAML are now bootstrap data for first DB import. After the SQLite DB exists, the daemon reads mutable state from the DB.

## Repo Hygiene

- Commit `config/settings.example.yml`
- Do not commit `config/settings.yml`
- Do not commit SQLite or cache artifacts under `config/data` or `config/tmp`
- `sqlite3` is managed through the repo `Gemfile`

`bass` and `treble` are clamped to Sonos range `-10..10`.

## Notes

- If track metadata includes a declared genre, that is used first.
- If not, the daemon falls back to keyword matching against title/artist/album/URI.
- If still unknown, it queries external providers in order (`lastfm`, `musicbrainz`, `itunes`) and caches results in `genre_lookup.cache_path`.
- Raw provider genres/tags are normalized into a fixed canonical app genre set before preset selection.
- Only successful genre lookups are cached.
- Cache eviction: TTL expiry on read plus size-based compaction (oldest `seen_at` entries evicted when cache exceeds `max_cache_size_bytes`).
- Preset precedence is: `song+device` -> `song` -> `artist` -> `genre` -> `default`.
- If you change EQ in the Sonos app and it remains stable for `manual_override_debounce_sec`, the daemon writes a `song+device` override into SQLite.
- Learned overrides are stored in SQLite using device IDs (Sonos UDNs).
- Legacy YAML bootstrap data is imported into SQLite on first run.
- For configured HT rooms, learned/applied presets can also include `sub_gain` and `surround_level` (mapped to Sonos `SubGain` and `SurroundLevel`).
- The daemon skips EQ writes for playback that does not look like identifiable music content.
- Home theater music controls are only touched when the source looks like music, not TV input.
- On track change, the daemon performs an end-of-song finalize pass for any pending learned override candidate.
- Startup sync is safe: it only adds newly discovered entries (`target_rooms`, `target_device_ids`, `devices`) and never removes existing entries or overwrites `overrides`.
- Remaining startup config sync writes (`target_rooms`, `target_device_ids`) are persisted atomically.
- Safety: volume-changing SOAP actions are blocked in code (`SetVolume`, `SetRelativeVolume`, `SetVolumeDB`, `SetRelativeVolumeDB`).
- This uses local Sonos UPnP APIs only and does not require Sonos cloud auth.
