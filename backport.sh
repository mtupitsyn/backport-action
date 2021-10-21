#!/bin/bash
set -o errexit -o pipefail -o nounset

global_branches_success=""
global_branches_failure=""

newline_at_eof() {
  local file="$1"
  if [ -s "${file}" ] && [ "$(tail -c1 "${file}"; echo x)" != $'\nx' ]
  then
    # ensure newline at the end of file
    echo ''>> "${file}"
  fi
}

debug() {
  local outvar=$1
  shift
  echo "::debug::running: $*"

  local stdout
  stdout="$(mktemp)"
  # shellcheck disable=SC2001
  ("$@" 2> >(sed -e 's/^/::debug::err:/') > "${stdout}")
  local rc=$?
  # shellcheck disable=SC2140
  eval "${outvar}"="'$(cat "${stdout}")'"
  newline_at_eof "${stdout}"
  sed -e 's/^/::debug::out:/' "${stdout}"
  rm "${stdout}"

  bash -c 'echo -n' # force flushing stdout so that debug out/err are outputted before rc
  echo "::debug::rc=${rc}"

  return ${rc}
}

http_post() {
  local url=$1
  local json=$2

  local output
  output="$(mktemp)"

  result=''
  debug result curl -XPOST --fail -v -fsL \
    --output "${output}" \
    -w '{"http_code":%{http_code},"url_effective":"%{url_effective}"}' \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "${json}" \
    "${url}"|| true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::result=${result}"
  if [[ ! $(echo "${result}" |jq -r .http_code) =~ ^"2" ]]
  then
    local message
    message=$(echo "${result}"| jq -r -s 'add | (.http_code|tostring) + ", effective url: " + .url_effective')
    echo "::error::Error in HTTP POST to ${url} of \`${json}\`: ${message}"
    exit 1
  fi
}

fail() {
  local message=$1
  local error=${2:-}
  local merged
  merged=$(jq --raw-output .pull_request.merged "${GITHUB_EVENT_PATH}")

  echo "::error::${message} (${error})"

  if [ "${merged}" == "true" ]; then
    local comment="${message}"
    if [ -n "${error}" ]
    then
      comment+="\n\n<details><summary>Error</summary><pre>${error}</pre></details>"
    fi
    local comment_json
    comment_json="$(jq -n -c --arg body "${comment}" '{"body": $body|gsub ("\\\\n";"\n")}')"
    comments_url=$(jq --raw-output .pull_request._links.comments.href "${GITHUB_EVENT_PATH}")
    http_post "${comments_url}" "${comment_json}"
  fi

}

auth_header() {
  local token=$1
  echo -n "$(echo -n "x-access-token:${token}"|base64 --wrap=0)"
}

checkout() {
  local branch=$1
  local repository=$2

  output=''
  if [[ -d "${GITHUB_WORKSPACE}/.git" ]]; then
    debug output git -C "${GITHUB_WORKSPACE}" checkout -B "${branch}" -t "origin/${branch}" || \
        (echo "Unexpected error checking out branch ${branch}, will try fresh clone" && clone "${branch}" "${repository}")
    debug output git -C "${GITHUB_WORKSPACE}" pull --ff-only origin "${branch}" || \
        (echo "Unexpected error refreshing branch ${branch}, will try fresh clone" && clone "${branch}" "${repository}")
  else
    echo "Repo not found, will try fresh clone"
    clone "${branch}" "${repository}"
  fi
}

clone() {
  local branch=$1
  local repository=$2

  output=''
  echo "Cleaning up workspace"
  find "${GITHUB_WORKSPACE}" -mindepth 1 -maxdepth 1 -exec rm -Rf \{\} \;
  echo "Getting fresh repository clone"
  debug output git clone -q --no-tags -b "${branch}" "${repository}" "${GITHUB_WORKSPACE}" || fail "Unable to clone from repository \`${repository}\` a branch named \`${branch}\`, this should not have happened"
  cd "${GITHUB_WORKSPACE}"
}

cherry_pick() {
  local branch=$1
  local repository=$2
  local backport_branch=$3
  local merge_sha=$4

  output=''

  cd "${GITHUB_WORKSPACE}"

  local user_name
  user_name="$(git --no-pager log --format=format:'%an' -n 1)"
  local user_email
  user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

  local commits
  if git show "${merge_sha}" --compact-summary | grep -E -q ^Merge:; then
      echo "Commit ${merge_sha} is a merge commit, PR was merged via 'Merge Commit' strategy. Dependent commits will be cherry-picked automatically."
      commits="${merge_sha}"
  else
      echo "Commit ${merge_sha} is not a merge commit, PR was merged via 'Squash' or 'Rebase' strategy. Building list of commits to cherry-pick."
      base_commit=$(jq --raw-output .pull_request.base.sha "${GITHUB_EVENT_PATH}")
      commits=$(git log --format=%H --reverse "${base_commit}".."${merge_sha}")
  fi

  set +e

  debug output git checkout -q -B "${backport_branch}" \
    || fail "Unable to checkout branch named \`${backport_branch}\` from \`${branch}\`, you might need to create it or use a different label."

  local exit_code=0
  for commit in $commits; do
    echo "Cherry-picking commit ${commit} into branch \`${branch}\`"
    debug output git -c user.name="${user_name}" -c user.email="${user_email}" cherry-pick -x --mainline 1 "${commit}" || exit_code=1
    if [ $exit_code -eq 0 ]; then
      global_branches_success="${global_branches_success} ${branch}"
      echo "Commit cherry-picked successfully"
    else
      global_branches_failure="${global_branches_failure} ${branch}"
      fail "Unable to cherry-pick commit ${commit} on top of branch \`${branch}\`. This pull request needs to be backported manually." "${output}
$(git status)"
      break
    fi
  done

  set -e
  return $exit_code
}

push() {
  local backport_branch=$1

  local auth
  auth="$(auth_header "${INPUT_TOKEN}")"

  (
    cd "${GITHUB_WORKSPACE}"

    local user_name
    user_name="$(git --no-pager log --format=format:'%an' -n 1)"
    local user_email
    user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

    set +e

    git -c user.name="${user_name}" -c user.email="${user_email}" -c "http.https://github.com.extraheader=Authorization: basic ${auth}" push -q --set-upstream origin "${backport_branch}" > /dev/null || fail "Unable to push the backported branch, did you try to backport the same PR twice without deleting the \`${backport_branch}\` branch?"

    set -e
  )
}

create_pull_request() {
  local branch=$1
  local backport_branch=$2
  local title=$3
  local number=$4
  local pulls_url=$5

  local pull_request_title="[Backport ${branch}] ${title}"

  local pull_request_body="Backport of #${number}"

  local pull_request="{\
    \"title\": \"${pull_request_title}\", \
    \"body\": \"${pull_request_body}\", \
    \"head\": \"${backport_branch}\", \
    \"base\": \"${branch}\" \
  }"

  http_post "${pulls_url}" "${pull_request}"
}

backport_dry_run() {
  local number=$1
  local branch=$2
  output=''
  echo "::group::Performing dry run of backporting PR #${number} to branch ${branch}"

  local repository
  repository=$(jq --raw-output .repository.clone_url "${GITHUB_EVENT_PATH}")

  local backport_branch
  backport_branch="backport/${number}-to-${branch}"

  local backport_test_branch
  backport_test_branch="backport/test/${number}-to-${branch}"

  checkout "${GITHUB_HEAD_REF}" "${repository}"
  cd "${GITHUB_WORKSPACE}"

  local user_name
  user_name="$(git --no-pager log --format=format:'%an' -n 1)"
  local user_email
  user_email="$(git --no-pager log --format=format:'%ae' -n 1)"

  checkout "${GITHUB_BASE_REF}" "${repository}"
  debug output git checkout -B "${backport_test_branch}"
  debug output git -c user.name="${user_name}" -c user.email="${user_email}" merge --no-edit --no-ff "${GITHUB_HEAD_REF}"
  local merge_sha
  merge_sha=$(git log -1 --format=%H)

  debug output git checkout "${branch}"
  local exit_code=0
  cherry_pick "${branch}" "${repository}" "${backport_branch}" "${merge_sha}" || exit_code=1
  debug output git branch -D "${backport_test_branch}"
  echo '::endgroup::'
}

backport() {
  local number=$1
  local branch=$2

  echo "::group::Performing backport of PR #${number} to branch ${branch}"

  local repository
  repository=$(jq --raw-output .repository.clone_url "${GITHUB_EVENT_PATH}")

  local backport_branch
  backport_branch="backport/${number}-to-${branch}"

  local merge_sha
  merge_sha=$(jq --raw-output .pull_request.merge_commit_sha "${GITHUB_EVENT_PATH}")

  checkout "${branch}" "${repository}"
  local exit_code=0
  cherry_pick "${branch}" "${repository}" "${backport_branch}" "${merge_sha}" || exit_code=1
  if [ $exit_code -eq 0 ]; then
    push "${backport_branch}"

    local title
    title=$(jq --raw-output .pull_request.title "${GITHUB_EVENT_PATH}")

    local pulls_url
    pulls_url=$(tmp=$(jq --raw-output .repository.pulls_url "${GITHUB_EVENT_PATH}"); echo "${tmp%{*}")

    create_pull_request "${branch}" "${backport_branch}" "${title}" "${number}" "${pulls_url}"
  fi
  echo '::endgroup::'
}

delete_branch() {
  echo '::group::Deleting closed pull request branch'

  local branch=$1
  local refs_url
  refs_url=$(tmp=$(jq --raw-output .pull_request.head.repo.git_refs_url "${GITHUB_EVENT_PATH}"); echo "${tmp%{*}")
  local output
  output="$(mktemp)"

  debug status curl -XDELETE -v -fsL \
    --fail \
    --output "${output}" \
    -w '%{http_code}' \
    -H 'Accept: application/vnd.github.v3+json' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "$refs_url/heads/$branch" || true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::status=${status}"
  if [[ "${status}" == 204 || "${status}" == 422 ]]; then
    echo 'Deleted'
  else
    echo 'Failed to delete branch'
    fail "Unable to delete pull request branch '${branch}'. Please delete it manually."
  fi

  echo '::endgroup::'
}

check_token() {
  echo '::group::Checking token'

  if [[ -z ${INPUT_TOKEN+x} ]]; then
    echo '::error::INPUT_TOKEN is was not provided, by default it should be set to {{ github.token }}'
    echo '::endgroup::'
    exit 1
  fi

  local output
  output="$(mktemp)"

  status=''
  debug status curl -v -fsL \
    --fail \
    --output "${output}" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${INPUT_TOKEN}" \
    "https://api.github.com/zen" || true

  newline_at_eof "${output}"
  sed -e 's/^/::debug::output:/' "${output}"
  rm "${output}"

  echo "::debug::status=${status}"
  if [[ ${status} != 200 ]]
  then
    echo '::error::Provided INPUT_TOKEN is not valid according to the zen API'
    echo '::endgroup::'
    exit 1
  fi

  echo 'Token seems valid'
  echo '::endgroup::'
}

post_check_status() {
  local status_url
  status_url=$(jq --raw-output .pull_request._links.statuses.href "${GITHUB_EVENT_PATH}")
  local state
  state=$(test -n "$global_branches_failure" && echo failure || echo success)
  local description
  if [ -n "${global_branches_success}" ] && [ -n "${global_branches_failure}" ]; then
    description="can be backported: ${global_branches_success}, in conflict: ${global_branches_failure}"
  elif [ -n "${global_branches_success}" ]; then
    description="can be backported: ${global_branches_success}"
  elif [ -n "${global_branches_failure}" ]; then
    description="in conflict: ${global_branches_failure}"
  else
    description="nothing needs to be backported"
  fi

  local status_json="{\"state\": \"${state}\", \"context\": \"mergeability check\", \"description\": \"${description}\"}"
  http_post "${status_url}" "${status_json}"
}

main() {
  echo '::group::Environment'
  for e in $(printenv)
  do
    echo "::debug::${e}"
  done
  echo '::endgroup::'

  local state
  state=$(jq --raw-output .pull_request.state "${GITHUB_EVENT_PATH}")
  local login
  login=$(jq --raw-output .pull_request.user.login "${GITHUB_EVENT_PATH}")
  local title
  title=$(jq --raw-output .pull_request.title "${GITHUB_EVENT_PATH}")
  local merged
  merged=$(jq --raw-output .pull_request.merged "${GITHUB_EVENT_PATH}")

  if [[ "$state" == "closed" && "$login" == "github-actions[bot]" && "$title" == '[Backport '* ]]; then
    check_token
    delete_branch "$(jq --raw-output .pull_request.head.ref "${GITHUB_EVENT_PATH}")"
    return
  fi

  local number
  number=$(jq --raw-output .number "${GITHUB_EVENT_PATH}")
  local labels
  labels=$(jq --raw-output .pull_request.labels[].name "${GITHUB_EVENT_PATH}")

  local default_ifs="${IFS}"
  IFS=$'\n'
  for label in ${labels}; do
    IFS="${default_ifs}"
    # label needs to be `backport <name of the branch>`
    if [[ "${label}" == 'backport '* ]]; then
      local branch=${label#* }
      check_token
      if [[ "$merged" != "true" ]]; then
        backport_dry_run "${number}" "${branch}"
      else
        backport "${number}" "${branch}"
      fi
    fi
  done
  test "${merged}" != "true" && post_check_status
}


${__SOURCED__:+return}

main "$@"

if [ -n "${global_branches_failure}" ]; then
  exit 1
else
  exit 0
fi