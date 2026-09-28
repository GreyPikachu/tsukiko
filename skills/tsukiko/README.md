# Tsukiko Agent Skill: Installation Guide

This skill allows terminal AI coding assistants (Claude Code, OpenAI Codex, Google Antigravity, OpenClaw, Hermes) to automatically transcribe audio attachments and voice notes using your local machine's Tsukiko installation.

---

## One-Click Installation via Desktop App

The easiest way to install the skill is through the Tsukiko UI:
1. Open **Tsukiko → Settings (`⌘,` / `Ctrl+,`)**.
2. Go to **Application → AI Agent Skill**.
3. Click **"Install Skill"**.

Tsukiko automatically discovers installed agent environments and links the skill manifest directly.

---

## Manual Installation

The skill follows the universal `SKILL.md` specification with standard YAML frontmatter:

Copy the `skills/tsukiko` directory to your agent's skill directory:

| Agent / Tool | User Scope | Project Scope |
| :--- | :--- | :--- |
| **Claude Code** | `~/.claude/skills/tsukiko/` | `.claude/skills/tsukiko/` |
| **OpenAI Codex** | `~/.codex/skills/tsukiko/` | `.agents/skills/tsukiko/` |
| **Google Antigravity** | `~/.gemini/config/skills/tsukiko/` | `.agents/skills/tsukiko/` |
| **OpenCode** | `~/.config/opencode/skills/tsukiko/` | `.agents/skills/tsukiko/` |
| **OpenClaw** | `~/.openclaw/skills/tsukiko/` | `skills/tsukiko/` |
| **Hermes** | `~/.hermes/skills/tsukiko/` | `skills/tsukiko/` |

### Quick Installation Command

```sh
mkdir -p ~/.claude/skills ~/.codex/skills ~/.gemini/config/skills
cp -R skills/tsukiko ~/.claude/skills/
cp -R skills/tsukiko ~/.codex/skills/
cp -R skills/tsukiko ~/.gemini/config/skills/
```

Restarting your agent is usually not required; start a new conversation to load the new skill.

---

## Verification

Provide an audio file to your agent and ask a question about its contents:

```
Here is a voice note from a colleague, ~/Downloads/voice.ogg — what are they requesting?
```

The agent will autonomously invoke `tsukiko-transcribe` locally and summarize or answer based on the transcribed text.
