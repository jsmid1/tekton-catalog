#!/usr/bin/env bash
# Copyright 2023 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

# Use this script to sync the task and pipeline definitions with those
# found in the conforma/cli repository.
# Usage:
#   sync-ec-cli-tasks.sh <PATH_TO_EC_CLI_REPO>

set -o errexit
set -o pipefail
set -o nounset

EC_CLI_REPO_PATH="${1}"

collect_remote_branches() {
  git fetch origin > /dev/null
  echo "$(git branch --remote --format '%(refname:lstrip=-1)' --sort=refname --list 'origin/release-v*')"
}

# pin unpinned quay.io/conforma/cli image references in the given directory
pin_images() {
  local dir=${1}
  if [[ ! -d "${dir}" ]]; then
    return
  fi
  pushd "${dir}" > /dev/null
  images="$(grep -r -h -o -w 'quay.io/conforma/cli:.*' | grep -v '@' | sort -u || true)"
  if [[ -z "${images}" ]]; then
    echo "No unpinned images found in ${dir} - all images are already pinned"
    popd > /dev/null
    return
  fi
  for image in $images; do
    echo "Resolving image $image"
    digest="$(skopeo manifest-digest <(skopeo inspect --raw "docker://${image}"))"
    pinned_image="${image}@${digest}"
    echo "↳ ${pinned_image}"
    find . -type f -exec sed -i "s!${image}!${pinned_image}!g" {} +
  done
  popd > /dev/null
}

# helper function to add tasks and pipelines to a git branch
add_definitions() {
  local branch=${1}
  local remote_branch=${2}
  local base_branch="${remote_branch#origin/}"
  local sync_branch="sync/${branch}"
  pushd "${EC_CLI_REPO_PATH}" > /dev/null
  git checkout "${branch}"
  popd > /dev/null
  git checkout -B "${sync_branch}" --track "${remote_branch}"

  # Remove definitions deleted upstream since cp -r does not handle deletions.
  for d in tasks/*/; do
    [[ -d "$d" && ! -d "${EC_CLI_REPO_PATH}/${d}" ]] && git rm -rf "$d" || true
  done

  cp -r "${EC_CLI_REPO_PATH}/tasks" .
  # older release branches don't have pipelines/
  if [[ -d "${EC_CLI_REPO_PATH}/pipelines" ]]; then
    for d in pipelines/*/; do
      [[ -d "$d" && ! -d "${EC_CLI_REPO_PATH}/${d}" ]] && git rm -rf "$d" || true
    done
    cp -r "${EC_CLI_REPO_PATH}/pipelines" .
  fi
  pin_images tasks
  pin_images pipelines
  diff="$(git status --porcelain)"
  if [[ -z "${diff}" ]]; then
      echo "No changes to sync for ${branch}"
      return
  fi

  git add tasks
  if [[ -d pipelines ]]; then
    git add pipelines
  fi
  git commit -m "sync ec task and pipeline definitions"
  git push -f origin "${sync_branch}"

  if ! gh pr list --repo "${GH_REPO}" --base "${base_branch}" --head "${sync_branch}" --state open --json number | grep -q number; then
    gh pr create --repo "${GH_REPO}" --base "${base_branch}" --head "${sync_branch}" \
      --title "chore: sync task and pipeline definitions to ${branch}" \
      --body "Automated sync of task and pipeline definitions from conforma/cli \`${branch}\`."
  fi
}

if [ -n "${GITHUB_ACTIONS:-}" ]; then
  git config --global user.email "${GITHUB_ACTOR}@users.noreply.github.com"
  git config --global user.name "${GITHUB_ACTOR}"
fi

tekton_catalog_branches=$(collect_remote_branches)
pushd "${EC_CLI_REPO_PATH}" > /dev/null
ec_cli_branches=$(collect_remote_branches)
popd > /dev/null

for branch in ${ec_cli_branches[@]}; do
    if ! echo "$tekton_catalog_branches" | grep -Fxq "$branch"; then
      echo "Skipping ${branch} - no matching branch in tekton-catalog"
      continue
    fi
    add_definitions "${branch}" "origin/${branch}"
done

add_definitions "main" "origin/main"
