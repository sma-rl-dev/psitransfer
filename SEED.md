# PsiTransfer Seed Note

Deterministic seed for the `psitransfer` prospect (filesystem store on the
`psitransfer-data` volume; no DB, no logins).

## Commands

```sh
./tester-env reset          # wipe container + data volume (clean state)
./tester-env deploy         # build from source, start on http://localhost:8095
./tester-env seed           # create the 3 fixed buckets below via the tus API (idempotent)
./tester-env verify         # assert seeded state, no junk buckets created
```

Full cycle: `reset -> deploy -> seed -> verify`. Seed definitions live in
`tester-env-seed.sh` (sourced by `tester-env`).

## Credentials

- Admin page `/admin`: header `x-passwd: test-admin-123`
  (`PSITRANSFER_ADMIN_PASS=test-admin-123`).
- No app logins. Upload endpoint has no upload password by default.

## Seed inventory (fixed across resets)

| Bucket (sid) | Protection | Retention | Files |
|---|---|---|---|
| `a1b2c3d4e5f6` | open | `604800` (1 Week) | `release-notes.txt`, `launch-checklist.txt` |
| `9f8e7d6c5b4a` | password `share-secret-7` | `86400` (1 Day) | `budget-review.csv` |
| `012345abcdef` | open | `3600` (1 Hour, short-expiry case) | `one-hour-memo.txt` |

Totals: 3 buckets, 4 files. File keys are server-generated UUIDs and differ
per run; assertions use names, byte sizes, and retention values only.

## Browser-visible assertions

- `/` serves the upload page; completing an upload shows "Upload completed"
  plus a share link `/<12-char sid>`.
- `/a1b2c3d4e5f6` shows 2 files with zip/tar.gz archive buttons.
- `/9f8e7d6c5b4a` prompts for the bucket password; `share-secret-7` unlocks
  `budget-review.csv`.
- `/admin` (header `x-passwd: test-admin-123`) lists the 3 buckets with
  distinct expiry dates; the locked bucket shows a key icon.
