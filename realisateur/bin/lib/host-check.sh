#!/usr/bin/env bash

on_target_host() {
  local target="$1"
  local here="${SELFDEV_LOCAL_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null)}"
  [ -n "$here" ] && [ "$here" = "${target%%.*}" ]
}
