# Contributing to Acuity

Thanks for your interest in improving Acuity. Bug reports, feature requests, and pull requests are all welcome.

## Reporting bugs

Open an issue using the bug report template. The most useful reports include:

- `acuity list --json` output
- Your macOS version and Mac model (Apple Silicon or Intel)
- The display model and how it is connected (DisplayPort, HDMI, USB-C, or a dock)

## Development setup

Acuity is a Swift Package with a small Python helper layer.

```bash
git clone https://github.com/paulhkang94/acuity.git
cd acuity
swift build            # debug build
swift build -c release # release build -> .build/release/acuity
```

## Running tests

```bash
swift test                      # Swift unit tests
python3 -m pytest pytests/ -q   # Python tests (scripts/hidpi.py)
scripts/claude-verify.sh --all  # full pipeline: lint -> test -> compile
```

Run the full pipeline before opening a pull request.

## Pull requests

1. Fork the repo and create a branch off `main`.
2. Make your change, keeping commits focused.
3. Add or update tests for any behavior change.
4. Ensure `scripts/claude-verify.sh --all` passes.
5. Open a pull request describing what changed and why.

New CLI commands live in `Sources/acuity/Commands/` and must be registered in `Acuity.swift`. Display logic that depends on physical hardware should be abstracted behind a protocol so it can be mocked in tests.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
