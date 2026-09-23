#!/usr/bin/env bash
# Runs on the guest (smoke.sh pipes it to `ssh ... bash -s`): prints each SELinux
# denial record since boot and exits 0, or exits 2 when ausearch itself fails.
#
# --input-logs is required: without it ausearch reads stdin whenever stdin is
# a pipe, as under ssh, and reports nothing.
# siginh, noatsecure and rlimitinh are the process-transition checks logged on
# every secure exec into a confined domain; they are not policy gaps.

out=$(sudo ausearch --input-logs -m AVC,USER_AVC,SELINUX_ERR -ts boot </dev/null 2>&1)
rc=$?
if ((rc == 0)); then
    printf '%s\n' "$out" |
        grep -E '^type=(AVC|USER_AVC|SELINUX_ERR) ' |
        grep -Ev 'denied +\{ ((siginh|noatsecure|rlimitinh) )+\}' ||
        true
# ausearch also exits 1 when it cannot read the logs, so only its own
# "<no matches>" report counts as a clean pass.
elif ((rc != 1)) || ! grep -qx '<no matches>' <<<"$out"; then
    printf 'ausearch failed (exit %s): %s\n' "$rc" "$out" >&2
    exit 2
fi
