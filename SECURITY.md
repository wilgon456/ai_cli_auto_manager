# Security policy

This tool updates executable programs and can permanently delete old conversation
history. Filesystem boundaries and package selection bugs are security-relevant.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/wilgon456/ai_cli_auto_manager/security/advisories/new)
when it is enabled. If that page is unavailable, open an issue asking the maintainer
for a private reporting channel, without exploit details or sensitive attachments.
Do not post credentials, conversation transcripts, or unredacted configuration files.

Include the affected version, OS, shell version, installation method, expected
behavior, and a minimal reproduction using disposable files. For deletion bugs,
describe which boundary was crossed and whether a dry run identified the files.

Security fixes target the current development version and the latest published
release. Older releases may require an upgrade; there is no guaranteed response
time or long-term support schedule.

## Limits of the safeguards

- npm waiting periods, provenance comparisons, and signature verification reduce
  risk but do not prove a package is safe. Other update channels use their vendor's
  distribution mechanism.
- `MANIFEST.json` detects missing or changed release files. It is an unsigned
  checksum list, not proof of the publisher's identity.
- A dry run is a snapshot. Processes and files can change before the actual run.
- Deleted conversation history has no automatic recovery. Keep a separate backup
  and preview cleanup before enabling its schedule.

To stop scheduled maintenance while investigating, run `aicm schedule remove`
(`.\bin\aicm.ps1 schedule remove` on Windows). This keeps logs and local data.
