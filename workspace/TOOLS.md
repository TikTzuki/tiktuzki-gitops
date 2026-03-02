# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```
## Local conventions
- Java/Kotlin projects follow DDD structure: domain / application / infrastructure / interfaces
- Rust projects use workspace Cargo.toml setup
- Python projects use FastAPI + Poetry
- All services containerized via Docker, orchestrated via Helm/K8s

## Preferred tooling
- Build: Gradle (Kotlin DSL) for JVM, Cargo for Rust
- API testing: HTTPie or curl, not Postman
- DB migration: Flyway (JVM), Alembic (Python)
- Secrets: environment variables or Vault — never hardcoded

## Git conventions
- Commit messages: imperative, lowercase, concise. Example: `add kafka consumer for order events`
- Branch naming: `feature/`, `fix/`, `chore/`


## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
