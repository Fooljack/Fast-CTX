# Contributing to FastCtx

Thanks for your interest in FastCtx! Bug reports, feature requests, and pull
requests are all welcome.

## Reporting issues

Open an issue at <https://github.com/yc-duan/fastctx/issues>. For bugs, please
include the platform, the FastCtx version, and steps to reproduce.

## Development

FastCtx is a single Rust crate. The usual loop:

```console
cargo fmt
cargo clippy --all-targets
cargo test
```

Please keep pull requests focused: one change per PR.

## Verification

Before opening a pull request, run the same locked checks used by CI. The release
profile and the no-default-features run are separate checks because they exercise
different dependency and optimization paths:

```console
cargo fmt --all -- --check
cargo check --locked --all-targets
cargo check --locked --no-default-features --all-targets
cargo test --locked --all-features
cargo test --locked --no-default-features
cargo test --locked --release
cargo clippy --locked --all-targets --all-features -- -D warnings
cargo clippy --locked --no-default-features --all-targets -- -D warnings
git diff --check
```

On Windows, run `./scripts/drain-test-processes.ps1` between contract-test groups
when a later Cargo invocation needs to replace a binary still held by a test
process. Performance measurements should use a release build and the real MCP
`serve` protocol; report the input, budget, samples, and variance rather than
adding a machine-specific timing threshold to CI.

## License of contributions

FastCtx is licensed under the Apache License 2.0.

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in FastCtx by you, as defined in the Apache-2.0
license, shall be licensed as above, without any additional terms or
conditions.
