#!/usr/bin/env bash

set -euo pipefail

project_id="${UPSTREAM_PROJECT_ID:-44426042}"
gitlab_base_url="${UPSTREAM_GITLAB_BASE_URL:-https://gitlab.com}"
requested_tag="${1:-${INPUT_UPSTREAM_TAG:-}}"

if [[ -n "$requested_tag" ]]; then
  release_api_url="$gitlab_base_url/api/v4/projects/$project_id/releases/$requested_tag"
else
  release_api_url="$gitlab_base_url/api/v4/projects/$project_id/releases/permalink/latest"
fi

release_json="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 5 "$release_api_url")"
tag_name="$(jq -r '.tag_name // empty' <<<"$release_json")"
version="${tag_name#v}"
commit_sha="$(jq -r '.commit.id // empty' <<<"$release_json")"
release_url="$(jq -r '._links.self // empty' <<<"$release_json")"
published_at="$(jq -r '.released_at // .created_at // empty' <<<"$release_json")"
source_tarball_url="$(jq -r '[.assets.sources[]? | select(.format == "tar.gz") | .url][0] // empty' <<<"$release_json")"

if [[ -z "$tag_name" ]]; then
  echo "Failed to resolve the upstream release tag from $release_api_url" >&2
  exit 1
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "tag_name=$tag_name"
    echo "version=$version"
    echo "commit_sha=$commit_sha"
    echo "release_url=$release_url"
    echo "published_at=$published_at"
    echo "source_tarball_url=$source_tarball_url"
    echo "description<<__MISSION_CENTER_DESCRIPTION__"
    jq -r '.description // ""' <<<"$release_json"
    echo "__MISSION_CENTER_DESCRIPTION__"
  } >>"$GITHUB_OUTPUT"
fi

printf '%s\n' "$release_json"
