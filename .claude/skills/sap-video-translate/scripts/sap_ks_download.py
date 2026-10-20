"""Download an access-controlled SAP video (video.sap.com / Kaltura) using a
session-bound Kaltura session (ks) token harvested from an authenticated browser.

Why this exists
---------------
video.sap.com is a Kaltura MediaSpace. Public entries download directly with
yt-dlp (core/_1_ytdlp.py handles the URL normalization). But access-controlled
entries reject every media URL with HTTP 404 unless the request carries a ks
token that was minted *inside the authenticated browser session* (via the
MediaSpace SSO cookie). The anonymous widget-session ks (fetchable over plain
HTTP) is NOT authorized for these entries, and Playwright cannot be installed
into this venv on the SAP network. So the ks is captured with the standalone
Playwright MCP browser and passed to this script.

How to get the ks (one-time, via the Playwright MCP browser)
------------------------------------------------------------
1. Open the SAP video page in the MCP browser (it already carries your SSO):
       browser_navigate("https://video.sap.com/media/t/<entryId>")
   (or the full /playlist/dedicated/.../<entryId> URL — the last segment is the
   playable entry id.)
2. List the Kaltura requests the authenticated player already made and copy the
   `ks=` query-parameter value from any of them (they share the same session
   token). The thumbnail requests appear even before playback starts:
       browser_network_requests(filter="kaltura")
   Look for a URL like .../thumbnail/.../ks/<TOKEN> or .../playManifest/...?ks=<TOKEN>
3. The token is long and base64-ish, starting with "djJ8". Copy the whole value
   (up to the next "/" or "&").

Then run
--------
    HF_ENDPOINT=https://hf-mirror.com \\
    uv run python scripts/sap_ks_download.py \\
        "https://video.sap.com/playlist/dedicated/398311063/1_doihyfnr/1_3j7c6lec" \\
        "djJ8MTkyMTY2MX..."   # the ks you copied

The script extracts the entry id, builds the applehttp (HLS) manifest URL with
your ks, downloads the best <=1080p rendition with yt-dlp, renames/sanitizes the
file, and writes output/input_manifest.json — exactly the state the Streamlit
pipeline expects. Afterwards run the subtitle pipeline normally:
    uv run python run_pipeline.py subtitles
"""
import argparse
import os
import re
import sys

# Kaltura partner constants for video.sap.com (stable; from the MediaSpace embed).
KALTURA_PARTNER_ID = "1921661"
KALTURA_SUB_PARTNER_ID = "192166100"

# Locate the VideoLingo project root so `core` is importable. This script may
# live either inside the VideoLingo repo (scripts/) or in a standalone skill
# directory, so try, in order: $VIDEOLINGO_DIR, the current working directory,
# then this file's parent-of-parent (the in-repo layout).
def _add_videolingo_to_path():
    candidates = [
        os.environ.get("VIDEOLINGO_DIR"),
        os.getcwd(),
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    ]
    for root in candidates:
        if root and os.path.isdir(os.path.join(root, "core")):
            sys.path.insert(0, root)
            return root
    # Fall back to the in-repo guess; the import below will raise a clear error.
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    return None


_add_videolingo_to_path()
from core._1_ytdlp import (  # noqa: E402
    find_video_files,
    sanitize_filename,
    write_input_manifest,
)


def extract_entry_id(url):
    """Return the Kaltura entry id (1_xxxxxxxx) from a video.sap.com URL.

    SAP serves two URL shapes:
      /media/t/{entryId}[/...]
      /playlist/dedicated/.../{entryId}
    In both the playable entry is the LAST 1_ segment in the path, so taking the
    final 1_ token (ignoring query/fragment) picks the right one.
    """
    path = re.split(r"[?#]", url, maxsplit=1)[0]
    tokens = re.findall(r"1_[0-9a-z]+", path)
    if tokens:
        return tokens[-1]
    raise ValueError(f"Could not find a Kaltura entry id (1_...) in URL: {url}")


def build_manifest_url(entry_id, ks):
    return (
        f"https://cdnapisec.kaltura.com/p/{KALTURA_PARTNER_ID}"
        f"/sp/{KALTURA_SUB_PARTNER_ID}/playManifest/entryId/{entry_id}"
        f"/format/applehttp/protocol/https/a.m3u8?ks={ks}"
    )


def download_with_ks(url, ks, save_path="output", resolution="1080"):
    os.makedirs(save_path, exist_ok=True)
    entry_id = extract_entry_id(url)
    manifest_url = build_manifest_url(entry_id, ks)
    print(f"Entry id: {entry_id}")
    print(f"Manifest: {manifest_url.split('?')[0]}?ks=<redacted>")

    fmt = (
        "bestvideo+bestaudio/best"
        if resolution == "best"
        else f"bestvideo[height<={resolution}]+bestaudio/best[height<={resolution}]"
    )
    ydl_opts = {
        "format": fmt,
        "outtmpl": f"{save_path}/%(title)s.%(ext)s",
        "noplaylist": True,
        "merge_output_format": "mp4",
        # SAP/Kaltura CDN keeps the HLS fallback stable with a Referer.
        "http_headers": {"Referer": "https://video.sap.com/"},
    }

    from yt_dlp import YoutubeDL

    with YoutubeDL(ydl_opts) as ydl:
        ydl.download([manifest_url])

    # Sanitize filenames like download_video_ytdlp does, then write the manifest.
    for file in os.listdir(save_path):
        full = os.path.join(save_path, file)
        if os.path.isfile(full):
            stem, ext = os.path.splitext(file)
            clean = sanitize_filename(stem)
            if clean != stem:
                os.rename(full, os.path.join(save_path, clean + ext))

    media_file = find_video_files(save_path)
    write_input_manifest(media_file, "video", save_path)
    print(f"DOWNLOADED: {media_file}")
    return media_file


def main():
    parser = argparse.ArgumentParser(
        description="Download an access-controlled SAP (Kaltura) video with a session ks token."
    )
    parser.add_argument("url", help="video.sap.com media or playlist URL")
    parser.add_argument("ks", help="session-bound Kaltura ks token harvested from the browser")
    parser.add_argument("--resolution", default="1080", help="max height, or 'best' (default 1080)")
    parser.add_argument("--save-path", default="output", help="output dir (default output)")
    args = parser.parse_args()

    if "video.sap.com" not in args.url:
        print("Warning: this helper is only for video.sap.com URLs.", file=sys.stderr)
    if not args.ks.startswith("djJ8"):
        print(
            "Warning: ks does not start with 'djJ8'; make sure you copied the full token "
            "from the playManifest request's ks= parameter.",
            file=sys.stderr,
        )

    download_with_ks(args.url, args.ks, save_path=args.save_path, resolution=args.resolution)


if __name__ == "__main__":
    main()
