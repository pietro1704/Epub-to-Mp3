# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| latest (nightly) | yes |
| 0.2.x | yes |
| < 0.2.0 | no |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Report privately via [GitHub Security Advisories](https://github.com/pietro1704/Epub-to-Mp3/security/advisories/new).

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Affected version(s)

You will receive a response within 7 days. If confirmed, a fix will be released as soon as possible and you will be credited in the release notes.

## Scope

In scope:
- Remote code execution via malformed EPUB/PDF input
- Path traversal in file upload or output handling
- Authentication/authorization bypass in the web API
- Dependency vulnerabilities with known exploits (CVE)

Out of scope:
- Vulnerabilities requiring local machine access
- Denial of service via large files (handled by `MAX_CHAPTER_CHARS`)
- Issues in third-party TTS cloud services (Edge-TTS)
