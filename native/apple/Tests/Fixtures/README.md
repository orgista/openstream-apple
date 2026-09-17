# OpenStream Test Fixtures

This directory holds the media fixtures and the loopback fixture server used by
the playback-engine tests (T3).  The fixtures exercise every route the
AetherEngine route policy can choose:

- `remoteBypass` – AVPlayer can play the origin directly.
- `loopback` – the engine remuxes the source to a local fMP4-HLS feed for
  AVPlayer.
- `nativeRemoteHLS` – AVPlayer plays an HLS playlist from the origin.
- `software` – libavcodec decodes because AVPlayer cannot handle the codec or
  scan type.

## Fixture matrix

| File | Expected route | What it proves |
|------|----------------|----------------|
| `mp4-h264-aac.mp4` | `remoteBypass` | Plain MP4/H.264/AAC goes straight to AVPlayer. |
| `ts-h264-aac.ts` | `loopback` | MPEG-TS H.264/AAC is remuxed to fMP4-HLS. |
| `ts-h264-interlaced-ac3.ts` | `software` | Interlaced H.264 + AC-3 5.1 needs software decode. |
| `ts-mpeg2-interlaced-mp2.ts` | `software` | MPEG-2 interlaced + MP2 is not supported by AVPlayer. |
| `mkv-h264-aac.mkv` | `loopback` | Matroska H.264/AAC is remuxed. |
| `mkv-hevc-eac3.mkv` | `loopback` | Matroska HEVC + E-AC3 5.1 is remuxed with passthrough. |
| `mkv-hevc-truehd.mkv` | `software` | TrueHD is not handled by AVPlayer. |
| `mkv-hevc-dts.mkv` | `software` | DTS is not handled by AVPlayer. |
| `mkv-vp9-opus.mkv` | `software` | VP9 needs software decode. |
| `hdr10-hevc.mp4` | `remoteBypass` | HDR10 HEVC plays natively. |
| `dv81-hevc-eac3.mp4` | `remoteBypass` | Dolby Vision profile 8.1 MP4 keeps Apple's DV pipeline. |
| `dv81-hevc-eac3.mkv` | `loopback` | DV profile 8.1 in Matroska is remuxed to MP4-compatible RPU. |
| `hls/index.m3u8` + `hls/seg%03d.ts` | `nativeRemoteHLS` | HLS VOD playlist played natively. |
| `private/dv5-sample.mkv` | `loopback` | Owner-provided Dolby Vision profile 5 sample. |
| `private/atmos-joc-sample.mp4` | `remoteBypass` | Owner-provided E-AC3-JOC (Atmos) sample. |

## Generating fixtures

```bash
bash Tests/Fixtures/make-fixtures.sh
```

The script is idempotent: existing files are skipped unless you pass `--force`.
If an encoder is unavailable (e.g. `libx264`, `libvpx-vp9`, `libopus`), the
missing file is recorded in `out/SKIPPED.txt` and generation continues.

## Running the fixture server

```bash
python3 Tests/Fixtures/serve.py
```

The server binds `127.0.0.1` and prints:

```
fixtures listening on 127.0.0.1:8765
```

Options:

- `--port N` – listen on port `N` (default `8765`).
- `--root <dir>` – serve fixtures from `<dir>` (default `Tests/Fixtures/out`).

### Routes

| Route | Behaviour |
|-------|-----------|
| `GET /media/<name>` | Static file from `out/`. Supports `Range` requests (`206 Partial Content`). Content-Type is set by extension. |
| `GET /live/<name>.ts` | Loops the `.ts` file forever using chunked transfer, paced at ~1.5 MB/s, with no `Content-Length`. |
| `GET /slow/<name>` | Sleeps 12 s, then behaves like `/media/<name>`. |
| `GET /protected/<name>` | Returns `403 referer required` unless `Referer` begins with `https://fixtures.local/`; then serves like `/media/<name>`. |
| `GET /hls/<path>` | Static file from `out/hls/`. |
| anything else | `404 not found` |

## How the tests find the server

Engine fixture tests are gated behind `PLAYBACK_ENGINE_TESTS=1`.  The base URL
defaults to `http://127.0.0.1:8765` and can be overridden with
`FIXTURE_BASE_URL`:

```bash
export PLAYBACK_ENGINE_TESTS=1
export FIXTURE_BASE_URL="http://127.0.0.1:8765"
python3 Tests/Fixtures/serve.py &
swift test --scratch-path "$HOME/Library/Caches/openstream-lane/.build" --filter ApplePlaybackEngineFixtureTests
```

## Private samples

Owner-provided samples live in `Tests/Fixtures/private/` (gitignored).  The
generator prints which of `dv5-sample.mkv` and `atmos-joc-sample.mp4` are
present; missing samples are skipped by the tests that use them.
