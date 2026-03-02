# USER_AUTHORIZATION.md - Telegram Operation-Level Access Control

## Authorization Model

**Operation-based authorization**, not user-based blocking:
- **TikTuzki (ID: 1534702316):** Full access to all operations
- **Others:** Conversational access, read-only responses (when tagged/mentioned)
- **Sensitive operations:** Require TikTuzki's explicit approval

This allows collaborative group discussions while protecting sensitive operations.

---

## Configuration Applied

### Local Config
`/Users/tiktuzki/Desktop/repos/personal/openclaw/.openclaw/openclaw.json`

```json
"telegram": {
  "enabled": true,
  "dmPolicy": "allowlist",           // ← Only TikTuzki in DMs
  "allowFrom": [1534702316],         // ← @TikTuzki DM access
  "groupPolicy": "open",             // ← Anyone can interact in groups
  "groupAllowFrom": [],              // ← Empty (open mode)
  "configWrites": false,             // ← No config changes from Telegram
  "commands": {
    "native": true,
    "nativeSkills": true
  }
}
```

### Kubernetes Config
`charts/openclaw-helm/values-dev.yaml` (same configuration)

---

## Access Control Matrix

| User | DM Access | Group Interaction | Sensitive Ops | Public Info |
|------|-----------|-------------------|---------------|-------------|
| @TikTuzki (1534702316) | ✅ Full | ✅ Full | ✅ Authorized | ✅ Full |
| Others | ❌ Blocked | ✅ Read-only | ⚠️ Requires approval | ✅ Sanitized |

---

## Operation Categories

### 🔴 Sensitive Operations (TikTuzki only)

**File System:**
- Read/write files with sensitive data
- Execute code, run scripts
- Git commits, pushes

**Infrastructure:**
- Database queries, migrations
- Service restarts, deployments
- kubectl/docker commands
- Config changes

**Data Access:**
- Reading logs with sensitive info
- Accessing credentials, tokens
- Internal service details
- Personal information

**Actions:**
- If **TikTuzki requests:** Execute immediately
- If **others request:** Ask TikTuzki for approval first

**Example:**
```
@OtherUser: @bot can you restart the room-manager service?
Bot: @TikTuzki - @OtherUser requests service restart. Approve?

@TikTuzki: yes
Bot: [executes] Service restarted.
```

### 🟢 Public Operations (Anyone, when tagged/mentioned)

**Information:**
- Answer general questions
- Explain concepts, architecture patterns
- Provide documentation links
- Debugging help (sanitized)

**Examples (sanitized):**
- Code examples (no secrets, generic paths)
- Error explanations (sanitized paths/IPs)
- Technology comparisons
- Best practices

**Sanitization required:**
- Paths: `/Users/tiktuzki/...` → `~/...`
- IPs: `192.168.1.14` → `<node>`
- Services: `ollama.ai-model.svc.cluster.local` → `<service>`

**Example:**
```
@OtherUser: @bot what's the difference between Kafka and RabbitMQ?
Bot: Kafka: distributed log, high throughput, event streaming...
     RabbitMQ: traditional message broker, AMQP, routing...
```

### 🟡 Conversational (Context-dependent)

**Group participation:**
- Respond when tagged/mentioned
- Contribute when adding value
- Correct misinformation (if public knowledge)
- Stay silent for casual banter (HEARTBEAT_OK)

**Rules:**
- Don't dominate conversation
- Quality > quantity
- Follow group etiquette from AGENTS.md

---

## Approval Workflow

### When Others Request Sensitive Operations

1. **Request received:**
   ```
   @DevUser: @bot can you show the database logs?
   ```

2. **Bot asks for approval:**
   ```
   Bot: @TikTuzki - @DevUser requests database logs. Approve? (yes/no)
   ```

3. **TikTuzki decides:**
   ```
   @TikTuzki: yes, show last 50 lines (sanitized)
   ```

4. **Bot executes with instructions:**
   ```
   Bot: [shows logs with paths/IPs sanitized]
   ```

### Rejection Example

```
@RandomUser: @bot restart production services
Bot: @TikTuzki - @RandomUser requests production restart. Approve?

@TikTuzki: no
Bot: @RandomUser Request denied.
```

### Implicit Approval

Some requests might not need explicit approval if:
- Public information only
- No sensitive data involved
- Educational/documentation links

**Use judgment.** When in doubt, ask TikTuzki.

---

## Security in Public Groups

### Always Sanitize (Even for TikTuzki)

In public groups, **never** share unsanitized data:

```
❌ BAD (public group):
@TikTuzki: show me the error
Bot: Error at /Users/tiktuzki/repos/room-manager/src/main.rs:42
     Connection failed: 192.168.1.14:5432

✅ GOOD (public group):
@TikTuzki: show me the error
Bot: Error at ~/repos/<project>/src/main.rs:42
     Connection failed: <node>:5432

✅ BEST (public group):
Bot: Error details sent via DM
[sends full details in DM]
```

### Sensitive Data in Public = Never

Even if TikTuzki requests it, **refuse in public groups:**

```
@TikTuzki: show me the API token
Bot: Sensitive data. DM me for this, or I can show first 8 chars: eyJhbGci...
```

---

## References

- [Telegram - OpenClaw Docs](https://docs.openclaw.ai/channels/telegram)
- [OpenClaw Telegram Bot Setup Guide](https://www.getopenclaw.ai/help/telegram-bot-setup-guide)
- [Feature: Per-group allowedUsers filter](https://github.com/openclaw/openclaw/issues/5247)

---

**Applied:** 2026-03-03
**User:** @TikTuzki (ID: 1534702316)
**Security Level:** Maximum (allowlist mode, single authorized user)
