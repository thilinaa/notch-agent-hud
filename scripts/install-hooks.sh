#!/bin/bash
# Install NotchHUD's Claude Code hooks from the command line.
#
# The app does the same thing from Settings → Advanced (or during first-run
# setup); this script exists for people who prefer a terminal, for dotfile
# setups, and for CI. It writes the relay script to ~/.notchhud/notify.sh and
# adds it to five hooks in ~/.claude/settings.json, keeping a timestamped
# backup of that file. Nothing else in settings.json is touched.
#
# Requires: macOS only (plutil + JavaScript for Automation), no Python.
set -euo pipefail

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
PORT="${NOTCHHUD_PORT:-48618}"
RELAY="$HOME/.notchhud/notify.sh"
EVENTS=(SessionStart UserPromptSubmit Notification Stop SessionEnd)

mkdir -p "$HOME/.notchhud"

# Relay: tags the hook payload with the host app (from __CFBundleIdentifier),
# the claude pid, and the active login, then POSTs it to the HUD.
cat > "$RELAY" <<EOF
#!/bin/sh
HOST="\${__CFBundleIdentifier:-}"
# Active Claude account (respects CLAUDE_CONFIG_DIR overrides).
CFG="\${CLAUDE_CONFIG_DIR:-\$HOME}/.claude.json"
ACC=\$(plutil -extract oauthAccount.emailAddress raw -o - "\$CFG" 2>/dev/null)
# Find the claude process in our ancestry for liveness checks.
PID=\$PPID
CLPID=0
i=0
while [ \$i -lt 5 ] && [ "\$PID" -gt 1 ] 2>/dev/null; do
  NAME=\$(ps -o comm= -p "\$PID" 2>/dev/null)
  case "\$NAME" in *claude*) CLPID=\$PID; break;; esac
  PID=\$(ps -o ppid= -p "\$PID" 2>/dev/null | tr -d ' ')
  [ -z "\$PID" ] && break
  i=\$((i+1))
done
sed "s/^{/{\\"_host\\":\\"\$HOST\\",\\"_pid\\":\$CLPID,\\"_account\\":\\"\$ACC\\",/" | curl -s -m 2 -X POST -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$PORT/event" >/dev/null 2>&1
exit 0
EOF
chmod +x "$RELAY"
echo "Wrote $RELAY"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
else
  mkdir -p "$(dirname "$SETTINGS")"
  echo '{}' > "$SETTINGS"
fi

# Merge with JavaScript for Automation (built into macOS): drop stale NotchHUD
# entries, append one relay entry per event, leave everything else untouched.
osascript -l JavaScript - "$SETTINGS" "$RELAY" "${EVENTS[@]}" <<'JXA'
function run(argv) {
  ObjC.import('Foundation');
  const [path, relay, ...events] = argv;
  const raw = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError($(path), $.NSUTF8StringEncoding, null));
  let settings;
  try { settings = JSON.parse(raw); } catch (e) {
    throw new Error(path + ' is not valid JSON; fix it first so nothing is lost.');
  }
  const isRelay = entry => (entry.hooks || []).some(h => {
    const c = String(h.command || '');
    return c === relay || c.toLowerCase().includes('notchhud');
  });
  settings.hooks = settings.hooks || {};
  for (const event of events) {
    const kept = (settings.hooks[event] || []).filter(e => !isRelay(e));
    kept.push({ hooks: [{ type: 'command', command: relay }] });
    settings.hooks[event] = kept;
  }
  const out = JSON.stringify(settings, null, 2) + '\n';
  $(out).writeToFileAtomicallyEncodingError($(path), true, $.NSUTF8StringEncoding, null);
  return 'Hooks installed for: ' + events.join(', ');
}
JXA
echo "New Claude Code sessions will now report to NotchHUD. Existing sessions pick hooks up on restart."
