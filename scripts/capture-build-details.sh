#!/bin/sh
#  capture-build-details.sh
#  Trio
#
#  Created by Jonas Björkert on 2024-05-08.
#
# NOTE: This script only populates informational build metadata (date, branch,
# commit, submodule SHAs) shown on the app's about screen. It must never abort
# the archive. Under Xcode's user-script sandbox (ENABLE_USER_SCRIPT_SANDBOXING
# = YES) the plist write into BUILT_PRODUCTS_DIR — or the git subprocesses — can
# be denied, and with `set -e` that failure previously killed the whole archive.
# It now runs best-effort and always exits 0.

# Path to BuildDetails.plist in the built product
info_plist_path="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/BuildDetails.plist"

# Ensure the path to BuildDetails.plist is valid. Missing/unwritable → skip
# gracefully rather than failing the build.
if [ "${info_plist_path}" = "/" -o ! -e "${info_plist_path}" ]; then
    echo "BuildDetails.plist not found at path: ${info_plist_path}; skipping build-details capture." >&2
    exit 0
fi

echo "Gathering build details..."

# Capture the current date
plutil -replace com-trio-build-date -string "$(LC_ALL=C date -u '+%a %b %e %H:%M:%S UTC %Y')" "${info_plist_path}"

# --- Root repo details ---
# Retrieve current branch (or tag) and commit SHA.
git_branch=$(git symbolic-ref --short -q HEAD || echo "")
git_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")
git_commit_sha=$(git log -1 --format="%h" --abbrev=7)
git_branch_or_tag="${git_branch:-${git_tag}}"
if [ -z "${git_branch_or_tag}" ]; then
    git_branch_or_tag="detached"
fi

plutil -replace com-trio-branch -string "${git_branch_or_tag}" "${info_plist_path}"
plutil -replace com-trio-commit-sha -string "${git_commit_sha}" "${info_plist_path}"

# --- Submodule details ---
# Remove an existing submodules key if it exists, then create an empty dictionary.
# (Using PlistBuddy, which is available on macOS)
submodules_key="com-trio-submodules"
if /usr/libexec/PlistBuddy -c "Print :${submodules_key}" "${info_plist_path}" 2>/dev/null; then
    /usr/libexec/PlistBuddy -c "Delete :${submodules_key}" "${info_plist_path}"
fi
/usr/libexec/PlistBuddy -c "Add :${submodules_key} dict" "${info_plist_path}"

# Gather submodule details.
# We use git submodule foreach to output lines in the form:
#   submodule_name|branch_or_tag|commit_sha
submodules_info=$(git submodule foreach --quiet '
  sub_git_branch=$(git symbolic-ref --short -q HEAD || echo "")
  sub_git_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")
  sub_git_commit_sha=$(git log -1 --format="%h" --abbrev=7)
  sub_git_branch_or_tag="${sub_git_branch:-${sub_git_tag}}"
  if [ -z "${sub_git_branch_or_tag}" ]; then
    sub_git_branch_or_tag="detached"
  fi
  echo "$name|$sub_git_branch_or_tag|$sub_git_commit_sha"
')

# For each line, add a dictionary entry for that submodule.
echo "${submodules_info}" | while IFS="|" read -r submodule_name sub_branch sub_sha; do
    # Create a dictionary for this submodule
    /usr/libexec/PlistBuddy -c "Add :${submodules_key}:${submodule_name} dict" "${info_plist_path}"
    /usr/libexec/PlistBuddy -c "Add :${submodules_key}:${submodule_name}:branch string ${sub_branch}" "${info_plist_path}"
    /usr/libexec/PlistBuddy -c "Add :${submodules_key}:${submodule_name}:commit_sha string ${sub_sha}" "${info_plist_path}"
done

echo "BuildDetails.plist has been updated at: ${info_plist_path}"

# Never fail the archive over informational metadata.
exit 0