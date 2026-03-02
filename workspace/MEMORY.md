# MEMORY.md - Long-Term Memory

## About This File
Long-term curated memory. Daily files are raw logs, this is the distilled essence.

## User Context
- Bilingual: Vietnamese (native) / English (working)
- Stoic tone: cold, precise, factual - match input language
- Backend architect, distributed systems (5+ years)
- DDD, clean architecture, event-driven patterns
- Code > prose for technical explanations
- **Telegram:** @TikTuzki (ID: 1534702316) - ONLY authorized user

### Tech Preferences
- JVM: Kotlin over Java
- Rust for systems work
- FastAPI for Python services
- GitOps via ArgoCD
- Local Kubernetes dev cluster (node1)

## Projects

### OpenClaw Configuration
- **Config:** `/Users/tiktuzki/Desktop/repos/personal/openclaw/.openclaw/openclaw.json`
- **Runtime workspace:** `/home/node/.openclaw/workspace`
- **Primary model:** anthropic/claude-sonnet-4-6
- **Secondary:** ollama/qwen3:8b (ollama.ai-model.svc.cluster.local:11434)
- **Gateway:** Port 18789 (NodePort 31789), local mode
- **Issue:** userTimezone=UTC, should be Asia/Ho_Chi_Minh

## Infrastructure

### Kubernetes Cluster
- Local dev cluster, node1 (192.168.1.14)
- Persistent volumes: /home/tik/data/
- ArgoCD for GitOps

### Services
- PostgreSQL, TimescaleDB
- RabbitMQ, Kafka, NATS
- Keycloak
- Ollama (local LLM)

## Patterns & Conventions

### Git
- Commit: imperative, lowercase (`add kafka consumer for events`)
- Branches: feature/, fix/, chore/

### Code Organization
- Java/Kotlin: domain / application / infrastructure / interfaces (DDD)
- Rust: workspace Cargo.toml
- Python: FastAPI + Poetry

### Tools
- Build: Gradle (Kotlin DSL), Cargo, Poetry
- API: HTTPie or curl
- DB: Flyway, Alembic
- Secrets: env vars or Vault

## Lessons Learned

## Things to Remember
- Location: Ho Chi Minh City, GMT+7
- 5+ years experience - no hand-holding
- Precision > warmth
- Nihilist/stoic philosophy
- Dark humor appreciated (sparingly)
