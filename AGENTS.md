# Security CI Pipeline — Agent Guide

How this pipeline was built, why each piece exists, and how to replicate it.

---

## What This Pipeline Does

Every time code is pushed (or a PR is opened), this workflow runs five free security scanners, produces a report, creates GitHub Issues for each finding, and optionally sends a Teams alert. It never blocks deployment.

```
push/PR → Security Scan workflow → five scanners → HTML/MD report
                                                  → GitHub Issues (per finding)
                                                  → Teams Adaptive Card (Critical/High only)
```

---

## The Five Scanners

| Scanner | What it finds | Severity range | Config file |
|---------|--------------|----------------|-------------|
| **Semgrep** | SAST (bad code patterns, injection, auth flaws) | ERROR, WARNING | `.semgrep/custom/` |
| **Gitleaks** | Hardcoded secrets, API keys, passwords | N/A (binary) | `.gitleaks.toml` (optional) |
| **Trivy (fs)** | Dependency CVEs, Dockerfile misconfig | LOW–CRITICAL | auto-detects |
| **Trivy (image)** | Container image vulns (OS + runtime) | ALL | auto-detects |
| **Checkov** | IaC misconfig (Actions, Terraform, K8s) | ALL (resolved) | auto-detects |

**Why these five:**
- All free, no login required (Semgrep Pro is optional via token).
- They cover different layers: code (Semgrep), secrets (Gitleaks), dependencies (Trivy fs), container (Trivy image), infrastructure (Checkov).
- No overlap in scan targets (we skip our own artifacts so scanners never flag each other).

---

## Workflow Structure (Step by Step)

### 1. Checkout + Python setup
```yaml
- uses: actions/checkout@v4
- uses: actions/setup-python@v5
```
Python is needed for Semgrep, Checkov, and the report generator.

### 2. Semgrep (SAST)
```yaml
env:
  SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}
```
- If `SEMGREP_APP_TOKEN` secret is set → runs with **Semgrep Pro** rules (deeper).
- If missing or fails → falls back to **OSS packs** + `.semgrep/custom/`.
- Records the mode in `semgrep-mode.txt` so the report states what ran.
- Always includes `.semgrep/custom/` rules (project-specific).

### 3. Gitleaks (secrets)
```bash
if [ -f .gitleaks.toml ]; then
  ./gitleaks dir --config .gitleaks.toml ...
else
  ./gitleaks dir ...   # defaults only
fi
```
- Downloads pinned binary (v8.30.1), verifies SHA256 checksum.
- `.gitleaks.toml` is optional — extends defaults with allowlists.

### 4. Trivy (dependencies)
```bash
./trivy fs \
  --scanners vuln,misconfig \
  --severity LOW,CRITICAL \
  --ignore-unfixed \
  --skip-files gitleaks.json --skip-files semgrep.json ...
```
- `--ignore-unfixed`: only reports CVEs with a fix available (less noise).
- `--skip-files`/`--skip-dirs`: skips our own report artifacts and large folders.
- For .NET repos: `dotnet restore` runs first so Trivy can read `obj/project.assets.json`.

### 5. Trivy (container image)
```yaml
if: hashFiles('**/Dockerfile*') != ''
```
- Auto-detects any `Dockerfile` in the repo.
- Builds the image, then scans it.
- Skipped when no Dockerfile exists.

### 6. Checkov (IaC)
```bash
checkov --directory . --skip-path gitleaks.json --skip-path semgrep.json ... || true
```
- `|| true`: checkov exits non-zero when findings exist (its normal behavior).
- `--skip-path` for all our artifacts so scanners never flag each other.

### 7. Report Generator (Python heredoc)
The Python block:
- Parses all five JSON outputs into a uniform finding model.
- Computes the security score (0–100, Veracode-style).
- Generates `security-report.html` (searchable, filterable) and `security-report.md`.
- Emits `alert.json` for the Teams step and `counts.json` for the Issues step.

### 8. Upload Artifacts
```yaml
- uses: actions/upload-artifact@v4
  with:
    name: security-scan-report
    path: |
      security-report.html
      security-report.md
      semgrep.json gitleaks.json trivy.json trivy-image.json checkov.json
```
All raw JSON + reports are preserved for 30 days.

### 9. Teams Notification (optional)
Sends an Adaptive Card when Critical + High > 0 (see Power Automate section below).

### 10. GitHub Issues (default branch only)
- One issue per finding, labelled `security-scan`, `critical`/`high`/`medium`/`low`.
- Auto-closed when the finding is fixed.
- Human-closed issues never reopen (wontfix/false-positive escape hatch).
- Bot-closed issues reopen if the finding regresses.

### 11. PR Summary Comment
Posts a compact summary table + badge on every PR with findings.

---

## Power Automate + Teams Webhook (Post Alert)

### What is Power Automate?
Power Automate (Microsoft) is a no-code workflow tool. We use it to create a **webhook endpoint** that posts messages to a Teams channel.

### Why use Power Automate instead of a direct webhook?
Teams doesn't have a native incoming webhook for Adaptive Cards. Power Automate acts as the middleman:
```
GitHub Actions → HTTP POST to Power Automate → Adaptive Card appears in Teams
```

### How to set it up (step by step)

#### Step 1: Create a Power Automate flow
1. Go to [make.powerautomate.com](https://make.powerautomate.com).
2. Click **+ Create** → **Automated cloud flow**.
3. Name it something like `Teams Security Alert`.
4. Search for trigger: **When a Teams webhook request is received**.
5. Select it and click **Create**.

#### Step 2: Add the "Post card in a chat or channel" action
1. Click **+ New step**.
2. Search for: **Post card in a chat or channel** (Teams connector).
3. Select it and configure:
   - **Post as**: Flow bot
   - **Post in**: Channel
   - **Team**: Your team
   - **Channel**: Your channel
4. Click **Adaptive Card** and paste the JSON body from the `teams-card.json` template (or the template built into the workflow).

#### Step 3: Save and get the webhook URL
1. Click **Save**.
2. At the top, click **When a Teams webhook request is received** trigger.
3. Copy the **HTTP POST URL** — it looks like:
   ```
   https://default3ceb64fb1f1248e59eba7a0fbcc53c.41.environment.api.powerplatform.com:443/powerautomate/automations/direct/cu/13/workflows/80c29aefecdf4c5eaf50b03e3b0fb5c7/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=...
   ```

#### Step 4: Set the webhook to "Anyone"
1. In the trigger, set **Who can use this flow** to **Anyone** (not "Any user in my tenant").
2. This lets GitHub Actions (external) call it without authentication.

#### Step 5: Add the secret to GitHub
```bash
# In the repo's GitHub Settings → Secrets and variables → Actions → New repository secret
# Name: TEAMS_WEBHOOK_URL
# Value: <the HTTP POST URL from step 3>
```

### What the workflow sends
The workflow builds an Adaptive Card JSON and POSTs it:

```json
{
  "type": "message",
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": {
      "type": "AdaptiveCard",
      "body": [
        { "type": "TextBlock", "text": "Security Scan: vuln-bank — F (0/100)", "weight": "bolder", "size": "large" },
        { "type": "TextBlock", "text": "Summary: 1 Critical, 2 High, 3 Medium", "wrap": true },
        { "type": "FactSet", "facts": [
          { "title": "Critical", "value": "1" },
          { "title": "High", "value": "2" }
        ]},
        { "type": "TextBlock", "text": "**Top findings:**\n- app.py:45 — SQL injection\n- config.py:12 — Hardcoded API key", "wrap": true }
      ],
      "actions": [{ "type": "Action.OpenUrl", "title": "View Report", "url": "..." }]
    }
  }]
}
```

### When does it alert?
- **Critical + High > 0** → sends the card.
- **No Critical or High** → skips silently (no notification noise).
- **No TEAMS_WEBHOOK_URL secret** → skips silently.

---

## Testing Locally with `act`

[act](https://github.com/nektos/act) runs GitHub Actions workflows locally in Docker.

### Install act
```bash
# Linux
curl -fsSL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b /usr/local/bin

# Or download binary directly
wget -q https://github.com/nektos/act/releases/latest/download/act_Linux_x86_64.tar.gz
tar -xzf act_Linux_x86_64.tar.gz -C /usr/local/bin act
```

### Run the workflow locally
```bash
cd vuln-bank

# Run the full workflow
act push

# With a test secret (e.g. Teams webhook to a local listener)
echo "TEAMS_WEBHOOK_URL=http://localhost:9999/hook" > /tmp/.secrets
act push --secret-file /tmp/.secrets

# Use a smaller image to save time
act push -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

### Test the Teams webhook with a local listener
```bash
# Start a simple HTTP listener to capture the payload
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        print('=== PAYLOAD RECEIVED ===')
        print(body.decode())
        print('========================')
        self.send_response(202)
        self.end_headers()
HTTPServer(('0.0.0.0', 9999), H).serve_forever()
" &

# Point act to the local listener
echo "TEAMS_WEBHOOK_URL=http://172.17.0.1:9999/hook" > /tmp/.secrets
act push --secret-file /tmp/.secrets
```

The Python script prints the Adaptive Card payload if the workflow sends it.

---

## Adding This Pipeline to a New Repo

1. **Copy the workflow file:**
   ```bash
   mkdir -p new-repo/.github/workflows
   cp .github/workflows/security-scan.yml new-repo/.github/workflows/
   ```

2. **Push it.** The workflow auto-detects everything — no repo-specific edits needed.

3. **Optional: tune noise.**
   - Create `.semgrepignore` in the repo root to ignore test files.
   - Create `.gitleaks.toml` to allowlist known test fixtures:
     ```toml
     [extend]
     useDefault = true
     [allowlist]
       description = "Test fixtures"
       paths = [
         '''test[_-]data''',
         '''cafebabe:deadbeef''',
       ]
     ```

4. **Optional: enable Teams alerts.**
   - Follow the Power Automate steps above.
   - Add `TEAMS_WEBHOOK_URL` as a repo secret.

5. **Optional: enable Semgrep Pro.**
   - Sign up at [semgrep.dev](https://semgrep.dev) (free tier).
   - Add `SEMGREP_APP_TOKEN` as a repo secret.

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| Semgrep shows "oss-fallback" | Pro token invalid or rate-limited | Check `SEMGREP_APP_TOKEN` is valid |
| Gitleaks finds test keys | No `.gitleaks.toml` allowlist | Add `.gitleaks.toml` with `useDefault = true` + allowlist |
| Checkov step looks "failed" | `|| true` was removed | Re-add `|| true` to the checkov command |
| Trivy "NO OUTPUT" | Binary download failed | Check network; increase `--max-time` in curl |
| Teams card not posting | Secret missing or wrong URL | Verify `TEAMS_WEBHOOK_URL` in repo secrets; check Power Automate flow is active |
| Issues not created | Workflow runs on a PR branch | Issues sync only runs on default branch |
| act fails with "unexpected client error" | Docker can't reach GitHub | Use `catthehacker/ubuntu:act-latest` image (pre-cached); ensure Docker has network access |

---

## Key Design Decisions

| Decision | Why |
|----------|-----|
| Never fail the build | Security findings are informational; blocking deployment on false positives is worse than shipping them |
| `continue-on-error: true` on every step | Even if a scanner crashes, the rest still runs |
| Skip own artifacts from scanners | Prevents scanners from flagging each other's output (gitleaks.json triggers CKV_SECRET_6, etc.) |
| LOW excluded from report, included in score | Keeps the report actionable; score is still accurate |
| Score penalizes severity not count | 1 critical (−8) hurts more than 8 lows (−4) — reflects real risk |
| Issues auto-close on fix | No manual cleanup; finding is gone → issue is gone |
| Human-closed issues stay closed | False positives/wontfix can be dismissed permanently |
| Teams alerts only on Critical/High | No notification noise for low-severity findings |
| Pinned tool versions | Reproducible scans; no surprise breakage from upstream changes |

---

## File Reference

```
vuln-bank/
├── .github/workflows/
│   └── security-scan.yml    # The pipeline (this is the only file that matters)
├── .gitleaks.toml           # Optional: allowlist for test fixture secrets
├── .semgrepignore           # Optional: ignore test files from Semgrep
├── .semgrep/custom/         # Optional: project-specific Semgrep rules
└── AGENTS.md                # This file
```
