---
name: sap-video-translate
description: Download a SAP internal video (video.sap.com / Kaltura) or a public YouTube/online video and produce English (or any target language) subtitles and a subtitled video using VideoLingo. Handles access-controlled SAP videos by harvesting a Kaltura session (ks) token via the Playwright MCP browser. Auto-installs its own dependencies (clones VideoLingo, creates the uv Python 3.12 env, checks ffmpeg, sets the HuggingFace mirror). Use when the user wants to translate/subtitle a SAP video, a video.sap.com link, a Kaltura video, or a YouTube/online video to English, or says "translate this video", "add English subtitles", "字幕", "翻译视频".
---

# SAP Video → English Subtitles (VideoLingo)

Turn a SAP internal video (`video.sap.com`) or a public online video into a
subtitled video + SRT files, source language auto-detected and translated to a
target language (default English). Wraps the VideoLingo pipeline and adds the
one piece SAP videos need that plain yt-dlp can't do: a session-bound Kaltura
`ks` token harvested from the authenticated Playwright MCP browser.

## When to use

- "Translate this SAP video to English" / "add English subtitles"
- A `https://video.sap.com/...` or Kaltura link
- A YouTube / other online video link, or a local media file
- "翻译这个视频 / 加英文字幕 / 字幕"

## Prerequisites this skill installs or verifies automatically

Run the bootstrap first (idempotent — safe to re-run):

```bash
bash <skill_dir>/scripts/bootstrap.sh
```

It will, only when missing:
1. **uv** — the Python launcher VideoLingo uses (install via the official script if absent).
2. **VideoLingo repo** — clones `https://github.com/velocityX-br/VideoLingo` to
   `~/Workdir/Github/VideoLingo` (or reuses an existing clone; override with
   `VIDEOLINGO_DIR`). The `velocityX-br` fork carries the SAP/Kaltura support.
3. **VideoLingo Python 3.12 env** — runs `uv run start.py --check`, which triggers
   VideoLingo's own `setup_env.py` to build `.venv` with all ASR/translate deps.
4. **ffmpeg** — required for audio extraction + subtitle burning. On macOS installs
   via Homebrew; on Linux prints the apt/zypper command (does not sudo-install silently).
5. **HuggingFace mirror** — ensures `HF_ENDPOINT=https://hf-mirror.com` is in `~/.zshrc`
   and exports it for the current run (huggingface.co is blocked on the SAP network).

The script prints a summary and exits non-zero if a hard dependency it cannot
auto-install (e.g. ffmpeg on Linux without sudo) is still missing.

**Playwright MCP browser** (only needed for *access-controlled* SAP videos): this
is an MCP server configured in Claude Code, not a pip package. The skill uses the
`mcp__playwright-headed__*` tools directly — no install needed. If those tools are
not available, tell the user to enable a Playwright MCP server (headed, with their
SAP SSO session) and re-invoke.

## Decision: which download path?

```
Is the URL a video.sap.com / Kaltura link?
├─ No  → public/local path: let VideoLingo download it directly (Step B-public).
└─ Yes → try the direct path first; if it 404s, it is access-controlled → ks path (Step B-sap-ks).
```

Most SAP videos are access-controlled, so expect the ks path.

## Workflow

### Step A — Bootstrap (always)

```bash
bash <skill_dir>/scripts/bootstrap.sh
```

Capture the printed `VIDEOLINGO_DIR` — all later commands run from there. If the
user gives a target language other than English, update it:

```bash
cd "$VIDEOLINGO_DIR"
uv run python -c "from core.utils import update_key; update_key('target_language','<LANG>')"
uv run python -c "from core.utils import update_key; update_key('whisper.language','auto')"
```

### Step B-public — Download a public / online video

```bash
cd "$VIDEOLINGO_DIR"
HF_ENDPOINT=https://hf-mirror.com uv run python -c "
from core._1_ytdlp import download_video_ytdlp, find_video_files
download_video_ytdlp('<URL>', resolution='1080')
print('DOWNLOADED:', find_video_files())
"
```

If this fails with a sign-in / 403 error for a SAP URL, fall through to Step B-sap-ks.

### Step B-sap-ks — Download an access-controlled SAP video (ks via MCP browser)

A SAP Kaltura entry rejects every media URL with **HTTP 404** unless the request
carries a `ks` token minted inside the *authenticated* browser session. The
anonymous Kaltura widget-session ks (plain HTTP) is **not** authorized. So harvest
the real ks from the Playwright MCP browser:

1. **Open the page** (the MCP browser carries the user's SAP SSO):
   ```
   mcp__playwright-headed__browser_navigate(url="https://video.sap.com/media/t/<entryId>")
   ```
   The playable entry id is the **last** `1_...` segment of the URL (for a
   `/playlist/dedicated/.../A/B` URL, use `B`).

2. **List Kaltura requests** and read the `ks` from any of them (they share the
   session token; thumbnail requests appear even before playback):
   ```
   mcp__playwright-headed__browser_network_requests(filter="kaltura", static=true)
   ```
   Find a URL like `.../thumbnail/.../ks/<TOKEN>` or `.../playManifest/...?ks=<TOKEN>`.
   The token is long and starts with `djJ8`. Copy the whole value (up to the next
   `/` or `&`). If none appear, trigger playback (click the player) and re-list.

3. **Download** via the bundled helper, passing the URL and the ks:
   ```bash
   cd "$VIDEOLINGO_DIR"
   HF_ENDPOINT=https://hf-mirror.com uv run python \
     "<skill_dir>/scripts/sap_ks_download.py" "<SAP_URL>" "<KS_TOKEN>"
   ```
   The helper builds the authorized `applehttp` manifest URL, downloads the best
   ≤1080p rendition, sanitizes the filename, and writes `output/input_manifest.json` —
   exactly the state the pipeline expects.

**ks tokens expire** (short-lived). If the download 404s, re-harvest a fresh ks
(repeat 1–2) and retry immediately.

### Step C — Run the subtitle pipeline

```bash
cd "$VIDEOLINGO_DIR"
HF_ENDPOINT=https://hf-mirror.com uv run python run_pipeline.py subtitles
```

This runs ASR (auto-detects source language) → NLP split → translate → generate
SRT → burn subtitles. On first run it downloads ASR models via the HF mirror
(can take a while). Outputs land in `output/`:
- `output/src.srt` — source-language subtitles
- `output/trans.srt` — translated subtitles
- `output/output_sub.mp4` — video with burned-in subtitles

Report these paths to the user when done. For dubbing (optional), run
`uv run python run_pipeline.py dubbing` afterwards.

### Step C2 — Archive the artifacts (always, before processing the next video)

VideoLingo always writes to the single `output/` directory, so the next video
would overwrite it. Archive each run into its own timestamped folder so nothing
is ever lost:

```bash
cd "$VIDEOLINGO_DIR"
bash "<skill_dir>/scripts/archive_output.sh" --label "<short-video-name>"
```

This copies everything in `output/` to
`artifacts/<label>_<YYYYmmdd-HHMMSS>/` and prints the path (last line
`ARTIFACT_DIR=...`). It never deletes or overwrites earlier archives — each run
gets a fresh timestamped folder. `--label` is optional (defaults to the
downloaded video's filename). Add `--move` to move instead of copy (frees disk
space and leaves `output/` empty, ready for the next video). Report the
`ARTIFACT_DIR` to the user.

### Step D — (Optional) Interactive UI

To let the user drive it in a browser instead of CLI:
```bash
cd "$VIDEOLINGO_DIR"
HF_ENDPOINT=https://hf-mirror.com uv run start.py
```
Then paste the URL under "a. Download or Upload Video" and click through. (Public
SAP/YouTube videos work entirely in the UI; access-controlled SAP videos still
need the ks path above, since the UI can't harvest the token.)

## Fresh-start / re-run

Each video reuses `output/`. **Always archive first** (Step C2) so previous
results are preserved, then clear `output/` for the next video:
```bash
# 1. archive the finished run into artifacts/<label>_<timestamp>/
bash "<skill_dir>/scripts/archive_output.sh" --label "<short-video-name>"
# 2. then clear output/ for a clean next run
rm -rf "$VIDEOLINGO_DIR/output"
```
Or run the archive with `--move`, which empties `output/` as it archives, so no
separate `rm -rf` is needed. Never run `rm -rf output` *before* archiving — that
is what used to discard prior results. Each archive folder is timestamped and is
never overwritten.

## Notes & limits

- **ks cannot be automated headlessly**: it is JS-minted per authenticated session;
  only a real logged-in browser (the MCP browser) yields an authorized token. This
  is why Playwright-in-venv is intentionally *not* used.
- **SAP network**: `huggingface.co` and some PyPI CDNs are throttled/blocked; the
  skill relies on `HF_ENDPOINT=https://hf-mirror.com` and uv's resolver. If model
  downloads stall, confirm the mirror env var is exported.
- **Target language**: set via `target_language` in `config.yaml` (Step A). Source
  language stays `auto`.
- Treat the downloaded video and its content as internal/confidential; do not
  upload it anywhere outside the user's machine.

## Bundled files

- `scripts/bootstrap.sh` — idempotent dependency installer/verifier.
- `scripts/sap_ks_download.py` — ks-authenticated Kaltura downloader (writes the
  VideoLingo input manifest).
- `scripts/archive_output.sh` — archives each run's `output/` into a timestamped
  `artifacts/<label>_<timestamp>/` folder so results are never overwritten.
