# Claude Pet

A little desktop buddy for [Claude Code](https://docs.claude.com/en/docs/claude-code). It sits on your screen and you can drag it anywhere. Click 💬 and a chat panel opens that runs `claude` headless in a folder of your choice. Replies render Markdown, LaTeX math and images inline.

<img src="assets/pet.png" width="140" alt="The default pet">

It's a single native Swift/SwiftUI app with no dependencies beyond the Xcode command-line tools. KaTeX and marked are vendored in `assets/web`.

## Features

- **Drag** the pet anywhere. Its position is remembered. Click to poke it, right-click for the menu. **Esc** closes the chat.
- **💬 Chat** runs `claude -p` with `--output-format stream-json` in the working directory you pick. Conversations continue with `--resume`.
- **Markdown + LaTeX + images.** Claude is told about the panel through `--append-system-prompt`, so it writes math as `$…$` / `$$…$$` and embeds pictures with `![](/absolute/path.png)`. Click an image to open it.
- **⌘V** attaches a clipboard screenshot or copied files, with a thumbnail before sending. Text pastes as usual.
- **＋ / drag and drop** attaches files from Finder. Their folders are passed with `--add-dir`.
- **Screen context (optional).** When you ask something like "what's this error?" without giving context, Claude takes a screenshot of your displays and looks first. This needs Screen Recording permission (see below).
- **Continue in iTerm** reopens the same conversation interactively in iTerm.
- **✨ menu bar icon** for working directory, new chat, permissions, show/hide and quit.

## Requirements

- macOS 14 or later
- Xcode command-line tools for `swiftc`: `xcode-select --install`
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in. The app looks for `claude` in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and your `PATH`.
- Optional: [iTerm2](https://iterm2.com) for "Continue in iTerm"

## Setup

```bash
git clone https://github.com/kairussenberger/claude-pet.git
cd claude-pet
./build.sh                 # builds ~/Applications/Claude Pet.app
open ~/Applications/Claude\ Pet.app
```

Re-run `./build.sh` after any change to `Sources/` or `assets/`. Optional environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `BUNDLE_ID` | `io.github.claudepet` | The app's bundle identifier. Use your own, e.g. `BUNDLE_ID=com.you.claudepet ./build.sh` |
| `APP` | `~/Applications/Claude Pet.app` | Where the app bundle is written |

The app is ad-hoc signed with a designated requirement pinned to the bundle ID. Without that pin, macOS would forget the Screen Recording permission on every rebuild.

### Permissions: read this

The chat runs `claude -p` non-interactively, so Claude can't stop to ask you for approval. There are two modes:

- **Default: prompts on.** Claude follows your normal Claude Code [permission settings](https://docs.claude.com/en/docs/claude-code/settings). Any tool you haven't pre-approved is refused in the chat. Pre-approve what you're comfortable with in `~/.claude/settings.json`, for example:
  ```json
  { "permissions": { "allow": ["Read", "Edit", "Bash(ls:*)", "Bash(screencapture:*)", "Bash(mkdir:*)"] } }
  ```
  Screen context runs one short shell line that clears a temp folder (`rm -rf $TMPDIR/claude-pet-screen`), recreates it and calls `screencapture`. In this mode, Claude asks for or reports any piece you haven't allowed. Allow `rm` only if you're comfortable with it.
- **✨ → "Skip permission prompts (risky)".** Runs with `--dangerously-skip-permissions`, in the chat and in "Continue in iTerm". Claude can then run any command and edit any file without asking. It's convenient on your own machine, but only turn it on if you trust what you're asking for. The setting is stored per user (`defaults read io.github.claudepet skipPermissions`).

### Screen Recording (optional)

For screen context, allow **Claude Pet** under *System Settings → Privacy & Security → Screen & System Audio Recording*, then reopen the app. The ✨ menu shows "Allow screen access…" while the permission is missing. Without it, everything else still works, and Claude simply asks you for context.

## Make it your own pet

The pet is just `assets/pet.png`, a transparent PNG drawn bottom-aligned. The code adds the motion: waddling, breathing, a hop when clicked, and faster wobbling while Claude works. The original version used a personal cartoon character that isn't included here for copyright reasons. Here's how to put in your own:

1. **Use any image you have the rights to** (your own drawing, a photo of your cat…). To cut the subject out of its background with Apple's Vision framework:
   ```bash
   swift tools/cutout.swift my_picture.png assets/pet.png
   ```
   Or make a transparent PNG yourself in any editor. Around 400 × 450 px works well. Portrait-ish shapes look best, because the pet is sized by its height.
2. **Optional glint over sunglasses or eyes:** add `assets/pet_lens.png`, the same size as `pet.png`. Paint white where the shine should sweep and leave the rest transparent. Without this file, the glint is skipped.
3. Run `./build.sh` and reopen the app.

To get the default orange buddy back: `swift tools/placeholder.swift` (it rewrites both PNGs).

**What was removed from the original:** the sprite art and its source images, plus three one-off scripts that composited two character cutouts and recoloured them to a fixed palette (`compose.swift`, `recolor.swift`, `trim.swift`). They only worked on that specific art. `tools/cutout.swift` plus any image editor covers the same ground.

## How it works

| File | What it does |
|---|---|
| `Sources/main.swift` | The app: the pet window and sprite animation, the chat panel, the `claude` process (`ClaudeSession`), attachments, the menu and the permission toggle |
| `Sources/Transcript.swift` | The chat transcript: a `WKWebView` that renders Markdown (marked) and math (KaTeX) from `assets/web`. Local images are served through a custom `petchat://` scheme (only image files are readable). |
| `assets/web/` | Chat HTML/CSS/JS plus vendored KaTeX and marked, with their licences |
| `tools/placeholder.swift` | Draws the default sprite and glint mask |
| `tools/cutout.swift` | Vision-based background removal for your own sprite |
| `build.sh` | `swiftc`, bundle assembly, `Info.plist`, ad-hoc signing |

Notes:
- The app is menu-less (`LSUIElement`). A hidden Edit menu exists only so ⌘C/⌘V/⌘X/⌘A work in the chat.
- Screenshots for screen context go to `$TMPDIR/claude-pet-screen` and are overwritten on each capture. Claude is told to save pictures it shows you in `/tmp/claude-pet/`.

## Licence

MIT, see [LICENSE](LICENSE). KaTeX (MIT) and marked (MIT) keep their own licences in `assets/web/`.
