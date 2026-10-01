# Contributing and Security

## Contributing

Practical rules:

- use `mise` for tasks and toolchain management
- test every change
- keep code, logs, and comments in English
- preserve behavior parity between CLI and Web when relevant

## Common tasks

```bash
mise run test
mise run test:unit
mise run test:web
mise run test
```

## Recommended flow

1. change the code
2. add or update tests
3. validate locally
4. open a PR
5. monitor CI and CodeQL

## Security

See also:

- [SECURITY.md](https://github.com/pietro1704/Epub-to-Mp3/blob/master/SECURITY.md)

Key points:

- do not open a public issue for vulnerabilities
- use GitHub Security Advisories
- include impact, reproduction steps, and affected versions
