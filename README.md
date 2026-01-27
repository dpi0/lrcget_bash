# `lrcget_bash`

Fetch lyrics using the LRCLIB API.

> [!TIP]
> Make sure to have decently accurate metadata in your tracks before using this script.
>
> As it relies only on the metadata tags present in the track itself. Like "Title", "Artist", "Album" and "Duration".
>
> See more below on how this script works.

## Quickstart - Using Docker

The built docker image is of two types: one with `kid3` package and another one without it.

If you intend to use the `--embed` flag in the script to embed lyrics in your tracks, then use the image tagged with `:*-embed` at the end.

> [!IMPORTANT]
> I had to split the image into two versions as `kid3` wasn't available as it's CLI `kid3-cli` counterpart in alpine packages.
>
> And `kid3` is the full-fledged GUI package bloating the image.

So pull the base (no `kid3` package) image (around 55-60 MB)

```bash
docker pull ghcr.io/dpi0/lrcget_bash:latest
```

Make sure to map the directories properly where your tracks/directories are present, otherwise the docker container won't be able to find your tracks.

Say your albums/playlists/singles are present in `/mnt/Library/Music`.

To fetch the lyrics for an input track using the `--song` option

```bash
docker run --rm \
  -v "/mnt/Library/Music/Albums:/mnt/Library/Music/Albums" \
  ghcr.io/dpi0/lrcget_bash:latest \
  --song /mnt/Library/Music/Albums/Handsomeboy\ Technique/\[2005\]\ Adelie\ Land\ \[MP3\]/10\ Your\ Blessings.mp3
```

This will try to fetch the synced lyrics for this track, save it in a `.lrc` file right next to the track and exit.

To fetch lyrics for the whole directory, use the `--dir` option

```bash
docker run --rm \
  -v "/mnt/Library/Music/Albums:/mnt/Library/Music/Albums" \
  ghcr.io/dpi0/lrcget_bash:latest \
  --dir /mnt/Library/Music/Albums/Handsomeboy\ Technique/\[2005\]\ Adelie\ Land\ \[MP3\]
```

For all available options see below.

## Quickstart - Using Script

### Requirements

The script requires the following packages to be present on your Linux distro: `jq` ≥ 1.5, `ffmpeg` ≥ 3.2 (for `ffprobe`), `curl` ≥ 7.40.

Core Linux utilities requirements present almost in every distro include `bash` ≥ 4.0, `coreutils` ≥ 8.20, `findutils` ≥ 4.6 (for `find`) and `util-linux` ≥ 2.25 (for `xargs`).

For embedding lyrics into tracks you will need either the `kid3-cli` or `kid3` ≥ 3.5 package.

The exact package names will vary based on your distro's package manager.

### Usage

Download the script `lrcget_bash.sh` and ideally save it somewhere in your shell `$PATH`.

To fetch lyrics for a track and save it as `.lrc` or `.txt` right next to it

```bash
lrcget_bash.sh --song /mnt/Library/Music/Albums/Ninajirachi/\[2025\]\ I\ Love\ My\ Computer\ \[AAC\]/09\ Battery\ Death.m4a
```

For an entire directory

```bash
lrcget_bash.sh --dir /mnt/Library/Music/Albums/Ninajirachi/\[2025\]\ I\ Love\ My\ Computer\ \[AAC\]
```

## But Why Is This Needed When `tranxuanthang/lrcget` Exists?

I used [lrcget](https://github.com/tranxuanthang/lrcget) extensively and felt that

- The GUI approach felt clunky and slow UX.
- I couldn't run it on my home-server for automation.
- I wasn't able to force only synced lyrics (basically specify what type of lyrics i need).
- I couldn't embed lyrics or replace them.
- The lyric fetching didn't feel accurate enough and it constantly missed a lot of tracks.

This script, although not perfect fits better for my usecase of automation and good enough accuracy.

This script was also inspired by this article I read about 2 months back <https://leshicodes.github.io/blog/spotify-migration/#synced-lyrics-lrcget-kasm>.

## How Does This Work?

1. The script uses `ffprobe` to fetch `Title`, `Artist`, `Album` and `Duration` fields from the input track.
2. It then makes an `/api/get` request using these fields. Like for the track "claws - Charli xcx.m4a" with this metadata,

    `Title` = 'claws'
    `Album` = 'how i’m feeling now'
    `Artist` = 'Charli XCX'
    `Duration` = '149 sec'

    ```bash
    curl -s \
    -A "lrcget_bash (https://github.com/dpi0/lrcget_bash)" \
    --retry 3 --retry-delay 1 --max-time 30 \
    "https://lrclib.net/api/get?track_name=claws&artist_name=Charli%20XCX&album_name=how%20i%E2%80%99m%20feeling%20now&duration=149"
    ```
3. It uses the JSON response and fetches either the `plainLyrics` or the `syncedLyrics` field and saves it content in the desired place (embedded or external file).
    ```json
    {
      "id": 315361,
      "name": "claws",
      "trackName": "claws",
      "artistName": "Charli XCX",
      "albumName": "how i'm feeling now",
      "duration": 149.0,
      "instrumental": false,
      "plainLyrics": "<HIDDEN>",
      "syncedLyrics": "<HIDDEN>"
    }
    ```
4. If if finds the response is not the one user asked for, it then makes an `/api/search` request.
5. For the response JSON array, it uses the one with the least duration difference with the original track.
6. And again uses the `plainLyrics` or `syncedLyrics` to embed or store the lyric in an external file.

## Options

`--sync-only` - To fetch only the synced/timestamped lyrics.

```bash
lrcget_bash.sh --song --sync-only /path/to/file.mp3
```

---

`--text-only` - To fetch only plaintext lyrics with no timestamp. `--sync-only` and `--text-only` are mutually exclusive.

```bash
lrcget_bash.sh --song --text-only /path/to/file.mp3
```

---

`--force` - To overwrite/replace existing lyrics (either it be in external file or embedded).

Otherwise, script will skip the track if, track has embedded lyrics (synced or plain) or track has external file lyrics (.lrc or .txt).

> [!CAUTION]
> This is will overwrite your existing lyrics. So backup your files before proceeding if unsure.

```bash
lrcget_bash.sh --song --force /path/to/file.mp3
```

---

`--no-instrumental-lrc` - By default the script will create a `.lrc` file with this content `[00:00.00] ♪ Instrumental ♪` if it encounters an Instrumental track.

This option prevents this behavior.

Also it is independent of `--text-only` and `--sync-only`.

```bash
lrcget_bash.sh --song --no-instrumental-lrc /path/to/file.mp3
```

---

`--cached` - By default the script uses the `/api/get` endpoint to fetch lyrics and uses `/api/search` as a fallback.

This option instead uses the `/api/get-cached` endpoint first instead and then falls back to `/api/search`.

```bash
lrcget_bash.sh --song --cached /path/to/file.mp3
```

---

`--embed` - By default the script will always create an external `.lrc` or `.txt` file with the same name as the track.

This option will place the fetched lyrics in the `Lyrics`/`lyrics` metadata of the track using the `kid3-cli`.

`kid3-cli` does not touch the audio stream. You will not lose quality when using this.

> [!WARNING]
> This will however overwrite the `Lyrics` metadata tag of your tag, which is kinda annoying to reverse.
>
> So proceed if you understand how to reverse this OR ideally take a backup.

```bash
lrcget_bash.sh --song --embed --sync-only --force /path/to/file.mp3
```

---

`--server <url>` - By default the script uses `https://lrclib.net` server address URL for the LRCLIB API.

You can set a custom self-hosted address with this.

```bash
lrcget_bash.sh --song --server "http://10.0.0.10:3300" --force /path/to/file.mp3
```

---

`--debug` - Adds additional standard output for the response CMD and the response JSON so you can manually verify why something isn't working.

```bash
lrcget_bash.sh --dir --debug /path/to/directory
```

---

`--jobs <1-15>` - Set an integer value for the number of parallel processes to spawn via `xargs`.

Default number is `8`.

```bash
lrcget_bash.sh --song --jobs 5 --text-only --force /path/to/file.mp3
```
