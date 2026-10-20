#!/usr/bin/env bash
# Idempotent dependency installer/verifier for the sap-video-translate skill.
#
# Installs or verifies, only when missing:
#   1. uv              - the Python launcher VideoLingo uses
#   2. VideoLingo repo - clones the velocityX-br fork (SAP/Kaltura support)
#   3. Python 3.12 env - via `uv run start.py --check` (triggers setup_env.py)
#   4. ffmpeg          - audio extraction + subtitle burning
#   5. HF mirror       - HF_ENDPOINT=https://hf-mirror.com (huggingface.co blocked on SAP net)
#
# Prints a summary and, on success, the VIDEOLINGO_DIR the caller should use.
# Safe to re-run. Exits non-zero if a hard dependency it cannot auto-install
# (e.g. ffmpeg on Linux without sudo) is still missing.

set -uo pipefail

VIDEOLINGO_REPO="https://github.com/velocityX-br/VideoLingo"
VIDEOLINGO_DIR="${VIDEOLINGO_DIR:-$HOME/Workdir/Github/VideoLingo}"
HF_ENDPOINT_VALUE="https://hf-mirror.com"

note()  { printf '  [bootstrap] %s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
warn()  { printf '  [warn] %s\n' "$*" >&2; }
fail()  { printf '  [FAIL] %s\n' "$*" >&2; }

hard_fail=0

echo "== sap-video-translate bootstrap =="

# ---------------------------------------------------------------- 1. uv -------
if command -v uv >/dev/null 2>&1; then
  ok "uv present: $(command -v uv)"
else
  note "uv not found; installing via the official script..."
  if curl -LsSf https://astral.sh/uv/install.sh | sh; then
    # The installer drops uv in ~/.local/bin; make it visible for this run.
    export PATH="$HOME/.local/bin:$PATH"
    if command -v uv >/dev/null 2>&1; then
      ok "uv installed: $(command -v uv)"
    else
      fail "uv install ran but uv is still not on PATH (expected ~/.local/bin/uv)."
      hard_fail=1
    fi
  else
    fail "uv install script failed. Install uv manually: https://docs.astral.sh/uv/"
    hard_fail=1
  fi
fi

# ----------------------------------------------------- 2. VideoLingo repo -----
if [ -d "$VIDEOLINGO_DIR/.git" ]; then
  ok "VideoLingo clone present: $VIDEOLINGO_DIR"
elif [ -e "$VIDEOLINGO_DIR" ] && [ ! -d "$VIDEOLINGO_DIR/.git" ]; then
  # A non-git path exists where we expected the clone; don't clobber it.
  warn "$VIDEOLINGO_DIR exists but is not a git clone; reusing it as-is."
else
  note "Cloning $VIDEOLINGO_REPO -> $VIDEOLINGO_DIR ..."
  mkdir -p "$(dirname "$VIDEOLINGO_DIR")"
  if git clone --depth 1 "$VIDEOLINGO_REPO" "$VIDEOLINGO_DIR"; then
    ok "Cloned VideoLingo."
  else
    fail "git clone failed. Check network access to github.com."
    hard_fail=1
  fi
fi

# --------------------------------------------------------- 5. HF mirror -------
# (Done before the env step so the env check inherits the mirror.)
export HF_ENDPOINT="$HF_ENDPOINT_VALUE"
ok "HF_ENDPOINT exported for this run: $HF_ENDPOINT"
# Persist it to ~/.zshrc if not already present.
ZSHRC="$HOME/.zshrc"
if [ -f "$ZSHRC" ] && grep -q "HF_ENDPOINT=$HF_ENDPOINT_VALUE" "$ZSHRC" 2>/dev/null; then
  ok "HF_ENDPOINT already persisted in ~/.zshrc"
else
  if printf '\n# HuggingFace mirror (huggingface.co blocked on SAP network)\nexport HF_ENDPOINT=%s\n' "$HF_ENDPOINT_VALUE" >> "$ZSHRC" 2>/dev/null; then
    ok "Persisted HF_ENDPOINT to ~/.zshrc"
  else
    warn "Could not write ~/.zshrc; HF_ENDPOINT set for this run only."
  fi
fi

# --------------------------------------------------------- 4. ffmpeg ----------
if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg present: $(command -v ffmpeg)"
else
  note "ffmpeg not found."
  case "$(uname -s)" in
    Darwin)
      if command -v brew >/dev/null 2>&1; then
        note "Installing ffmpeg via Homebrew..."
        if brew install ffmpeg; then
          ok "ffmpeg installed."
        else
          fail "brew install ffmpeg failed; install it manually."
          hard_fail=1
        fi
      else
        fail "Homebrew not found. Install ffmpeg manually: brew install ffmpeg"
        hard_fail=1
      fi
      ;;
    Linux)
      # Do not sudo-install silently; print the command for the user.
      if command -v apt-get >/dev/null 2>&1; then
        fail "ffmpeg missing. Run: sudo apt-get update && sudo apt-get install -y ffmpeg"
      elif command -v zypper >/dev/null 2>&1; then
        fail "ffmpeg missing. Run: sudo zypper install -y ffmpeg"
      else
        fail "ffmpeg missing. Install it via your distro package manager."
      fi
      hard_fail=1
      ;;
    *)
      fail "ffmpeg missing on an unrecognised OS; install it manually."
      hard_fail=1
      ;;
  esac
fi

# ------------------------------------------------- 3. Python 3.12 env ---------
# Only attempt if uv and the repo are both usable.
if command -v uv >/dev/null 2>&1 && [ -f "$VIDEOLINGO_DIR/start.py" ]; then
  note "Verifying/building the VideoLingo Python 3.12 env (uv run start.py --check)..."
  if ( cd "$VIDEOLINGO_DIR" && HF_ENDPOINT="$HF_ENDPOINT_VALUE" uv run start.py --check ); then
    ok "VideoLingo env healthy."
  else
    warn "env --check reported an issue; the first real run (start.py / run_pipeline.py)"
    warn "will trigger setup_env.py to finish building .venv. Continuing."
  fi
else
  warn "Skipping env check (uv or $VIDEOLINGO_DIR/start.py not available yet)."
fi

echo "== summary =="
if [ "$hard_fail" -ne 0 ]; then
  fail "One or more hard dependencies are missing (see [FAIL] lines above)."
  echo "VIDEOLINGO_DIR=$VIDEOLINGO_DIR"
  exit 1
fi

ok "All dependencies present."
# Machine-readable last line for the caller to parse.
echo "VIDEOLINGO_DIR=$VIDEOLINGO_DIR"
