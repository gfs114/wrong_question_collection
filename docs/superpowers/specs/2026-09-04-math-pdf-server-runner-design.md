# Math PDF Server Runner Design

## Goal

Provide a single Node.js script that can run on the deployed server and exercise
the existing PDF import API from upload through review draft retrieval. The
script is a black-box test client: it must not bypass authentication, write the
database directly, confirm drafts, or change server behavior.

## Chosen approach

Use Node.js built-in HTTP, filesystem, hashing and JSON support. This is
preferred over a Bash/curl script because it does not require `jq`, and over
TypeScript because it does not require installing or building dependencies
before use. The deployed server already provides Node.js.

The runner will:

1. Validate and hash the source PDF.
2. Create an import with the requested absolute page range.
3. Split the file into exactly the `partCount` returned by the server.
4. Upload every part with its lowercase SHA-256 header.
5. Complete the upload and poll the existing status endpoint.
6. Fetch the draft only after the job reaches `review`.
7. Write the raw draft response and a separate run metadata JSON file.
8. Optionally fail the command when expected question labels or count are absent.

## Security and failure behavior

- Read the bearer token from `--token` or `WQC_ACCESS_TOKEN` and never print it.
- Verify TLS normally; support `--ca-cert` for the deployment CA. `--insecure`
  is explicit and intended only for an isolated test server. Plain HTTP is
  accepted automatically only for loopback; any remote HTTP target requires
  the explicit `--allow-http` acknowledgement.
- Preserve failed jobs and a sanitized stage/error summary for diagnosis; do
  not automatically cancel or confirm an import.
- Bound every request and enforce a fixed deadline from `complete` to `review`.
- Treat `failed`, `cancelled`, and `expired` as terminal failures.

## Files

- `server/scripts/math-pdf-import-e2e.cjs`: executable black-box runner.
- `server/scripts/tests/math-pdf-import-e2e.test.cjs`: `node:test` tests with
  an in-process fake API server.

## Verification

Run the script with `node --test`, server Jest tests, TypeScript build, worker tests, and
`--help`. The real two-page PDF run is performed on the deployed server with an
access token; its output becomes `before-fix-draft.json` or
`after-fix-draft.json`.
