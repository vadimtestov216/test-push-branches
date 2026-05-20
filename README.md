# GitHub Actions push payload investigation

This repository records selected `push` event fields into the independent
`push-event-log` branch.

The workflow captures:

- `github.sha`
- `github.event.before`
- `github.event.after`
- `github.ref`
- `github.ref_name`
- workflow run metadata

The log branch contains `records/events.jsonl`, one JSON object per run, plus a
Markdown rendering in `records/events.md`.

## Push sample 1

First follow-up push at 2026-05-20T15:19:26Z UTC.
