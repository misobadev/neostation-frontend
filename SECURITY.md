# Security Policy

We take security seriously at NeoStation and appreciate the efforts of security researchers and contributors who help keep our users safe.

## Reporting a Vulnerability

If you believe you've found a security vulnerability, please follow responsible disclosure practices and **do not** open a public GitHub issue, as this could expose the vulnerability before a fix is available.

Instead, please report it through one of the following channels:

- **Email:** [miguelsotobaez@gmail.com](mailto:miguelsotobaez@gmail.com)
- **GitHub Security Advisory:** [Open a private advisory](https://github.com/misobadev/neostation-frontend/security/advisories/new)

We will acknowledge your report promptly and work with you to understand and resolve the issue as quickly as possible.

## Best Practices for Contributors

- Never commit secrets, API keys, or passwords in code.
- Use `String.fromEnvironment` for sensitive build-time values.
- Ensure third-party assets comply with their respective licenses.
- If you work with native code (C/C++), follow memory safety best practices.
