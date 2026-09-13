# Math PDF Server Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a dependency-free Node.js runner for the deployed PDF import API and verify its HTTP contract without changing production services.

**Architecture:** A small `ApiClient` owns authenticated JSON and byte requests. `runImport` owns hashing, server-derived chunking, upload, polling and output persistence; command-line parsing supplies deployment-specific values without storing secrets.

**Tech Stack:** Node.js built-ins (`node:http`, `node:https`, `node:fs`, `node:crypto`, `node:test`).

---

### Task 1: Define the runner contract with failing tests

**Files:**
- Create: `server/scripts/tests/math-pdf-import-e2e.test.cjs`
- Create later: `server/scripts/math-pdf-import-e2e.cjs`

- [x] Test that a fake API observes `POST /v1/imports/pdf`, indexed raw part
  uploads with SHA-256, `complete`, status polling and draft retrieval in order.
- [x] Test that LaTeX backslashes survive draft JSON persistence.
- [x] Test terminal failure, polling deadline, cleartext transport, label
  boundaries, post-create failure summaries, and output-path collisions.
- [x] Run `node --test server/scripts/tests/math-pdf-import-e2e.test.cjs`
  and verify RED because the runner module does not exist.

### Task 2: Implement the minimal standard-library runner

**Files:**
- Create: `server/scripts/math-pdf-import-e2e.cjs`

- [x] Implement `ApiClient.request(method, path, options)`
  with bearer auth, JSON decoding, request timeout and safe error messages.
- [x] Implement exact-count chunking using
  `chunk_size = ceil(source_size / server_part_count)` so every configured
  deployment receives the count it returned from create.
- [x] Implement `runImport` to create, upload, complete, poll, fetch and persist
  without confirm or cancel calls.
- [x] Implement CLI validation, environment token fallback, TLS CA selection,
  explicit insecure mode, expected count/label checks and exit codes.
- [x] Run the focused Node test command and verify GREEN.

### Task 3: Verify repository compatibility

**Files:**
- Verify only; no production files modified.

- [x] Run `node server/scripts/math-pdf-import-e2e.cjs --help`.
- [x] Run `cd server && npm test`.
- [x] Run `cd server && npm run build`.
- [ ] Run worker tests with a short Windows temp base to avoid the pre-existing
  long-path fixture failure.
- [ ] Run `git diff --check` and inspect the final diff.
- [ ] Do not commit, push, confirm a draft, or create a pull request.
