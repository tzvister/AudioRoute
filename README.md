<p align="center">
  <img src="assets/audioroute-social.png" alt="AudioRoute — Agent-first audio routing. Mix apps, instruments and microphones. Create virtual audio devices." width="900">
</p>

# AudioRoute

**Tell your agent what each person should hear. AudioRoute builds the mix on your Mac.**

Mix apps, instruments, and microphones. Create virtual microphones and speakers that you can select in Zoom and other audio apps.

## 1. Install

Requires **macOS 14.2 or later**. One installer supports Apple Silicon and Intel Macs.

1. **[Download the newest installer from GitHub Releases](https://github.com/tzvister/AudioRoute/releases).** Open the top release and download its `.pkg` file under **Assets**. Use the newest release, including previews; this link stays current as new versions are published.
2. Open the `.pkg` and follow macOS Installer. Approve the administrator prompt.
3. Restart your Mac to load the audio driver.
4. Open Terminal and run:

   ```sh
   audioroute setup --start
   ```

The installer includes the CLI, background app, and audio driver. Updates use the same steps and preserve your saved routes.

**Current releases are unsigned developer previews.** macOS may block installation. Apple signing and notarization are tracked in [issue #2](https://github.com/tzvister/AudioRoute/issues/2).

## 2. Chat with Claude Code or Codex

Open **Claude Code or Codex on this Mac**, with access to your terminal. Paste this, then describe your own setup:

```text
Use the installed AudioRoute CLI to set up my audio.
Run audioroute --help --json and audioroute guide to learn how it works.
Check audioroute setup, discover my devices, and help me test the result.

I want a guitar lesson on Zoom:
- My guitar is on input 1 of my audio interface.
- Use my AirPods microphone for my voice and AirPods for listening.
- My teacher should hear my guitar and voice.
- I should hear my guitar and the teacher, without monitoring my own voice.
- Do not send the teacher's audio back to them.

Create and save this route. Help me choose its virtual microphone and
speaker in Zoom, test it with me, and balance the levels.
```

Your agent learns the commands from the CLI itself. You approve any macOS microphone permission prompts and confirm what you hear.

Keep chatting to adjust the mix:

> “Lower my voice for the teacher.”
>
> “Turn up my guitar only in my headphones.”
>
> “Save this setup for my next lesson.”

AudioRoute runs the audio locally. Claude Code or Codex controls it through the CLI.

## More help

[Agent quickstart](docs/agent-quickstart.md) · [CLI reference](docs/cli.md) · [Troubleshooting channels](docs/channel-troubleshooting.md) · [Build from source](docs/development.md) · [Verification record](docs/verification.md)
