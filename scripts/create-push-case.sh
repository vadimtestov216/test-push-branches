#!/usr/bin/env bash
set -euo pipefail

remote="origin"
base_branch="main"
branch_prefix="generated"
push_branch=1
paths=(alpha beta gamma)

usage() {
  cat <<'USAGE'
Create GitHub Actions push/path-filter investigation cases.

Usage:
  scripts/create-push-case.sh linear [options]
  scripts/create-push-case.sh merge [options]
  scripts/create-push-case.sh criss-cross-force [options]

Global options:
  --base BRANCH        Base branch to start from. Default: main
  --remote NAME        Git remote to push/fetch. Default: origin
  --prefix PREFIX      Branch prefix. Default: generated
  --no-push            Create the branch locally, but do not push it
  --help               Show this help

linear options:
  --name NAME          Case name. Default: linear-<timestamp>
  --count N            Number of commits to create. Default: 10
  --paths CSV          Directory cycle. Default: alpha,beta,gamma
  --blocks SPEC        Commit blocks instead of cycling paths.
                       SPEC format: path:count,path:count,...

merge options:
  --name NAME          Case name. Default: merge-<timestamp>
  --parents SPEC       Side branches to merge. Default: alpha:2,beta:2
                       SPEC format: path:count,path:count,...
  --head-path PATH     Optional final commit after the merge
  --head-count N       Number of final commits after the merge. Default: 0

criss-cross-force options:
  --name NAME          Case name. Default: criss-cross-<timestamp>
  --left-path PATH     Path changed on the left side. Default: alpha
  --right-path PATH    Path changed on the right side. Default: beta
  --final-path PATH    Path changed only in the forced update. Default: gamma

Examples:
  scripts/create-push-case.sh linear --name linear-350 --count 350 --paths alpha,beta,gamma
  scripts/create-push-case.sh linear --name first-300-alpha --blocks alpha:300,gamma:50
  scripts/create-push-case.sh merge --name two-parent --parents alpha:3,beta:4
  scripts/create-push-case.sh merge --name octopus --parents alpha:2,beta:2,gamma:2 --head-path gamma --head-count 1
  scripts/create-push-case.sh criss-cross-force --name multiple-merge-bases

The script prints the local diff range GitHub is expected to use for the first
push of a new branch: first-pushed-commit^..HEAD. For new branches, GitHub's
push payload still has before=0000000000000000000000000000000000000000.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

timestamp() {
  date -u +%Y%m%d%H%M%S
}

split_csv() {
  local input="$1"
  IFS=',' read -r -a paths <<< "${input}"
}

require_clean_tree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
    die "working tree is not clean"
  fi
}

fetch_base() {
  git fetch "${remote}" "${base_branch}"
}

require_branch_absent() {
  local branch="$1"

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    die "local branch already exists: ${branch}"
  fi

  if git ls-remote --exit-code --heads "${remote}" "${branch}" >/dev/null 2>&1; then
    die "remote branch already exists: ${branch}"
  fi
}

checkout_case_branch() {
  local branch="$1"

  git switch "${base_branch}"
  git pull --ff-only "${remote}" "${base_branch}"
  git switch --no-track -c "${branch}"
}

write_case_file() {
  local path="$1"
  local case_name="$2"
  local label="$3"
  local index="$4"
  local file="${path}/${case_name}-${label}-${index}.txt"

  mkdir -p "${path}"
  printf 'case=%s\nlabel=%s\nindex=%s\ncreated_at=%s\n' \
    "${case_name}" "${label}" "${index}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${file}"
  git add "${file}"
}

commit_case_file() {
  local path="$1"
  local case_name="$2"
  local label="$3"
  local index="$4"

  write_case_file "${path}" "${case_name}" "${label}" "${index}"
  git commit -m "Add ${case_name} ${label} ${index}"
}

print_expected_range() {
  local branch="$1"
  local base_ref="${remote}/${base_branch}"
  local first_commit

  first_commit="$(git rev-list --reverse "${base_ref}..${branch}" | sed -n '1p')"
  [[ -n "${first_commit}" ]] || die "branch ${branch} has no commits beyond ${base_ref}"

  echo
  echo "Case branch: ${branch}"
  echo "Base ref:    ${base_ref} ($(git rev-parse --short "${base_ref}"))"
  echo "First new:   ${first_commit}"
  echo "Head:        $(git rev-parse "${branch}")"
  echo "Expected new-branch compare:"
  echo "  ${first_commit}^..$(git rev-parse "${branch}")"
  echo
  echo "Changed files in expected range:"
  git diff --name-only "${first_commit}^" "${branch}" | sed 's/^/  /'
}

maybe_push() {
  local branch="$1"

  if [[ "${push_branch}" -eq 1 ]]; then
    git push -u "${remote}" "${branch}"
  else
    echo
    echo "Skipped push. To push later:"
    echo "  git push -u ${remote} ${branch}"
  fi
}

parse_global_option() {
  case "${1:-}" in
    --base)
      base_branch="${2:-}"
      [[ -n "${base_branch}" ]] || die "--base requires a value"
      return 2
      ;;
    --remote)
      remote="${2:-}"
      [[ -n "${remote}" ]] || die "--remote requires a value"
      return 2
      ;;
    --prefix)
      branch_prefix="${2:-}"
      [[ -n "${branch_prefix}" ]] || die "--prefix requires a value"
      return 2
      ;;
    --no-push)
      push_branch=0
      return 1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      return 0
      ;;
  esac
}

create_linear_case() {
  local name="linear-$(timestamp)"
  local count=10
  local blocks_spec=""

  while [[ "$#" -gt 0 ]]; do
    parse_global_option "$@" && true
    local consumed=$?
    if [[ "${consumed}" -gt 0 ]]; then
      shift "${consumed}"
      continue
    fi

    case "$1" in
      --name)
        name="${2:-}"
        [[ -n "${name}" ]] || die "--name requires a value"
        shift 2
        ;;
      --count)
        count="${2:-}"
        [[ "${count}" =~ ^[0-9]+$ ]] || die "--count must be a positive integer"
        shift 2
        ;;
      --paths)
        split_csv "${2:-}"
        [[ "${#paths[@]}" -gt 0 ]] || die "--paths requires at least one path"
        shift 2
        ;;
      --blocks)
        blocks_spec="${2:-}"
        [[ -n "${blocks_spec}" ]] || die "--blocks requires a value"
        shift 2
        ;;
      *)
        die "unknown linear option: $1"
        ;;
    esac
  done

  [[ "${count}" -gt 0 ]] || die "--count must be greater than zero"

  require_clean_tree
  fetch_base

  local branch="${branch_prefix}/${name}"
  require_branch_absent "${branch}"
  checkout_case_branch "${branch}"

  if [[ -n "${blocks_spec}" ]]; then
    local block_entries=()
    local commit_index=1
    IFS=',' read -r -a block_entries <<< "${blocks_spec}"

    for entry in "${block_entries[@]}"; do
      local path="${entry%%:*}"
      local block_count="${entry#*:}"
      [[ -n "${path}" && -n "${block_count}" && "${path}" != "${block_count}" ]] || die "bad block spec entry: ${entry}"
      [[ "${block_count}" =~ ^[0-9]+$ && "${block_count}" -gt 0 ]] || die "block count must be positive: ${entry}"

      for ((i = 1; i <= block_count; i++)); do
        commit_case_file "${path}" "${name}" "linear-${path//\//-}" "${commit_index}"
        commit_index=$((commit_index + 1))
      done
    done
  else
    for ((i = 1; i <= count; i++)); do
      local path="${paths[$(((i - 1) % ${#paths[@]}))]}"
      commit_case_file "${path}" "${name}" "linear" "${i}"
    done
  fi

  print_expected_range "${branch}"
  maybe_push "${branch}"
}

create_merge_case() {
  local name="merge-$(timestamp)"
  local parents_spec="alpha:2,beta:2"
  local head_path=""
  local head_count=0

  while [[ "$#" -gt 0 ]]; do
    parse_global_option "$@" && true
    local consumed=$?
    if [[ "${consumed}" -gt 0 ]]; then
      shift "${consumed}"
      continue
    fi

    case "$1" in
      --name)
        name="${2:-}"
        [[ -n "${name}" ]] || die "--name requires a value"
        shift 2
        ;;
      --parents)
        parents_spec="${2:-}"
        [[ -n "${parents_spec}" ]] || die "--parents requires a value"
        shift 2
        ;;
      --head-path)
        head_path="${2:-}"
        [[ -n "${head_path}" ]] || die "--head-path requires a value"
        shift 2
        ;;
      --head-count)
        head_count="${2:-}"
        [[ "${head_count}" =~ ^[0-9]+$ ]] || die "--head-count must be a non-negative integer"
        shift 2
        ;;
      *)
        die "unknown merge option: $1"
        ;;
    esac
  done

  require_clean_tree
  fetch_base

  local branch="${branch_prefix}/${name}"
  local base_ref="${remote}/${base_branch}"
  local parent_branches=()
  local parent_entries=()

  IFS=',' read -r -a parent_entries <<< "${parents_spec}"
  [[ "${#parent_entries[@]}" -ge 2 ]] || die "merge case needs at least two parents"
  require_branch_absent "${branch}"

  for entry in "${parent_entries[@]}"; do
    local path="${entry%%:*}"
    local count="${entry#*:}"
    [[ -n "${path}" && -n "${count}" && "${path}" != "${count}" ]] || die "bad parent spec entry: ${entry}"
    [[ "${count}" =~ ^[0-9]+$ && "${count}" -gt 0 ]] || die "parent count must be positive: ${entry}"

    local side_branch="${branch}-parent-${path//\//-}"
    require_branch_absent "${side_branch}"
    git switch --no-track -c "${side_branch}" "${base_ref}"

    for ((i = 1; i <= count; i++)); do
      commit_case_file "${path}" "${name}" "parent-${path//\//-}" "${i}"
    done

    parent_branches+=("${side_branch}")
  done

  git switch --no-track -c "${branch}" "${base_ref}"
  git merge --no-ff --no-edit "${parent_branches[@]}"

  if [[ "${head_count}" -gt 0 ]]; then
    [[ -n "${head_path}" ]] || die "--head-path is required when --head-count is greater than zero"
    for ((i = 1; i <= head_count; i++)); do
      commit_case_file "${head_path}" "${name}" "head" "${i}"
    done
  fi

  print_expected_range "${branch}"
  maybe_push "${branch}"
}

create_criss_cross_force_case() {
  local name="criss-cross-$(timestamp)"
  local left_path="alpha"
  local right_path="beta"
  local final_path="gamma"

  while [[ "$#" -gt 0 ]]; do
    parse_global_option "$@" && true
    local consumed=$?
    if [[ "${consumed}" -gt 0 ]]; then
      shift "${consumed}"
      continue
    fi

    case "$1" in
      --name)
        name="${2:-}"
        [[ -n "${name}" ]] || die "--name requires a value"
        shift 2
        ;;
      --left-path)
        left_path="${2:-}"
        [[ -n "${left_path}" ]] || die "--left-path requires a value"
        shift 2
        ;;
      --right-path)
        right_path="${2:-}"
        [[ -n "${right_path}" ]] || die "--right-path requires a value"
        shift 2
        ;;
      --final-path)
        final_path="${2:-}"
        [[ -n "${final_path}" ]] || die "--final-path requires a value"
        shift 2
        ;;
      *)
        die "unknown criss-cross-force option: $1"
        ;;
    esac
  done

  require_clean_tree
  fetch_base

  local branch="${branch_prefix}/${name}"
  local left_branch="${branch}-left"
  local right_branch="${branch}-right"
  local base_ref="${remote}/${base_branch}"

  require_branch_absent "${branch}"
  require_branch_absent "${left_branch}"
  require_branch_absent "${right_branch}"

  git switch --no-track -c "${left_branch}" "${base_ref}"
  commit_case_file "${left_path}" "${name}" "left" "1"
  local left_first
  left_first="$(git rev-parse HEAD)"

  git switch --no-track -c "${right_branch}" "${base_ref}"
  commit_case_file "${right_path}" "${name}" "right" "1"
  local right_first
  right_first="$(git rev-parse HEAD)"

  git switch "${left_branch}"
  git merge --no-ff --no-edit "${right_first}"
  local left_tip
  left_tip="$(git rev-parse HEAD)"

  git switch "${right_branch}"
  git merge --no-ff --no-edit "${left_first}"
  local right_merge_tip
  right_merge_tip="$(git rev-parse HEAD)"

  commit_case_file "${final_path}" "${name}" "forced-final" "1"
  local right_final_tip
  right_final_tip="$(git rev-parse HEAD)"

  git branch "${branch}" "${left_tip}"
  git switch "${branch}"

  echo
  echo "Criss-cross case branch: ${branch}"
  echo "Left first:              ${left_first}"
  echo "Right first:             ${right_first}"
  echo "Initial pushed tip:      ${left_tip}"
  echo "Forced replacement tip:  ${right_final_tip}"
  echo
  echo "Merge bases between initial and forced tips:"
  git merge-base --all "${left_tip}" "${right_final_tip}" | sed 's/^/  /'
  echo
  echo "Changed files for two-dot tree diff initial..forced:"
  git diff --name-only "${left_tip}" "${right_final_tip}" | sed 's/^/  /'
  echo
  echo "Changed files from each merge-base to forced tip:"
  while read -r merge_base; do
    echo "  merge-base ${merge_base}:"
    git diff --name-only "${merge_base}" "${right_final_tip}" | sed 's/^/    /'
  done < <(git merge-base --all "${left_tip}" "${right_final_tip}")

  if [[ "${push_branch}" -eq 1 ]]; then
    git push -u "${remote}" "${branch}"
    git push --force-with-lease "${remote}" "${right_final_tip}:refs/heads/${branch}"
  else
    echo
    echo "Skipped push. To run the force-push test manually:"
    echo "  git push -u ${remote} ${branch}"
    echo "  git branch -f ${branch} ${right_final_tip}"
    echo "  git switch ${branch}"
    echo "  git push --force-with-lease ${remote} ${branch}"
  fi
}

main() {
  local command="${1:-}"
  [[ -n "${command}" ]] || {
    usage
    exit 1
  }
  shift

  case "${command}" in
    linear)
      create_linear_case "$@"
      ;;
    merge)
      create_merge_case "$@"
      ;;
    criss-cross-force)
      create_criss_cross_force_case "$@"
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
