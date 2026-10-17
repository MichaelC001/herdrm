# Contributing to herdrm

Thanks for helping. A PR that does the following gets reviewed quickly, because
the owner can see it works without rebuilding it in their head.

## Before you open a PR

1. **Write the test first and watch it fail.** Then make it pass.
   - Logic in `Packages/HerdrKit`: a unit test next to the others in
     `Packages/HerdrKit/Tests`. Run `make kit-test`.
   - Anything you can click: a behavior test through the real view, in
     `Tests/HerdrMTests` with `SidebarHarness`. Click through real AppKit
     hit-testing, the way a user does. Run `make uiux-test`.
   - Talking to herdr or SSH: the integration tests in `make kit-test` use a
     running local herdr; `HERDRM_E2E_SSH_TARGET=user@host make kit-test` adds
     the remote SSH ones.
2. **Every test passes.** CI runs `make kit-test`, `make uiux-test` and a
   secret scan on each PR (`.github/workflows/tests.yml`).
3. **Accessibility.** Follow [docs/ACCESSIBILITY.md](docs/ACCESSIBILITY.md):
   every control has its own VoiceOver name, and tests find controls by that
   name.
4. **`CHANGELOG.md`** has an entry under `## [Unreleased]`. Releases fail
   without one.
5. **UI changes** come with a screenshot or GIF that uses fake data (`test1`,
   `test2`, …), never real project, host or account names.
6. **No secrets, no new binaries without a reason.** Changes to workflows,
   `project.yml`, `Package.swift`, the `Makefile` or
   `Packages/HerdrSSH/Artifacts/` need the owner's review (`.github/CODEOWNERS`);
   say in the PR why they're needed.

## The PR description

Use the headings merged PRs use: **Context** (the moment a user hits the
problem), **What** (user-visible changes), **Why**, **Cost** (size, tests and
how to run them, what you didn't test), **Reviewer action** (the one decision
you need from the owner).
