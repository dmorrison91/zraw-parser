# Contributing

## Pull Requests

1. Fork the repository and create a feature branch from `main`.
2. Make your changes, keeping code style consistent with the surrounding code.
3. Run `swift build` to verify the project compiles.
4. Open a pull request describing the change and motivation.

## Code Style

- Swift: follow Swift API design guidelines, use meaningful names, avoid force unwraps.
- C/C++/Obj-C: use 4-space indentation, keep functions focused and documented.
- No trailing whitespace.
- Prefer `let` over `var`, `map`/`compactMap` over loops where appropriate.

## Commit Messages

Use concise, descriptive commit messages:

```
component: brief description of change
```

## Reporting Issues

Include the ZRAW camera model, macOS version, and steps to reproduce.
