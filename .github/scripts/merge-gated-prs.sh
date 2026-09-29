#!/usr/bin/env bash
# Folds open PRs labeled `awaiting-cliproxyapi` into a CLIProxyAPI bump PR once the
# bumped binary's embedded registry lists every model the gated PR declares, then
# merges the combined PR so a single release ships the binary and the catalog change.
#
# A gated PR declares what it needs with one or more body lines:
#   Requires-CLIProxyAPI-Model: gpt-6.1-sol
#
# Inputs (env): BUMP_PR (number), GH_TOKEN, GITHUB_REPOSITORY, DRY_RUN (true/false).
set -euo pipefail

LABEL="awaiting-cliproxyapi"
BINARY="src/Sources/Resources/cli-proxy-api"
BUILD_CHECK_NAME="Swift Build"
CHECK_POLL_SECONDS=30
CHECK_POLL_ATTEMPTS=60

log() { echo "[merge-gated-prs] $*"; }

registry_lists_model() {
  # The registry is embedded as plain JSON, so an exact `"id": "<model>"` match is reliable.
  grep -aqF "\"id\": \"$1\"" "$BINARY"
}

wait_for_build() {
  local pr="$1" state
  sleep 20 # let GitHub attach the check run for the pushed head commit
  for _ in $(seq 1 "$CHECK_POLL_ATTEMPTS"); do
    state=$(gh pr checks "$pr" --json name,bucket \
      --jq "[.[] | select(.name == \"$BUILD_CHECK_NAME\") | .bucket] | if length == 0 then \"none\" elif any(. == \"fail\" or . == \"cancel\") then \"fail\" elif any(. == \"pending\") then \"pending\" else \"pass\" end" \
      2>/dev/null || echo none)
    case "$state" in
      pass) return 0 ;;
      fail) log "'$BUILD_CHECK_NAME' failed on #$pr"; return 1 ;;
    esac
    sleep "$CHECK_POLL_SECONDS"
  done
  log "Timed out waiting for '$BUILD_CHECK_NAME' on #$pr"
  return 1
}

main() {
  : "${BUMP_PR:?BUMP_PR is required}"
  local dry_run="${DRY_RUN:-false}"

  local bump_head bump_state
  bump_head=$(gh pr view "$BUMP_PR" --json headRefName --jq .headRefName)
  bump_state=$(gh pr view "$BUMP_PR" --json state --jq .state)
  if [ "$bump_state" != "OPEN" ]; then
    log "Bump PR #$BUMP_PR is $bump_state, nothing to do."
    return 0
  fi

  git fetch --quiet origin "$bump_head"
  git checkout --quiet -B "$bump_head" "origin/$bump_head"

  local candidates
  candidates=$(gh pr list --state open --label "$LABEL" \
    --json number,title,body,headRefName,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository | not)]')

  local merged=() merged_titles=() count i
  count=$(jq length <<<"$candidates")
  if [ "$count" -eq 0 ]; then
    log "No open PRs labeled '$LABEL'."
    return 0
  fi

  for i in $(seq 0 $((count - 1))); do
    local number title head models model missing=""
    number=$(jq -r ".[$i].number" <<<"$candidates")
    title=$(jq -r ".[$i].title" <<<"$candidates")
    head=$(jq -r ".[$i].headRefName" <<<"$candidates")
    models=$(jq -r ".[$i].body // \"\"" <<<"$candidates" \
      | sed -n 's/^[Rr]equires-CLIProxyAPI-Model:[[:space:]]*//p' | tr -d '\r')

    if [ -z "$models" ]; then
      log "#$number has no Requires-CLIProxyAPI-Model line, skipping."
      continue
    fi

    for model in $models; do
      if ! [[ "$model" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log "#$number declares an invalid model id '$model', skipping."
        missing="invalid"
        break
      fi
      if ! registry_lists_model "$model"; then
        missing="$model"
        break
      fi
    done

    if [ -n "$missing" ]; then
      log "#$number not ready: bundled binary does not list '$missing'."
      continue
    fi

    log "#$number is ready: bundled binary lists all required models (${models//$'\n'/ })."
    if [ "$dry_run" = "true" ]; then
      merged+=("$number")
      merged_titles+=("$title")
      continue
    fi

    git fetch --quiet origin "$head"
    if git merge --no-ff --no-edit -m "Merge #$number: $title" "origin/$head"; then
      merged+=("$number")
      merged_titles+=("$title")
    else
      git merge --abort || true
      log "#$number conflicts with the bump branch, skipping."
      gh pr comment "$number" --body "Automatic merge into bump PR #$BUMP_PR hit a conflict. Resolve it, then re-run the 'Merge gated PRs with CLIProxyAPI bump' workflow." || true
    fi
  done

  if [ "${#merged[@]}" -eq 0 ]; then
    log "Nothing to combine."
    return 0
  fi

  if [ "$dry_run" = "true" ]; then
    log "DRY RUN: would merge ${merged[*]} into #$BUMP_PR and squash-merge it."
    return 0
  fi

  git push --quiet origin "HEAD:$bump_head"

  local bump_title new_title extra_body="" n
  bump_title=$(gh pr view "$BUMP_PR" --json title --jq .title)
  new_title="$bump_title"
  for i in "${!merged[@]}"; do
    new_title="$new_title, ${merged_titles[$i]}"
    extra_body="$extra_body- #${merged[$i]}: ${merged_titles[$i]}"$'\n'
  done
  local body_file
  body_file=$(mktemp)
  {
    gh pr view "$BUMP_PR" --json body --jq .body
    printf '\nAlso includes the following PRs, folded in because the bumped binary lists the models they need:\n\n%s' "$extra_body"
  } >"$body_file"
  gh pr edit "$BUMP_PR" --title "$new_title" --body-file "$body_file"

  wait_for_build "$BUMP_PR"
  gh pr merge "$BUMP_PR" --squash --delete-branch

  for n in "${merged[@]}"; do
    gh pr close "$n" --delete-branch \
      --comment "Merged as part of #$BUMP_PR, which shipped together with the CLIProxyAPI bump."
  done
  log "Merged #$BUMP_PR with ${merged[*]}."
}

# Wrapped in main so bash never re-reads this file after `git checkout` swaps branches.
main "$@"; exit
