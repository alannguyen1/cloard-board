# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in cloard-board, please report it responsibly.

**Option 1: GitHub Security Advisory**
Open a [private security advisory](../../security/advisories/new) on this repository.

**Option 2: Email**
Send details to the maintainer via the email listed in the commit history.

Please include:
- A description of the vulnerability
- Steps to reproduce
- Potential impact

You can expect an initial response within 72 hours. We will work with you to understand the issue and coordinate a fix before any public disclosure.

## Scope

cloard-board is a local developer tool. Its threat model assumes a trusted local user on a single machine. Areas of particular interest:

- **Token handling**: `CLAUDE_CODE_OAUTH_TOKEN` and other credentials persisted to disk
- **Plist/XML generation**: injection via environment variable names or values
- **Shell command construction**: injection via task titles, repo paths, or cron job names
- **State file integrity**: concurrent access to `~/.cloard-board/state.json`

## Supported Versions

Only the latest release is actively maintained. Security fixes are not backported to older versions.
