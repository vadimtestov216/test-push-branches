#!/usr/bin/env bash
set -euo pipefail

log_branch="${LOG_BRANCH:-push-event-log}"
workflow_label="${PATH_WORKFLOW_LABEL:?PATH_WORKFLOW_LABEL is required}"
record_dir="$(mktemp -d)"
record_file="${record_dir}/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${workflow_label}.json"

jq -n \
  --slurpfile event "${GITHUB_EVENT_PATH}" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repository "${GITHUB_REPOSITORY}" \
  --arg workflow "${GITHUB_WORKFLOW}" \
  --arg workflow_label "${workflow_label}" \
  --arg event_name "${GITHUB_EVENT_NAME}" \
  --arg ref "${GITHUB_REF}" \
  --arg ref_name "${GITHUB_REF_NAME}" \
  --arg sha "${GITHUB_SHA}" \
  --arg run_id "${GITHUB_RUN_ID}" \
  --arg run_attempt "${GITHUB_RUN_ATTEMPT}" \
  --arg actor "${GITHUB_ACTOR}" \
  '($event[0]) as $payload |
  {
    created_at: $created_at,
    repository: $repository,
    workflow: $workflow,
    workflow_label: $workflow_label,
    event_name: $event_name,
    ref: $ref,
    ref_name: $ref_name,
    sha: $sha,
    before: ($payload.before // ""),
    after: ($payload.after // ""),
    created: ($payload.created // false),
    deleted: ($payload.deleted // false),
    forced: ($payload.forced // false),
    compare: ($payload.compare // ""),
    run_id: $run_id,
    run_attempt: $run_attempt,
    actor: $actor,
    commits_count: (($payload.commits // []) | length),
    commits: [($payload.commits // [])[] | {
      id,
      message,
      added: (.added // []),
      modified: (.modified // []),
      removed: (.removed // [])
    }]
  }' > "${record_file}"

worktree="$(mktemp -d)"
remote_url="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

git clone --no-checkout "${remote_url}" "${worktree}"
cd "${worktree}"

if git ls-remote --exit-code --heads origin "${log_branch}" >/dev/null 2>&1; then
  git fetch origin "${log_branch}"
  git checkout "${log_branch}"
else
  git checkout --orphan "${log_branch}"
  git rm -rf . >/dev/null 2>&1 || true
  printf '# Push event log\n\nThis branch is maintained by GitHub Actions.\n' > README.md
fi

mkdir -p records/path-workflows
cp "${record_file}" "records/path-workflows/${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${workflow_label}.json"
jq -c . "${record_file}" >> records/path-workflow-events.jsonl

{
  printf '| created_at | workflow_label | ref_name | before | sha | created | commits_count | run_id |\n'
  printf '| --- | --- | --- | --- | --- | --- | --- | --- |\n'
  jq -r '[.created_at, .workflow_label, .ref_name, .before, .sha, .created, .commits_count, .run_id] | @tsv' records/path-workflow-events.jsonl |
    while IFS=$'\t' read -r created_at label ref_name before sha created commits_count run_id; do
      printf '| `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` | `%s` |\n' \
        "${created_at}" "${label}" "${ref_name}" "${before}" "${sha}" "${created}" "${commits_count}" "${run_id}"
    done
} > records/path-workflow-events.md

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add README.md records

if git diff --cached --quiet; then
  echo "No path workflow log changes to commit."
  exit 0
fi

git commit -m "Record path workflow ${workflow_label} ${GITHUB_RUN_ID}.${GITHUB_RUN_ATTEMPT}"
git push origin "${log_branch}"
