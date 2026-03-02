# OpenClaw Telegram Security Configuration

## ✅ APPLIED CONFIGURATION

**User-level authorization implemented:**
- Only user ID 1534702316 (@TikTuzki) can interact with bot
- All other users silently ignored
- Applied to both DMs and groups
- Config writes disabled

See `USER_AUTHORIZATION.md` for complete details.

---

## Configuration Applied

### Local: `/Users/tiktuzki/Desktop/repos/personal/openclaw/.openclaw/openclaw.json`

```json
"telegram": {
  "enabled": true,
  "dmPolicy": "allowlist",
  "allowFrom": [1534702316],         // @TikTuzki only
  "groupPolicy": "whitelist",
  "groupAllowFrom": [1534702316],    // @TikTuzki only
  "configWrites": false,
  "streaming": "off"
}
```

### Kubernetes: `charts/openclaw-helm/values-dev.yaml`

```json
"channels": {
  "telegram": {
    "enabled": true,
    "botToken": "${TELEGRAM_BOT_TOKEN}",
    "dmPolicy": "allowlist",
    "allowFrom": [1534702316],
    "groupPolicy": "whitelist",
    "groupAllowFrom": [1534702316],
    "configWrites": false,
    "streaming": "off"
  }
}
```

---

### For Local OpenClaw

1. Edit `.openclaw/openclaw.json` with your group IDs
2. Restart OpenClaw:
   ```bash
   # If running via Docker
   docker restart openclaw

   # If running via npm
   # Stop and restart the process
   ```

### For Kubernetes Deployment

1. Edit `charts/openclaw-helm/values-dev.yaml` with your group IDs
2. Commit and push changes (triggers ArgoCD sync):
   ```bash
   git add charts/openclaw-helm/values-dev.yaml
   git commit -m "secure telegram configuration for public groups"
   git push
   ```

3. Or manually apply:
   ```bash
   kubectl rollout restart deployment openclaw-helm
   ```

---

## Step 4: Verify Security

### Test Whitelist

1. **In whitelisted group:** Bot should respond
2. **In non-whitelisted group:** Bot should ignore messages
3. **Try config command:** Should be rejected if `configWrites: false`

### Check Logs

```bash
kubectl logs -l app.kubernetes.io/name=openclaw-helm --tail=100 -f
```

Look for:
- `[telegram] Group -100XXXXXXXXXX is whitelisted`
- `[telegram] Group -100YYYYYYYYYY not in whitelist, ignoring`
- `[telegram] Config write rejected`

---

## Security Checklist

- [ ] Group IDs collected
- [ ] `groupPolicy: "whitelist"` set
- [ ] `groupAllowFrom` populated with trusted IDs
- [ ] `configWrites: false` set
- [ ] Configuration applied to both local and K8s
- [ ] Tested in whitelisted group (works)
- [ ] Tested in non-whitelisted group (ignored)
- [ ] SECURITY.md reviewed
- [ ] AGENTS.md security section read

---

## Emergency: Disable All Groups

If something goes wrong:

```json
"telegram": {
  "enabled": true,
  "groupPolicy": "deny",     // ← Blocks ALL groups
  "dmPolicy": "pairing"      // ← DMs still work
}
```

Or completely disable Telegram:

```json
"telegram": {
  "enabled": false
}
```

---

## Monitoring

### Red Flags in Logs

- Repeated failed auth attempts
- Unknown group IDs trying to access
- Config write attempts from public groups
- Suspicious commands (file reads, credential access)

### Audit Commands

```bash
# Check active Telegram sessions
kubectl exec -it deploy/openclaw-helm -- cat /home/node/.openclaw/workspace/.openclaw/workspace-state.json

# Monitor real-time
kubectl logs -l app.kubernetes.io/name=openclaw-helm -f | grep -i telegram
```

---

## Notes

- Whitelist mode is **required** for public groups
- DM pairing is separate from group access
- Bot can be in multiple groups but only respond to whitelisted ones
- `configWrites: false` prevents remote config tampering
- Restart required after config changes

---

**Last updated:** 2026-03-03
**Priority:** CRITICAL - Apply before using in public groups
