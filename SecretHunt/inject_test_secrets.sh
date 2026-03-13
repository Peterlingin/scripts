#!/usr/bin/env bash
# =============================================================================
# inject_test_secrets.sh — Inject fake secrets into shell history for testing
#
# Usage:
#   ./inject_test_secrets.sh [bash|zsh|fish]
#
# If no shell is specified, the current shell history file is used.
# All entries are clearly marked as FAKE/TEST and are not real credentials.
# =============================================================================

# ── Target history file ───────────────────────────────────────────────────────
case "${1:-}" in
  bash) HIST_FILE="$HOME/.bash_history" ;;
  zsh)  HIST_FILE="$HOME/.zsh_history" ;;
  fish) HIST_FILE="$HOME/.local/share/fish/fish_history" ;;
  "")
    case "$SHELL" in
      */zsh)  HIST_FILE="$HOME/.zsh_history" ;;
      */fish) HIST_FILE="$HOME/.local/share/fish/fish_history" ;;
      *)      HIST_FILE="$HOME/.bash_history" ;;
    esac
    ;;
  *) echo "Usage: $0 [bash|zsh|fish]"; exit 1 ;;
esac

echo "Injecting test entries into: $HIST_FILE"
echo ""

# ── Helper: append a line and print confirmation ──────────────────────────────
inject() {
  local label="$1"
  local entry="$2"
  echo "$entry" >> "$HIST_FILE"
  printf "  %-30s → injected\n" "$label"
}

# ── HIGH severity ─────────────────────────────────────────────────────────────
echo "[ HIGH ]"
inject "AWS Access Key ID"        "aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE"
inject "AWS Secret Access Key"    "export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
inject "GitHub Token"             "git clone https://github.com/org/repo GITHUB_TOKEN=ghp_A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8"
inject "Stripe Secret Key"        "curl https://api.stripe.com/v1/charges -u sk_live_4eC39HqLyjWDarjtT1zdp7dc:"
inject "Slack Token"              "curl -H 'Authorization: Bearer xoxb-123456789012-123456789012-ABCDEFGHIJKLMNOP' https://slack.com/api/auth.test"
inject "Google API Key"           "curl 'https://maps.googleapis.com/maps/api/geocode/json?address=Rome&key=AIzaSyD-9tSrke72skgW1234567890abcdefghij'"
inject "JWT Token"                "curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyQGV4YW1wbGUuY29tIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c' https://api.example.com/profile"
inject "DB Connection String"     "psql postgres://admin:S3cr3tPassw0rd!@db.example.com:5432/production"
inject "Basic Auth in URL"        "curl https://john.doe:SuperSecret123@api.example.com/private/data"
inject "Private Key Header"       "echo '-----BEGIN RSA PRIVATE KEY----- MIIEowIBAAKCAQEA...'"
inject "SendGrid API Key"         "export SENDGRID_KEY=SG.abcdefghijklmnopqrstuv.ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcdefghijk"
inject "npm Auth Token"           "echo '//registry.npmjs.org/:_authToken=npm_A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6' >> ~/.npmrc"

echo ""

# ── MEDIUM severity ───────────────────────────────────────────────────────────
echo "[ MEDIUM ]"
inject "Generic API Key"          "curl -H 'X-Api-Key: api_key=abcdef1234567890ABCDEF12' https://api.example.com/data"
inject "Generic Secret"           "export client_secret=xK9mP2qR7nT4vL8"
inject "Generic Token"            "curl -d 'access_token=eyABC123DEF456GHI789JKL012' https://api.example.com"
inject "Generic Password"         "mysqldump -u root --password=Tr0ub4dor&3 mydb > backup.sql"
inject "SSH Identity File"        "ssh -i ~/.ssh/production_rsa.pem ubuntu@203.0.113.42"
inject "curl with Credentials"    "curl -u john.doe:MyP@ssw0rd123 https://internal.example.com/api"

echo ""

# ── LOW severity ──────────────────────────────────────────────────────────────
echo "[ LOW ]"
inject "Exported Credential"      "export API_KEY=my-super-secret-api-key-here"
inject "Env Var Assignment"       "SECRET_KEY=django-insecure-abc123xyz789 python manage.py runserver"
inject "DB Password Env"          "DB_PASSWORD=Letmein123 rails db:migrate"
inject "sshpass"                  "sshpass -p 'R00tP@ssword!' ssh root@192.168.1.100"
inject "scp with Key"             "scp -i ~/.ssh/deploy.pem ./dist/* ubuntu@203.0.113.10:/var/www/html"

echo ""
echo "Done. Total test entries injected: 23"
echo ""
echo "Now run:  ./secrethunt.sh"
echo "Or:       ./secrethunt.sh -s high    (high severity only)"
echo "Or:       ./secrethunt.sh -o report.csv"
