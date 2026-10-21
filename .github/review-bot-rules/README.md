# cmux Review Bot Rules

These rules are review guidance for human and agent reviewers of this fork. Upstream wired them into Greptile and CodeRabbit; this fork does not configure those bots.

The rule files are intentionally short and focused. Each one defines one class of issue, concrete failure cases, allowed cases, and the expected reporting shape. Keep new rules narrow enough that a reviewer can apply the rule to a full PR diff without turning it into a broad style guide.

Current rules:

- `algorithmic-complexity.md`
- `browser-automation-webkit-waits-off-main.md`
- `cache-substitution-correctness.md`
- `full-internationalization.md`
- `hot-path-allocating-formatting.md`
- `no-ambient-global-state.md`
- `no-test-debug-seam-in-production-source.md`
- `react-base-ui-accessibility.md`
- `reliability-single-source-of-truth.md`
- `runtime-no-hacky-sleeps.md`
- `source-control-artifacts.md`
- `swiftpm-package-resolved.md`
- `swift-actor-isolation.md`
- `swift-architectural-rethink.md`
- `swift-auxiliary-window-close-shortcuts.md`
- `swift-blocking-runtime.md`
- `swift-concurrency-modernization.md`
- `swift-concurrent-annotation.md`
- `swift-expensive-sync-load.md`
- `swift-package-boundaries.md`
- `swift-logging.md`
- `swiftui-state-layout.md`
- `user-facing-errors.md`
- `remote-relay-authorization.md`

Open source repository note: review bots should apply the configuration from the base branch. A PR that edits these rules should not be able to weaken its own review.
