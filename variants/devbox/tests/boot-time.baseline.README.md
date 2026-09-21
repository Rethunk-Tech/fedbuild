# boot-time.baseline

Plaintext integer: the firstboot time budget reference in seconds.

Bless via `FIRSTBOOT_SECS=<n> make bless-boot-time` or overwrite this file
with the observed `FIRSTBOOT_SECS` from the last successful `make smoke` run.

Budget: `make smoke` fails if `FIRSTBOOT_SECS > baseline * 1.20` (20% over).
Override the percentage via env var `BOOT_BUDGET_PCT`.

The current value (`120`) is a placeholder. Replace it with the real observed
value from your environment after a successful `make smoke`.
