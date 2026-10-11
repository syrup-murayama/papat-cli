---
name: papat-upload
description: Upload a user-selected local JPEG folder to papat and return its gallery link. Use when the user asks to upload photos to papat; never inspect the photos or request an API key in chat.
compatibility: Claude Code, Codex, and other Agent Skills-compatible agents on macOS.
metadata:
  author: Murayama Photo Office
---

# Upload a folder to papat

Use this skill only when the user has explicitly asked to upload a folder. Treat the folder path and upload options as user-provided input. The agent does not need to open, view, classify, or summarize any photo. Client photos should not be loaded into AI context.

## Procedure

1. Confirm the requested folder exists and is the folder the user named. Do not inspect image contents.
2. Check whether `papat` is available with `command -v papat`.
3. If unavailable, open `https://papat.app/cli/` and use the current download and checksum links shown there. Do not guess or hard-code a versioned URL. Save both files in the same directory and verify with `shasum -a 256 -c <downloaded-checksum-file>` before extracting or running anything. If the checksum fails, stop and tell the user. Extract, read the included README, and run the included `install.sh` only after the archive checksum passes.
4. Run `papat status`. If not authenticated, ask the user to open a terminal and run `papat login` themselves, then retry `papat status`. Never ask the user to paste, dictate, or send an API key in chat, a prompt, an environment variable, or a command argument. Do not read Keychain contents.
5. Run `papat upload "<user-selected-folder>" --background` and include the user's requested title, retention days, or key color only when specified. The command prints the gallery URL, passcode, and client message immediately. Return those details to the user.
6. Check `papat jobs` for completion and report whether upload is still running or finished. If it failed, report the local log path and offer to retry the same folder. Do not open the log if it contains anything beyond operational upload status, and do not retry a different folder without user direction.

For an installed command, `papat --version` reports its version. The official download page is the source of truth for the current release; do not rely on a version copied into this skill.

The CLI does not change source photos. Before upload, it removes EXIF (including GPS), XMP, IPTC, JPEG comments, and other non-color metadata from its temporary JPEG copy. It keeps the ICC color profile or adds sRGB when none is present. It only resizes/re-encodes when needed; metadata cleanup itself does not recompress image pixels.

## Safety boundaries

- Never run `papat close`, `papat extend`, or another state-changing command unless the user explicitly requested it.
- Never upload a folder the user did not select, recurse outside it, or change source photos.
- Do not run downloaded scripts before checksum verification. Do not disable Gatekeeper or alter system security settings.
- The user enters API keys into the macOS Keychain prompt via `papat login`; keys are not part of agent context.
- If a CLI version or download URL differs from this skill, use the official papat download page and verify the page's published checksum. Stop if the official source cannot be confirmed.
