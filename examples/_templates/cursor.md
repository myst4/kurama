<!--
Overlay for Cursor (examples/cursor/.cursor/rules/sdd-orchestrator.mdc).
Holds ONLY this harness's deltas; the shared body lives in core.md.
The HEADER block carries the modern Cursor `.mdc` YAML frontmatter (scoping);
the build script inserts the GENERATED marker right after the frontmatter.
No Model Assignments block for this harness, so that token renders empty.
-->

<!-- @@HEADER@@ -->
---
description: Agent Teams Lite — SDD orchestrator rule (coordinator, delegate-only)
globs:
alwaysApply: true
---
# Agent Teams Lite — Orchestrator for Cursor

Add this to `.cursor/rules/` in your project (modern Cursor rules format; replaces the legacy `.cursorrules`).

<!-- @@DELEGATION_MECHANISM@@ -->
Delegate real work to a sub-agent via Task when available, or run the matching skill phase. Keep only coordination in this thread.

<!-- @@STATE_CONVENTIONS@@ -->
Convention files under `~/.cursor/skills/_shared/` (global) or your project `skills/_shared/` (workspace): `engram-convention.md`, `persistence-contract.md`, `openspec-convention.md`.
