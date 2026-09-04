# DEPLOY-SMA — PsiTransfer

> Source-build and browser-smoke notes for the `psitransfer` RL environment.
> Baseline: upstream v2.4.4 (`e1040f23d985810e6965a54dcb77e4f86542216f`)
> plus Node 24 tus fix, `tester-env` CLI, and deterministic seed.

## Quick Start

```bash
./tester-env deploy    # Build image from editable source, start container
./tester-env seed      # Populate the 3 deterministic buckets via tus API
./tester-env verify    # Assert seeded state (names/sizes/retentions/gates)
/tester-env reset      # Stop container + wipe data volume (clean slate)
```

## Build

```bash
docker build -t tester-env-psitransfer:dev .
```

- Single-container Node app (`node:24-alpine`, `npm ci`, frontend rebuilt
  inside the image, `CMD node app.js`).
- Built from editable source in this repo (required for mutation scenarios).
- Cold build ~145s.

### Node 24 tus fix (baseline delta vs upstream v2.4.4)

`lib/store.js` `Store.append` used
`fsp.createWriteStream(path, {flags: 'a', start: offset})`, which Node >= 22
rejects (`ENOTSUP: operation not supported on socket, write`). Fixed with
native `fs` streams: plain append (`{flags: 'a'}`, no `start`) plus an
explicit current-size vs `Upload-Offset` check that throws
`OffsetMismatch` (409) on mismatch. `getFileStream` switched to native
`fs.createReadStream` for the same reason. The tus client always resumes at
`Upload-Offset == current size`, so plain append is positionally correct.

## Run

```bash
docker run -d --name tester-env-psitransfer \
  -p 8095:3000 \
  -v psitransfer-data:/data \
  -e PSITRANSFER_PORT=3000 \
  -e PSITRANSFER_ADMIN_PASS=test-admin-123 \
  -e PSITRANSFER_UPLOAD_DIR=/data \
  tester-env-psitransfer:dev
```

- Local URL: `http://localhost:8095` (host 8095 -> container 3000).
- Health check: `curl http://localhost:8095/` and `/admin` return 200.
- Env: `PSITRANSFER_PORT=3000`, `PSITRANSFER_UPLOAD_DIR=/data`,
  `PSITRANSFER_ADMIN_PASS=test-admin-123`. No upload password by default.
- Filesystem store on the `psitransfer-data` volume; no DB, no logins.

## Credentials

- Admin page `/admin`: request header `x-passwd: test-admin-123`.
- No app logins. Upload endpoint has no upload password by default.

## Reset

```bash
./tester-env reset     # docker stop/rm + docker volume rm (image kept)
./tester-env deploy    # rebuild/restart cleanly (idempotent-ish)
```

Reset removes the container and the named data volume but not the image
(content-addressed tags may be shared across runs).

## Deterministic Seed Data

- Seed: `./tester-env seed` (definitions in `tester-env-seed.sh`, sourced
  by the CLI; idempotent — skips files already present).
- Verify: `./tester-env verify` (asserts admin sid set, file names/sizes/
  retentions, password gate, share pages, byte-identical download).
- Full cycle: `reset -> deploy -> seed -> verify`.

| Bucket (sid) | Protection | Retention | Files |
|---|---|---|---|
| `a1b2c3d4e5f6` | open | `604800` (1 week) | `release-notes.txt`, `launch-checklist.txt` |
| `9f8e7d6c5b4a` | password `share-secret-7` | `86400` (1 day) | `budget-review.csv` |
| `012345abcdef` | open | `3600` (1 hour, short-expiry case) | `one-hour-memo.txt` |

Totals: 3 buckets, 4 files. File keys are server-generated UUIDs and differ
per run; assertions use names, byte sizes, and retention values only.
Full inventory: see `SEED.md`.

## Browser Evidence (gates passed pre-fork)

- Source build: pinned v2.4.4 == `e1040f2`; container live at
  `http://localhost:8095`; `GET /` and `/admin` 200; reset + redeploy
  re-verified; tus POST+PATCH covered.
- Browser smoke (re-smoke after tus fix): upload page loads; upload with
  password `smoketest123` + 1-week retention completed; banner
  `Upload completed` with share link; password gate enforced, decrypt
  revealed file; `New upload` returns clean state.
- Seed (two reset->deploy->seed->verify cycles green + double-seed
  idempotent; browser-verified): `/a1b2c3d4e5f6` 2-file list + zip/tar.gz;
  `/9f8e7d6c5b4a` gate unlocked by `share-secret-7`; `/012345abcdef`
  one-hour memo; `/admin` (`test-admin-123`) 3-row bucket table with lock
  icon only on the password bucket, Sum 0.43 kB.
