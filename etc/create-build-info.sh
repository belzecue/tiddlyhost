#!/bin/bash

(
  echo date: `date`
  echo sha: `git log -n1 --format=%H`
  echo commit: `git log -n1 --format=%s`
  echo branch: `git rev-parse --abbrev-ref HEAD`
  # Might be useful later
  #echo tag: `git describe --tags --abbrev=0`
) > etc/build-info.txt
