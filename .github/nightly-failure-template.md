---
title: "Nightly CI failing on main"
labels: [ci, nightly]
---

The nightly build is currently failing on `main`.

- **Run**: {{ env.GITHUB_SERVER_URL }}/{{ env.GITHUB_REPOSITORY }}/actions/runs/{{ env.GITHUB_RUN_ID }}
- **Runner image**: `macos-latest`
- **Likely causes**: a new Xcode bumped onto the runner, a transitive
  dependency update, a flaky test surfaced under different scheduling.

This issue is updated in place on consecutive failures (so it won't
spam new ones every day) and should be closed manually once the
underlying cause is fixed.
