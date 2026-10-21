#!/bin/bash

# Sourced by release scripts; validate before using version values in paths or commands.
validate_release_tag() {
  if [[ ! "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    echo 'Expected a version tag such as v0.2.0 or v0.2.0-beta.1.' >&2
    return 1
  fi
}
