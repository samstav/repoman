#!/usr/bin/env bash

# Undefined variables are errors.
set -euoE pipefail

errcho ()
{
    printf "%s\n" "$@" 1>&2
}

errxit ()
{
  errcho "$@"
  cleanup
  exit 1
}

_pushd () {
    command pushd "$@" > /dev/null
}

_popd () {
    command popd > /dev/null
}

function log () {
  printf "%s\n" "$@"
}

_tree_func () {
    if [ -x "$(command -v tree)" ]; then
      tree
      return $?
    else
      find . -print | sort | sed 's;[^/]*/;|---;g;s;---|; |;g'
      return $?
    fi
}



# Constants / Arguments
# To override, user should export $GH_HOST before running this test script.
export GH_HOST=${GH_HOST:-'github.com'}
export GITHUB_OWNER=${GITHUB_OWNER:-}

TMPTESTWORKDIR=$(mktemp -t 'gitmux-test-XXXXXX' -d || errxit "Failed to create tmpdir.")
echo "Working in tmpdir ${TMPTESTWORKDIR}"
_pushd "${TMPTESTWORKDIR}"

repositoriesToDelete=()
cleanup() {
  errcho "Cleaning up!"
  rm -rf "${TMPTESTWORKDIR}"
  for r in "${repositoriesToDelete[@]}"; do
     echo "Deleting ${r}"
     gh api --method DELETE repos/"${r}"
  done
  echo "🛀"
}

# shellcheck disable=SC2120
errcleanup() {
  if [ -n "${1:-}" ]; then
    _errmsg="⏩ Error at line ${1}"
    if [ -n "${2:-}" ]; then
      _errmsg="${_errmsg} in function '${2}'"
    fi
    errcho "${_errmsg}"
  fi
  errcho "⛔️ Tests failed."
  cleanup
  exit 1
}

trap 'errcleanup ${LINENO} ${FUNCNAME:-}' ERR

rands() {
  # Usage: rands
  echo $RANDOM$RANDOM | tr '0-9' '[:lower:]'
}

createRepository() {
  local _owner="${1}"
  local _project="${2}"
  local _visibility=${3:-'public'}
  if [[ -z "${_project}" ]] || [[ -z "${_owner}" ]]; then
    errxit "Repository owner and project are required. Usage: \`createRepository <ownerName> <repositoryName>\`"
  fi

  _ghcreateopts=''
  case ${_visibility} in
    internal) _ghcreateopts="--internal" ;;
    public) _ghcreateopts="--public" ;;
    private) _ghcreateopts="--private" ;;
    *) errxit "Not a valid value for visibility (choose one of public/private)";;
  esac

  ########## <GH CREATE REPO> ################
  # `gh repo create` must be run from inside a git repository. (weird)
  # gh repo create [<name>] [flags]
  TMPGHCREATEWORKDIR=$(mktemp -t 'gitmux-tests-XXXXXX' -d || errxit "Failed to create tmpdir.")
  _pushd "${TMPGHCREATEWORKDIR}"
  NEW_REPOSITORY_DESCRIPTION="Test repository for gitmux. If you find this lingering you may safely delete this repository."
  log "gh-cli is creating your new repository now!"
  gh repo create "${_owner}/${_project}" ${_ghcreateopts:-} --confirm --description "${NEW_REPOSITORY_DESCRIPTION}"
  log "renaming origin to hello"
  git remote rename origin hello
  git commit --message 'Hello: this repository was created by gitmux.' --allow-empty
  git remote --verbose show
  log "pushing change to hello"
  git push hello "master:master"
  _popd
  log "cleaning up gh-create-repo workdir"
  rm -rf "${TMPGHCREATEWORKDIR}"
  ########## </GH CREATE REPO> ################
}


#####################################
#### Setup source git repository.
#####################################
SOURCE_REPOSITORY_NAME="gitmux_test_source_$(rands)"
mkdir -p "${SOURCE_REPOSITORY_NAME}"
_pushd "${SOURCE_REPOSITORY_NAME}" && SOURCE_REPOSITORY_PATH="$(pwd)"
git init
createRepository "${GITHUB_OWNER}" "${SOURCE_REPOSITORY_NAME}"
repositoriesToDelete+=("${GITHUB_OWNER}/${SOURCE_REPOSITORY_NAME}")
git remote add source_remote_name "git@${GH_HOST}:${GITHUB_OWNER}/${SOURCE_REPOSITORY_NAME}.git"
git fetch source_remote_name
git checkout -b something-new --track source_remote_name/master
echo "Hello World" > "hello.txt"
echo "## wat" > 'wat.md'
mkdir -p toto
echo 'TUTU' > 'toto/tutu.txt'
echo 'TATA' > 'toto/tata.txt'
git add "hello.txt"
git commit -m 'initial source repo commit: gitmux test'
git add "wat.md"
git commit -m 'and now wat?'
git add toto
git commit -m 'toto/ 🇫🇷'
_sha=$(git rev-parse --short HEAD)
_popd

#####################################
#### Setup destination git repository.
#####################################
DESTINATION_REPOSITORY_NAME="gitmux_test_destination_$(rands 8)"
mkdir -p "${DESTINATION_REPOSITORY_NAME}"
_pushd "${DESTINATION_REPOSITORY_NAME}"
DESTINATION_REPOSITORY_PATH="$(pwd)"
git init
createRepository "${GITHUB_OWNER}" "${DESTINATION_REPOSITORY_NAME}"
repositoriesToDelete+=("${GITHUB_OWNER}/${DESTINATION_REPOSITORY_NAME}")
git remote add destination_remote_name "git@${GH_HOST}:${GITHUB_OWNER}/${DESTINATION_REPOSITORY_NAME}.git"
git fetch --update-head-ok destination_remote_name
# This actually creates a local 'master' tracking branch.
git checkout master
# Now back to current branch.
git checkout -b destination_current_branch --track destination_remote_name/master
git commit --allow-empty -m 'initial destination repo commit: gitmux test'
_popd && _popd


echo
echo "*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*"
echo

##########################################
#### Test 1:
####    - defaults
####    - use existing github repository
####    - rebase strategy 'ours'
##########################################

test_defaults_with_existing_upstream_destination() {
  ./gitmux.sh -v -r "${SOURCE_REPOSITORY_PATH}" -t "${DESTINATION_REPOSITORY_PATH}"
  _pushd "${DESTINATION_REPOSITORY_PATH}"
  git checkout "update-from-something-new-${_sha}-rebase-strategy-ours"
  local output=''
  if output=$(cat hello.txt) && [ "${output}" == "Hello World" ];then
    echo "${output}" && echo "✅ Success"
    # reset
    git checkout destination_current_branch
  else
    errcleanup
  fi
  _popd
}

echo
echo "*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*"
echo

##########################################
#### Test 2:
####    - With -p (place in subdir at destination)
####    - use existing github repository
####    - rebase strategy 'theirs'
##########################################

test_rebase_strategy_theirs_with_existing_upstream_destination() {
  ./gitmux.sh -v -r "${SOURCE_REPOSITORY_PATH}" -t "${DESTINATION_REPOSITORY_PATH}" -p place_content_in_this_subdir -b master -X theirs
  _pushd "${DESTINATION_REPOSITORY_PATH}"
  git checkout "update-from-something-new-${_sha}-rebase-strategy-theirs"
  local output=''
  if output=$(cat place_content_in_this_subdir/hello.txt) && [ "${output}" == "Hello World" ];then
    echo "${output}" && echo "✅ Success"
  else
    errcleanup
  fi
  _popd
}

echo
echo "*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*"
echo

##########################################
#### Test 3:
####    - defaults with -c (create repo for me)
####    - gitmux should create repository for me
####    - rebase strategy 'ours'
##########################################

test_defaults_destination_dne_yet() {
  NEW_REPO_URI="${GITHUB_OWNER}/gitmux_test_destination_$(rands 8)"
  repositoriesToDelete+=("${NEW_REPO_URI}")
  NEW_REPO_NO_UPSTREAM_YET="git@${GH_HOST}:${NEW_REPO_URI}.git"
  ./gitmux.sh -v -c -r "${SOURCE_REPOSITORY_PATH}" -t "${NEW_REPO_NO_UPSTREAM_YET}"
  _pushd "${DESTINATION_REPOSITORY_PATH}"
  git checkout "update-from-something-new-${_sha}-rebase-strategy-ours"
  local output=''
  if output=$(cat hello.txt) && [ "${output}" == "Hello World" ];then
    echo "${output}" && echo "✅ Success"
    # reset
    git checkout destination_current_branch
  else
    errcleanup
  fi
  _popd
}

echo
echo "*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*"
echo

##########################################
#### Test 4:
####    - defaults with -c (create repo for me)
####    - gitmux should create repository for me
####    - rebase strategy 'ours'
####    - add github team infraconfig/infracore
##########################################

test_defaults_add_orgteam() {
  NEW_REPO_PROJECT_NAME="gitmux_test_destination_$(rands)"
  repositoriesToDelete+=("${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}")
  NEW_REPO_NO_UPSTREAM_YET="git@${GH_HOST}:${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}.git"
  ./gitmux.sh -v -c -r "${SOURCE_REPOSITORY_PATH}" -t "${NEW_REPO_NO_UPSTREAM_YET}" -z infraconfig/infracore
  log "Now cloning repository which should have been created on GitHub by gitmux."
  git clone "${NEW_REPO_NO_UPSTREAM_YET}"
  # This should create a directory called $NEW_REPO_PROJECT_NAME
  _pushd "${NEW_REPO_PROJECT_NAME}"
  # update-from-something-new-23eae47-rebase-strategy-ours
  git checkout "update-from-something-new-${_sha}-rebase-strategy-ours"
  local output=''
  if output=$(cat hello.txt) && [ "${output}" == "Hello World" ];then
    echo "${output}" && echo "✅ Success"
    # reset
    git checkout destination_current_branch
  else
    errcleanup
  fi
  _popd
}

echo
echo "*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*~*"
echo

##########################################
#### Test 5:
####    - defaults with -c (create repo for me)
####    - gitmux should create repository for me
####    - rebase strategy 'ours'
####    - selective file migration
##########################################

test_defaults_destination_dne_yet_only_wat() {
  NEW_REPO_PROJECT_NAME="gitmux_test_destination_$(rands)"
  repositoriesToDelete+=("${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}")
  NEW_REPO_NO_UPSTREAM_YET="git@${GH_HOST}:${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}.git"
  ./gitmux.sh -v -c -r "${SOURCE_REPOSITORY_PATH}" -t "${NEW_REPO_NO_UPSTREAM_YET}" -l "wat.md"
  log "Now cloning repository which should have been created on GitHub by gitmux."
  git clone "${NEW_REPO_NO_UPSTREAM_YET}"
  # This should create a directory called $NEW_REPO_PROJECT_NAME
  _pushd "${NEW_REPO_PROJECT_NAME}"
  git checkout "update-from-something-new-${_sha}-rebase-strategy-ours"
  if [ -f hello.txt ]; then
    errcho "File hello.txt should not be here"
    errcleanup
  fi
  local output=''
  pwd
  if output=$(cat wat.md) && [ "${output}" == "## wat" ];then
    echo "${output}" && echo "✅ Success"
    # reset
    git branches
    git checkout destination_current_branch
  else
    errcleanup
  fi
  _popd
}

test_defaults_destination_dne_yet_only_toto() {
  NEW_REPO_PROJECT_NAME="gitmux_test_destination_$(rands)"
  repositoriesToDelete+=("${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}")
  NEW_REPO_NO_UPSTREAM_YET="git@${GH_HOST}:${GITHUB_OWNER}/${NEW_REPO_PROJECT_NAME}.git"
  ./gitmux.sh -v -c -r "${SOURCE_REPOSITORY_PATH}" -t "${NEW_REPO_NO_UPSTREAM_YET}" -l "toto"
  log "Now cloning repository which should have been created on GitHub by gitmux."
  git clone "${NEW_REPO_NO_UPSTREAM_YET}"
  # This should create a directory called $NEW_REPO_PROJECT_NAME
  _pushd "${NEW_REPO_PROJECT_NAME}"
  git checkout "update-from-something-new-${_sha}-rebase-strategy-ours"
  if [ -f hello.txt ]; then
    errcho "File hello.txt should not be here"
    errcleanup
  fi
  if [ -f wat.md ]; then
    errcho "File wat.md should not be here"
    errcleanup
  fi
  local output=''
  pwd
  if output=$(cat toto/tutu.txt) && \
      [ "${output}" == "TUTU" ] && \
      output=$(cat toto/tata.txt) && \
      [ "${output}" == "TATA" ] && \
      _tree=$(_tree_func); then
    echo "${_tree}" && echo "✅ Success"
    # reset
    git branches
    git checkout destination_current_branch
  else
    errcleanup
  fi
  _popd
}


run_test_cases() {
  test_defaults_with_existing_upstream_destination
  test_rebase_strategy_theirs_with_existing_upstream_destination
  test_defaults_destination_dne_yet
  test_defaults_add_orgteam
  test_defaults_destination_dne_yet_only_wat
  test_defaults_destination_dne_yet_only_toto
}


if run_test_cases; then
  echo '✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨'
  echo '✨  All tests completed successfully. ✨'
  echo '✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨✨'
  cleanup
else
  errxit "Tests failed."
fi
