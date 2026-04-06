# GCP API Key Audit Script

Bash script that scans all projects in a GCP organisation to find unrestricted API keys and keys with access to Generative AI APIs.

## Script Logic

The script runs in 4 stages:

### Stage 1 — Discover Projects

Lists all GCP projects visible to the authenticated user via `gcloud projects list`.

### Stage 2 — Identify AI-Enabled Projects

For each project, checks which APIs are enabled and filters for:

- `generativelanguage.googleapis.com` (Gemini API)
- `aiplatform.googleapis.com` (Vertex AI)

Also checks whether `apikeys.googleapis.com` is enabled on each project. This determines whether API key inspection results can be trusted (see [Trust Tags](#trust-tags) below).

### Stage 3 — Audit API Keys in AI-Enabled Projects

For each project from Stage 2, lists all API keys and inspects their restrictions:

- **3a** — Identifies keys with no API restrictions (unrestricted keys that can call any enabled API)
- **3b** — Identifies keys explicitly allowing `generativelanguage.googleapis.com` or `aiplatform.googleapis.com`

### Stage 4 — Audit API Keys in Remaining Projects

Scans all other projects (where AI APIs are not enabled) for unrestricted API keys.

### Summary

Consolidated report showing:

- Total projects scanned and categorised
- All unrestricted API keys (from both Stage 3 and Stage 4)
- Keys with AI API access
- Projects requiring manual review

### Trust Tags

The `gcloud api-keys list` command requires `apikeys.googleapis.com` to be enabled on a project to return results. Projects without this API enabled are tagged:

- **[TRUSTED]** — `apikeys.googleapis.com` is enabled; results are complete
- **[NEEDS MANUAL REVIEW]** — `apikeys.googleapis.com` is not enabled; API keys may exist but are not visible to gcloud. Review these projects manually in GCP Console under **APIs & Services > Credentials**

## Requirements

### Tools

- `gcloud` CLI (authenticated)
- `python3` (used for JSON parsing)
- `bash` 3.2+ (macOS default is supported)
