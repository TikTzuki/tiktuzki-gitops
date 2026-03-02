# SECURITY.md - OpenClaw Security Guidelines

## Threat Model

### Public Telegram Groups
- **Risk:** Anyone can see messages, including sensitive data
- **Attack vectors:**
  - File path disclosure (`/Users/tiktuzki/...`)
  - API keys, tokens, credentials
  - Infrastructure details (IPs, ports, service names)
  - Code snippets with secrets
  - Database schemas, queries
  - Personal information

### Direct Messages
- **Risk:** Lower but still need caution
- **Attack vectors:**
  - Message history compromise
  - Telegram account takeover
  - Bot token theft

---

## Security Configuration

### ✅ Applied Configuration (SECURE)

```json
"telegram": {
  "enabled": true,
  "dmPolicy": "allowlist",        // ✓ Only TikTuzki (1534702316) in DMs
  "allowFrom": [1534702316],      // ✓ DM access control
  "groupPolicy": "open",          // ✓ Anyone can interact in groups (read-only)
  "groupAllowFrom": [],           // ✓ Empty (open for conversation)
  "configWrites": false,          // ✓ No config changes from Telegram
  "streaming": "off"              // ✓ No streaming to reduce exposure
}
```

**Authorization Model:** Operation-level, not user-level
- **TikTuzki (ID: 1534702316):** Full access to sensitive operations
- **Others:** Conversational access (when tagged), read-only sanitized responses
- **Sensitive operations by others:** Require TikTuzki's explicit approval

See `USER_AUTHORIZATION.md` for complete details and approval workflows.

---

## Agent Guidelines

### Never Share in Public Groups

1. **Credentials**
   - API keys, tokens, passwords
   - Database credentials
   - SSH keys, certificates
   - OAuth tokens, session IDs

2. **Infrastructure Details**
   - Internal IPs, hostnames
   - Database connection strings
   - Service ports (except public)
   - Cluster node names
   - File system paths

3. **Personal Information**
   - Full names, emails, phone numbers
   - Physical addresses
   - Payment information
   - Usernames beyond public handles

4. **Code Secrets**
   - Hardcoded credentials
   - Private repository URLs
   - Internal API endpoints
   - Security vulnerabilities

### Safe to Share (with caution)

- Public repository links (GitHub public repos)
- General architecture patterns (no specific IPs)
- Error messages (sanitize paths/IPs first)
- Code snippets (remove secrets, sanitize paths)
- Public documentation links

---

## Operational Security

### Before Responding in Public Groups

1. **Sanitize file paths**
   - Replace: `/Users/tiktuzki/` → `~/`
   - Replace: `/home/tik/` → `~/`
   - Replace specific project paths → `<project>/`

2. **Sanitize IPs and hostnames**
   - Replace: `192.168.1.14` → `<node>`
   - Replace: `ollama.ai-model.svc.cluster.local` → `<service>`
   - Replace: `node1` → `<node>`

3. **Sanitize credentials**
   - Remove any `token=`, `key=`, `password=` values
   - Replace: `Bearer eyJ...` → `Bearer <token>`
   - Remove connection strings

4. **Review code snippets**
   - No hardcoded secrets
   - No real database names (use `mydb`, `example_db`)
   - No real table/column names if sensitive

### Response Templates

**Public group response:**
```
Error in <service>:
  Path: ~/projects/<name>/src/main.rs:42
  Node: <node>
  Database: <db>
```

**Direct message response:**
```
Error in room-manager:
  Path: /Users/tiktuzki/Desktop/repos/personal/room-manager/src/main.rs:42
  Node: node1
  Database: room_manager_db
```

---

## Workspace Security

### Files That May Contain Secrets

```
workspace/
├── .openclaw/
│   └── workspace-state.json    # Session data
├── memory/
│   └── *.md                    # Daily logs may contain sensitive info
├── WORKFLOW_AUTO.md            # Task details
└── *.html                      # Session exports
```

### Git Security

**Never commit:**
- `.env` files
- `*secret*`, `*credential*`, `*token*` files
- Session exports (`.html`)
- Workspace state files

**Gitignore patterns:**
```gitignore
# OpenClaw workspace
workspace/.openclaw/
workspace/.clawhub/
workspace/*.html
workspace/**/*secret*
workspace/**/*credential*
workspace/**/*.env

# Environment
.env
.env.*
!.env.example

# Credentials
**/credentials.json
**/token.json
**/*_rsa
**/*_rsa.pub
```

---

## Telegram Bot Configuration

### Get Group ID

```bash
# In group, send message to bot, then check:
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | \
  jq '.result[].message.chat'
```

### Lock Down Configuration

1. **Disable config writes**
   ```bash
   # Edit openclaw.json
   "configWrites": false
   ```

2. **Set whitelist mode**
   ```bash
   "groupPolicy": "whitelist"
   ```

3. **Add trusted groups**
   ```bash
   "groupAllowFrom": [
     "-100XXXXXXXXXX"  # Your private group ID
   ]
   ```

4. **Restart OpenClaw**
   ```bash
   kubectl rollout restart deployment openclaw-helm -n default
   ```

---

## Monitoring

### Red Flags in Responses

- Full file paths visible
- IP addresses in output
- Tokens/keys in code
- Database credentials
- Internal service names
- Personal information

### Audit Checklist

- [ ] groupPolicy set to "whitelist"
- [ ] configWrites disabled for public groups
- [ ] groupAllowFrom contains only trusted IDs
- [ ] .gitignore excludes workspace secrets
- [ ] AGENTS.md includes security awareness
- [ ] Response templates use sanitized output

---

## Incident Response

### If Secrets Leaked in Public Group

1. **Immediate:**
   - Delete message if possible
   - Revoke exposed credentials
   - Rotate API keys/tokens
   - Change passwords

2. **Short-term:**
   - Review message history for other leaks
   - Audit who saw the message
   - Update security config

3. **Long-term:**
   - Update AGENTS.md with lesson learned
   - Add check to prevent recurrence
   - Review and tighten permissions

---

## References

- OpenClaw docs: Security best practices
- OWASP: API Security Top 10
- Telegram Bot API: Group management
- Principle: Defense in depth

---

**Last updated:** 2026-03-03
**Severity:** CRITICAL - Review before every public group interaction
