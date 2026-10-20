# SAP Video Translate — Setup & Run Guide

Step-by-step guide to configure the **SAP Hyperspace AI** LLM endpoint, add your
API key, install the `sap-video-translate` Claude Code skill, and run it to turn
a SAP internal video (`video.sap.com` / Kaltura) or any public/YouTube video into
subtitled output with English (or any target-language) SRT files.

> **Audience:** SAP engineers on the SAP corporate network using Claude Code on
> macOS (Apple Silicon) or Linux.

---

## Table of contents

1. [What you get](#1-what-you-get)
2. [Prerequisites](#2-prerequisites)
3. [Configure SAP Hyperspace AI (local LLM endpoint)](#3-configure-sap-hyperspace-ai-local-llm-endpoint)
4. [Add your API key to VideoLingo](#4-add-your-api-key-to-videolingo)
5. [Install the `sap-video-translate` skill](#5-install-the-sap-video-translate-skill)
6. [Run it in Claude Code](#6-run-it-in-claude-code)
7. [How the pipeline works](#7-how-the-pipeline-works)
8. [Output & archiving](#8-output--archiving)
9. [Troubleshooting](#9-troubleshooting)
10. [Security notes](#10-security-notes)

---

## 1. What you get

| Input | Output |
|-------|--------|
| A `https://video.sap.com/...` link (access-controlled) | `output/output_sub.mp4` (burned-in subtitles) + `output/src.srt` + `output/trans.srt` |
| A YouTube / public video link | same |
| A local media file | same |

Source language is **auto-detected**; the target language defaults to **English**
(configurable). SAP videos served via Kaltura need a short-lived session token
(`ks`), which the skill harvests from an authenticated Playwright MCP browser —
see [step 6](#6-run-it-in-claude-code).

---

## 2. Prerequisites

The skill's `bootstrap.sh` installs/verifies most of these automatically, but you
need a few things in place first:

| Requirement | Why | Check |
|-------------|-----|-------|
| **Claude Code** | Runs the skill | `claude --version` |
| **git** | Clone VideoLingo | `git --version` |
| **ffmpeg** | Audio extract + subtitle burn | `ffmpeg -version` (macOS: `brew install ffmpeg`) |
| **uv** | Python 3.12 launcher (auto-installed) | `uv --version` |
| **SAP Hyperspace AI endpoint** | The LLM used for translation | see [step 3](#3-configure-sap-hyperspace-ai-local-llm-endpoint) |
| **Playwright MCP (headed)** | Only for access-controlled SAP videos | MCP server with your SAP SSO session |

The bootstrap also sets `HF_ENDPOINT=https://hf-mirror.com` (huggingface.co is
blocked/throttled on the SAP network) and clones the VideoLingo fork.

---

## 3. Configure SAP Hyperspace AI (local LLM endpoint)

VideoLingo calls an **OpenAI-compatible** chat endpoint for translation. On the
SAP network, you point it at your local **Hyperspace AI** proxy, which exposes an
OpenAI-compatible API on `localhost`.

### 3.1 Start the Hyperspace AI local proxy

Start the Hyperspace AI client/proxy so it listens locally. By default this guide
assumes it exposes an OpenAI-compatible API at:

```
http://localhost:6655/openai/v1
```

> If your proxy uses a different port or path, substitute it everywhere below.
> The endpoint must implement the OpenAI `/chat/completions` and `/models`
> routes.

### 3.2 Verify the endpoint is reachable

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:6655/openai/v1/models
```

- `HTTP 401` → the endpoint is **up** and simply wants your API key (good — proceed).
- `HTTP 200` → up and already authorized.
- `connection refused` / no response → the proxy is **not running**; start it first.

---

## 4. Add your API key to VideoLingo

VideoLingo reads LLM settings from `config.yaml` in the VideoLingo repo root
(`~/Workdir/Github/VideoLingo/config.yaml` by default).

Edit the `api:` block:

```yaml
# API settings
api:
  key: '<YOUR_HYPERSPACE_API_KEY>'        # e.g. a UUID issued by Hyperspace
  base_url: 'http://localhost:6655/openai/v1'
  model: 'gpt-4.1'                        # model name your Hyperspace proxy serves
  llm_support_json: true                  # Hyperspace supports JSON mode
```

And the language block (defaults shown):

```yaml
target_language: 'English'   # any natural-language name: 'Deutsch', '简体中文', ...

whisper:
  language: 'auto'           # auto-detect source language
```

You can set these from the CLI instead of editing by hand:

```bash
cd ~/Workdir/Github/VideoLingo
uv run python -c "from core.utils import update_key; update_key('api.key','<YOUR_HYPERSPACE_API_KEY>')"
uv run python -c "from core.utils import update_key; update_key('api.base_url','http://localhost:6655/openai/v1')"
uv run python -c "from core.utils import update_key; update_key('api.model','gpt-4.1')"
uv run python -c "from core.utils import update_key; update_key('target_language','English')"
uv run python -c "from core.utils import update_key; update_key('whisper.language','auto')"
```

> ⚠️ **Never commit your real key.** `config.yaml` is tracked in git. Keep the
> committed copy with a placeholder (`YOUR_API_KEY`) and only put the real key in
> your local working copy. To stop git from showing your local key as a change:
> ```bash
> git update-index --assume-unchanged config.yaml
> ```
> (undo later with `--no-assume-unchanged`). See [Security notes](#10-security-notes).

---

## 5. Install the `sap-video-translate` skill

The skill ships in this repo at `.claude/skills/sap-video-translate/`. Claude Code
discovers skills from two places:

### Option A — Project skill (already here)

If you are working **inside this repo**, Claude Code picks up
`.claude/skills/sap-video-translate/` automatically. Nothing to install — just
invoke it (step 6).

### Option B — User-wide skill (available in every project)

Symlink (or copy) the skill into your user skills directory:

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/.claude/skills/sap-video-translate" ~/.claude/skills/sap-video-translate
# or copy instead of symlink:
# cp -R .claude/skills/sap-video-translate ~/.claude/skills/
```

Verify Claude Code sees it:

```bash
ls ~/.claude/skills/sap-video-translate/SKILL.md
```

### 5.1 Run the one-time bootstrap

```bash
bash .claude/skills/sap-video-translate/scripts/bootstrap.sh
```

This is idempotent and will, only when missing: install `uv`, clone VideoLingo,
build the Python 3.12 `.venv`, verify `ffmpeg`, and persist the HF mirror. It
prints `VIDEOLINGO_DIR=...` on success — note that path; all pipeline commands run
from there.

---

## 6. Run it in Claude Code

### 6.1 Invoke the skill

In Claude Code, invoke by slash command with the video URL:

```
/sap-video-translate go translating this https://video.sap.com/playlist/dedicated/<id>/<A>/<entryId>
```

or just describe the task in natural language:

```
Translate this SAP video to English: https://video.sap.com/media/t/1_xxxxxxxx
```

### 6.2 What happens for an access-controlled SAP video

SAP Kaltura videos reject plain `yt-dlp` with **HTTP 404 / SSO redirect**. The
skill handles this automatically:

1. **Opens the video page** in the Playwright MCP browser (which carries your SAP
   SSO session):
   ```
   mcp__playwright-headed__browser_navigate(url="https://video.sap.com/media/t/<entryId>")
   ```
   The playable entry id is the **last** `1_...` segment of the URL.
2. **Harvests the `ks` token** from the Kaltura network requests (the token starts
   with `djJ8` and appears in thumbnail/playManifest requests).
3. **Downloads** the best ≤1080p rendition via the authorized `applehttp` manifest
   and writes `output/input_manifest.json`.

> **`ks` tokens are short-lived.** If a download 404s, Claude re-harvests a fresh
> token from the browser and retries. You must have a Playwright **headed** MCP
> server configured and already signed in to SAP SSO.

### 6.3 What happens for a public / YouTube video

No token needed — VideoLingo downloads it directly. (If it's a sign-in-gated
video, point `youtube.cookies_path` at an exported `cookies.txt`.)

### 6.4 The subtitle pipeline

Once the video is in `output/`, the pipeline runs:

```bash
cd "$VIDEOLINGO_DIR"
HF_ENDPOINT=https://hf-mirror.com uv run python run_pipeline.py subtitles
```

On first run this downloads ASR models through the HF mirror (can take several
minutes). For dubbing (optional) run `... run_pipeline.py dubbing` afterward.

---

## 7. How the pipeline works

```
video.sap.com URL
      │
      ├─ access-controlled? ──► Playwright MCP browser ──► harvest ks token
      │                                                         │
      │                         sap_ks_download.py  ◄───────────┘
      │                                │  (authorized applehttp manifest)
      ▼                                ▼
   output/a.mp4  ──►  run_pipeline.py subtitles
                            │
     STEP 1  ASR (Qwen3-ASR / WhisperX, local)  → word-level transcript, auto lang
     STEP 2  NLP + LLM sentence segmentation
     STEP 3  Translate  (SAP Hyperspace AI @ localhost:6655)
     STEP 4  Align / split subtitles
     STEP 5  Generate SRT  → src.srt, trans.srt
     STEP 6  Burn subtitles → output_sub.mp4
```

---

## 8. Output & archiving

Outputs land in `output/`:

| File | Description |
|------|-------------|
| `output/src.srt` | Source-language subtitles |
| `output/trans.srt` | Translated subtitles (target language) |
| `output/src_trans.srt`, `output/trans_src.srt` | Bilingual variants |
| `output/output_sub.mp4` | Video with burned-in subtitles |

VideoLingo **reuses the single `output/` directory**, so the next video would
overwrite it. **Always archive before the next run:**

```bash
cd "$VIDEOLINGO_DIR"
bash .claude/skills/sap-video-translate/scripts/archive_output.sh --move --label "<short-video-name>"
```

This moves everything in `output/` to `artifacts/<label>_<YYYYmmdd-HHMMSS>/` (never
overwriting earlier archives) and leaves `output/` empty for the next video.
`--move` frees disk space; omit it to copy instead. The script prints
`ARTIFACT_DIR=...` as its last line.

> `artifacts/` and the downloaded videos are large and are git-ignored — they stay
> local.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Translation step errors with 401 / auth | Wrong or placeholder API key | Put your real Hyperspace key in `config.yaml` (step 4) |
| Translation step: connection refused | Hyperspace proxy not running | Start the proxy; verify with the `curl` in step 3.2 |
| SAP download → `Unsupported URL: login.microsoftonline.com` | Direct download hit SSO (expected for access-controlled video) | Skill falls through to the `ks` path — ensure Playwright headed MCP is signed in |
| Download 404 right after harvesting ks | `ks` token expired | Re-harvest a fresh token and retry immediately |
| `command not found: timeout` (macOS) | macOS has no `timeout` | Run the command without `timeout` (gnu-coreutils provides `gtimeout`) |
| Model download stalls | HF mirror not exported | Ensure `HF_ENDPOINT=https://hf-mirror.com` is set (bootstrap persists it to `~/.zshrc`) |
| `ls output/*.srt` exits 1 during monitoring | SRTs only exist after STEP 5 | Not a failure — check later or gate on step completion |

---

## 10. Security notes

- **API key:** `config.yaml` is tracked in git. The committed copy must contain a
  placeholder (`YOUR_API_KEY`), **not** your real key. Keep the real key only in
  your local working copy and hide it from git with
  `git update-index --assume-unchanged config.yaml`.
- **SAP cookies / `ks` tokens:** `sap_video_cookies.txt` and `ks` tokens are
  credentials. They are git-ignored; never commit or share them.
- **Downloaded videos:** treat SAP video content as internal/confidential. Do not
  upload it anywhere outside your machine. `artifacts/` and `output/` are
  git-ignored for this reason.
- **`ks` cannot be automated headlessly:** it is JS-minted per authenticated
  session; only a real logged-in browser (the Playwright headed MCP) yields an
  authorized token.

---

## Bundled skill files

| File | Purpose |
|------|---------|
| `.claude/skills/sap-video-translate/SKILL.md` | Skill definition + workflow |
| `.claude/skills/sap-video-translate/scripts/bootstrap.sh` | Idempotent dependency installer/verifier |
| `.claude/skills/sap-video-translate/scripts/sap_ks_download.py` | `ks`-authenticated Kaltura downloader |
| `.claude/skills/sap-video-translate/scripts/archive_output.sh` | Archive each run's `output/` into a timestamped folder |
