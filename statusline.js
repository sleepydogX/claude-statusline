#!/usr/bin/env node
// Claude Code Statusline — Enhanced Dashboard
// A rich, informative status bar for Claude Code sessions.
// https://github.com/sleepydogX/claude-statusline

const fs = require('fs');
const path = require('path');
const os = require('os');

// Strip ASCII control characters (and DEL) from a value before it is rendered.
// Used for every row-3 field sourced from the payload, a cache file, or a
// subprocess's output (gh/supabase/git) — none of which are trusted to be
// free of escape sequences.
// C1 is included because some terminals treat \x9b as a one-byte CSI; bidi and
// format characters are included because they can visually reorder the row.
const CONTROL_RE = /[\x00-\x1f\x7f-\x9f‎‏‪-‮⁦-⁩]/g;
function stripControl(s) {
  return String(s).replace(CONTROL_RE, '');
}

// Wrap text in an OSC 8 hyperlink. Only http(s) URLs free of control characters
// are linked. On every exit path, text is coerced to a string and stripped of
// the same control characters before it is returned, so neither the URL nor
// the visible text can inject escape sequences into the row.
// Terminals without OSC 8 support ignore the sequence and show the text.
function osc8(url, text) {
  const safeText = stripControl(text);
  if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return safeText;
  if (stripControl(url) !== url) return safeText;
  return `\x1b]8;;${url}\x07${safeText}\x1b]8;;\x07`;
}

// tmpdir may be a shared /tmp. Both helpers refuse a symlink (O_NOFOLLOW), a
// FIFO (O_NONBLOCK, then the isFile check), a hardlink, or a file another user
// owns, so a planted path can neither be written through nor feed us content.
// Truncation happens only after those checks, never via O_TRUNC at open.
const OWN_UID = typeof process.getuid === 'function' ? process.getuid() : null;
function ownedRegular(st) {
  return st.isFile() && st.nlink === 1 && (OWN_UID === null || st.uid === OWN_UID);
}
function readTmpFile(p) {
  const { O_RDONLY, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
  const fd = fs.openSync(p, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  try {
    if (!ownedRegular(fs.fstatSync(fd))) throw new Error('untrusted tmp file');
    return fs.readFileSync(fd, 'utf8');
  } finally {
    fs.closeSync(fd);
  }
}
function writeTmpFile(p, content) {
  const { O_WRONLY, O_CREAT, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
  const fd = fs.openSync(p, O_WRONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600);
  try {
    if (!ownedRegular(fs.fstatSync(fd))) throw new Error('untrusted tmp file');
    fs.ftruncateSync(fd, 0);
    fs.writeSync(fd, content, 0);
  } finally {
    fs.closeSync(fd);
  }
}

// Resolve the git directory for startDir, walking up at most MAX_GIT_WALKUP
// levels. A .git FILE rather than a directory means a worktree or submodule; it
// holds a "gitdir: <path>" pointer, which may be relative to the file's own
// directory. Returns '' when nothing is found.
const MAX_GIT_WALKUP = 10;
function resolveGitDir(startDir) {
  let dir = startDir;
  for (let i = 0; i < MAX_GIT_WALKUP; i++) {
    const candidate = path.join(dir, '.git');
    try {
      const stat = fs.statSync(candidate);
      if (stat.isDirectory()) return candidate;
      if (stat.isFile()) {
        const pointer = fs.readFileSync(candidate, 'utf8').match(/gitdir:\s*(.+)/);
        if (!pointer) return '';
        const target = pointer[1].trim();
        return path.isAbsolute(target) ? target : path.resolve(dir, target);
      }
    } catch (e) { /* not here; keep walking */ }
    const parent = path.dirname(dir);
    if (parent === dir) break;  // filesystem root
    dir = parent;
  }
  return '';
}

// Read the current branch from HEAD. A "ref: refs/heads/NAME" line yields NAME;
// anything else is a detached HEAD, reported as a 7-character short SHA.
function readBranch(startDir) {
  try {
    const gitDir = resolveGitDir(startDir);
    if (!gitDir) return '';
    const head = fs.readFileSync(path.join(gitDir, 'HEAD'), 'utf8').trim();
    const ref = head.match(/^ref:\s*refs\/heads\/(.+)$/);
    if (ref) {
      const name = ref[1].trim();
      const safe = stripControl(name);
      return safe === name ? safe : '';
    }
    if (/^[0-9a-f]{7,40}$/i.test(head)) return head.slice(0, 7);
    return '';
  } catch (e) {
    return '';
  }
}

// ── Module toggles (set by install script) ──
const MODULES = {
  session_name: true,    // Session slug display
  cost: true,            // Projected cost in USD
  duration: true,        // Session duration
  rate_limits: true,     // 5-hour and 7-day usage limits
  lines_changed: true,   // Lines added/removed this session
  github: true,          // GitHub repo, branch, account
  supabase: true,        // Supabase linked project
  context_bridge: true,  // Write context metrics for other hooks
  effort: true,          // Reasoning effort level
  output_style: true,    // Active output style (added in T3)
  fast_mode: true,       // Fast mode indicator (added in T5)
  pr: true,              // Open pull request for the current branch
  subagents: true,       // Running subagents and their context usage
  prompt_cache: true,    // Prompt cache time-to-expiry and hit ratio
};

// Load user overrides from config file if present
const configPath = path.join(os.homedir(), '.claude', 'statusline-config.json');
if (fs.existsSync(configPath)) {
  try {
    const userConfig = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    Object.assign(MODULES, userConfig);
  } catch (e) {}
}

// Read JSON from stdin
let input = '';
const stdinTimeout = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => input += chunk);
process.stdin.on('end', () => {
  clearTimeout(stdinTimeout);
  try {
    const data = JSON.parse(input);
    const model = data.model?.display_name || 'Claude';
    const dir = data.workspace?.current_dir || process.cwd();
    const session = data.session_id || '';
    const remaining = data.context_window?.remaining_percentage;

    // ── Context window ──
    // Autocompact reserves a fixed token buffer, not a fixed share of the
    // window: 33k is 16.5% of 200k but only 3.3% of 1M.
    const AUTO_COMPACT_BUFFER_TOKENS = 33000;
    const windowSize = Number(data.context_window?.context_window_size) > 0
      ? Number(data.context_window.context_window_size)
      : 200000;
    const AUTO_COMPACT_BUFFER_PCT = Math.min(50, AUTO_COMPACT_BUFFER_TOKENS / windowSize * 100);
    const usedPct = remaining == null ? null : (() => {
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      return Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));
    })();

    // Write context metrics bridge file (for context-monitor hooks)
    if (MODULES.context_bridge && remaining != null) {
      const used = usedPct;
      const sessionSafe = session && !/[/\\]|\.\./.test(session);
      if (sessionSafe) {
        try {
          const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
          writeTmpFile(bridgePath, JSON.stringify({
            session_id: session, remaining_percentage: remaining,
            used_pct: used, timestamp: Math.floor(Date.now() / 1000)
          }));
        } catch (e) {}
      }
    }

    // ── User settings (effortLevel, fastMode) ──
    let userSettings = {};
    try {
      const settingsPath = path.join(os.homedir(), '.claude', 'settings.json');
      if (fs.existsSync(settingsPath)) {
        userSettings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
      }
    } catch (e) { /* silent; treat as empty */ }

    // ── Effort ──
    // Primary source is the payload's effort.level: it is the live session value
    // and reflects mid-session /effort changes. It is absent when the model does
    // not support the effort parameter, and on Claude Code builds that predate the
    // field — in both cases we fall back to the settings.json / env reading below.
    let effortPart = '';
    if (MODULES.effort) {
      try {
        const validLevels = new Set(['low', 'medium', 'high', 'xhigh', 'max']);
        const payloadRaw = typeof data.effort?.level === 'string' ? data.effort.level : '';
        // Accept unknown-but-sane levels so a newly added level still renders.
        const payloadVal = payloadRaw.toLowerCase().replace(/[^a-z]/g, '').slice(0, 8);
        const envRaw = process.env.CLAUDE_CODE_EFFORT_LEVEL;
        const envVal = envRaw ? envRaw.toLowerCase() : '';
        const envOverrides = envVal && envVal !== 'auto' && envVal !== 'unset';
        const settingsVal = typeof userSettings.effortLevel === 'string'
          ? userSettings.effortLevel.toLowerCase()
          : '';

        let display;
        let isOverride;
        let invalid = false;

        if (payloadVal) {
          // The payload already reports the effective level, so no override marker.
          display = payloadVal;
          isOverride = false;
        } else if (envOverrides) {
          if (validLevels.has(envVal)) {
            display = envVal;
            isOverride = true;
          } else {
            invalid = true;
          }
        } else if (settingsVal) {
          if (validLevels.has(settingsVal)) {
            display = settingsVal;
            isOverride = false;
          } else {
            invalid = true;
          }
        } else {
          display = 'auto';
          isOverride = false;
        }

        if (invalid) {
          effortPart = `\x1b[2m\u{1F9E0} ?\x1b[0m`;
        } else {
          // Null prototype so a level named after an Object.prototype member
          // cannot resolve to an inherited value, which would be truthy and
          // skip the `||` default, interpolating `undefined` into the row.
          const colorMap = Object.assign(Object.create(null), {
            auto:   '\x1b[3m',
            low:    '\x1b[38;5;245m',
            medium: '\x1b[32m',
            high:   '\x1b[33m',
            xhigh:  '\x1b[38;5;208m',
            max:    '\x1b[1;35m',
          });
          const color = colorMap[display] || '\x1b[0m';
          const label = display === 'auto' ? 'auto' : display.toUpperCase();
          const marker = isOverride ? '*' : '';
          effortPart = `${color}\u{1F9E0} ${label}${marker}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── Output style ──
    let outputStylePart = '';
    if (MODULES.output_style) {
      try {
        const raw = data.output_style;
        let name = '';
        if (typeof raw === 'string') {
          name = raw;
        } else if (raw && typeof raw === 'object' && typeof raw.name === 'string') {
          name = raw.name;
        }
        if (name && name !== 'default') {
          outputStylePart = `\x1b[36m\u{1F4DD} style: ${name}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── Fast mode ──
    let fastModePart = '';
    if (MODULES.fast_mode) {
      try {
        // fast_mode is the live session flag toggled by /fast. settings.json only
        // holds the startup default, so it is a fallback for builds omitting it.
        const enabled = typeof data.fast_mode === 'boolean'
          ? data.fast_mode
          : userSettings.fastMode === true;
        if (enabled) {
          fastModePart = `\x1b[1;96m\u26A1 FAST\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── Stale cache cleanup ──
    // Per-session files below accumulate in tmpdir forever. Sweep those older
    // than a week, at most once a day, gated by a marker file's mtime.
    try {
      const tmp = os.tmpdir();
      const marker = path.join(tmp, 'claude-statusline-gc');
      const DAY_MS = 86400000;
      let lastRun = 0;
      try { lastRun = fs.lstatSync(marker).mtimeMs; } catch (e) {}
      if (Date.now() - lastRun > DAY_MS) {
        // tmpdir may be a shared /tmp: O_NOFOLLOW refuses a planted symlink
        // (throwing, which skips the sweep), and bumping mtime instead of
        // writing means nothing is ever truncated.
        const { O_WRONLY, O_CREAT, O_NOFOLLOW } = fs.constants;
        const fd = fs.openSync(marker, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600);
        try {
          const now = new Date();
          fs.futimesSync(fd, now, now);
        } finally {
          fs.closeSync(fd);
        }
        const cutoff = Date.now() - 7 * DAY_MS;
        for (const f of fs.readdirSync(tmp)) {
          if (!/^claude-(info-.+\.json|ctx-.+\.json|slug-.+)$/.test(f)) continue;
          try {
            const p = path.join(tmp, f);
            const st = fs.lstatSync(p);
            if (st.isFile() && st.mtimeMs < cutoff) fs.unlinkSync(p);
          } catch (e) {}
        }
      }
    } catch (e) { /* silent */ }

    // ── Session name ──
    // Prefer the native session_name field (a /rename or --name value, otherwise
    // the AI-generated title). It is absent when the session has neither, so keep
    // scraping the transcript slug as a fallback.
    let sessionNamePart = '';
    const MAX_SESSION_NAME = 40;
    const renderSessionName = (text) => {
      const clean = text.replace(/\s+/g, ' ').trim();
      if (!clean) return '';
      const shown = clean.length > MAX_SESSION_NAME
        ? clean.slice(0, MAX_SESSION_NAME - 1) + '…'
        : clean;
      return `\x1b[1;38;5;213m\u{1F516} ${shown}\x1b[0m`;
    };
    if (MODULES.session_name && typeof data.session_name === 'string') {
      sessionNamePart = renderSessionName(data.session_name);
    }
    if (MODULES.session_name && !sessionNamePart) {
      const transcriptPath = data.transcript_path;
      if (transcriptPath && fs.existsSync(transcriptPath)) {
        try {
          const sessionSafe = session && !/[/\\]|\.\./.test(session);
          const slugCachePath = sessionSafe ? path.join(os.tmpdir(), `claude-slug-${session}`) : null;
          let slug = '';
          let cachedSlug = null;
          if (slugCachePath) {
            try { cachedSlug = readTmpFile(slugCachePath).trim(); } catch (e) { /* absent or untrusted */ }
          }
          if (cachedSlug) {
            slug = cachedSlug;
          } else {
            const stat = fs.statSync(transcriptPath);
            const readSize = Math.min(stat.size, 8192);
            const fd = fs.openSync(transcriptPath, 'r');
            const buf = Buffer.alloc(readSize);
            fs.readSync(fd, buf, 0, readSize, Math.max(0, stat.size - readSize));
            fs.closeSync(fd);
            const tail = buf.toString('utf8');
            const slugMatches = tail.match(/"slug"\s*:\s*"([^"]+)"/g);
            if (slugMatches && slugMatches.length > 0) {
              const lastMatch = slugMatches[slugMatches.length - 1].match(/"slug"\s*:\s*"([^"]+)"/);
              if (lastMatch) slug = lastMatch[1];
            }
            if (slug && slugCachePath) {
              try { writeTmpFile(slugCachePath, slug); } catch (e) {}
            }
          }
          if (slug) {
            const formatted = slug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
            sessionNamePart = renderSessionName(formatted);
          }
        } catch (e) {}
      }
    }

    // ── Session duration ──
    let durationPart = '';
    if (MODULES.duration) {
      const totalDurationMs = data.cost?.total_duration_ms;
      if (totalDurationMs != null && totalDurationMs > 0) {
        const elapsed = Math.floor(totalDurationMs / 1000);
        const h = Math.floor(elapsed / 3600);
        const m = Math.floor((elapsed % 3600) / 60);
        const s = elapsed % 60;
        const timeStr = h > 0 ? `${h}h${String(m).padStart(2,'0')}m` : `${m}m${String(s).padStart(2,'0')}s`;
        durationPart = `\x1b[1;35m\u231B ${timeStr}\x1b[0m`;
      }
    }

    // ── Estimated cost ──
    let costPart = '';
    if (MODULES.cost) {
      const totalCost = data.cost?.total_cost_usd;
      if (totalCost != null && totalCost > 0) {
        const costStr = totalCost < 0.01 ? '<$0.01' : `$${totalCost.toFixed(2)}`;
        // Under five minutes the hourly rate swings too much to mean anything.
        const hours = Number(data.cost?.total_duration_ms) / 3600000;
        let rateStr = '';
        if (hours >= 5 / 60) {
          const perHour = totalCost / hours;
          rateStr = ` \x1b[2m($${perHour >= 1 ? perHour.toFixed(1) : perHour.toFixed(2)}/h)\x1b[0m`;
        }
        costPart = `\x1b[1;33m\u{1F4B0} ${costStr}\x1b[0m${rateStr}`;
      }
    }

    // ── Prompt cache ──
    // Time left before the cached prefix expires (replying sooner reuses it at a
    // fraction of the price) and the session's hit ratio. expires_at is unix
    // seconds and hit_ratio is 0–1. Hidden until caching has been observed.
    let promptCachePart = '';
    if (MODULES.prompt_cache) {
      try {
        const pc = data.prompt_cache;
        if (pc && pc.caching_observed === true) {
          const ratio = Number(pc.hit_ratio);
          const hitStr = Number.isFinite(ratio) && ratio >= 0 && ratio <= 1
            ? ` \x1b[2m${Math.round(ratio * 100)}%\x1b[0m`
            : '';
          const leftMs = Number(pc.expires_at) * 1000 - Date.now();
          if (pc.warm === true && leftMs > 0) {
            const s = Math.floor(leftMs / 1000);
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            const text = h > 0 ? `${h}h${String(m).padStart(2, '0')}m` : m > 0 ? `${m}m` : `${s}s`;
            const color = s < 120 ? '\x1b[31m' : s < 600 ? '\x1b[33m' : '\x1b[36m';
            promptCachePart = `${color}\u{1F9CA} ${text}\x1b[0m${hitStr}`;
          } else {
            // Cold: the next message rewrites the whole prefix at full price.
            const tokens = Number(pc.recache_tokens_if_cold);
            const cost = tokens > 0
              ? ` \x1b[2m(${tokens >= 1000 ? Math.round(tokens / 1000) + 'k' : Math.round(tokens)} to rewrite)\x1b[0m`
              : '';
            promptCachePart = `\x1b[2;37m\u{1F9CA} cold\x1b[0m${cost}${hitStr}`;
          }
        }
      } catch (e) { /* silent */ }
    }

    // ── Rate limits ──
    let rateLimitPart = '';
    if (MODULES.rate_limits) {
      const fiveHour = data.rate_limits?.five_hour;
      const sevenDay = data.rate_limits?.seven_day;
      if (fiveHour || sevenDay) {
        const parts = [];
        const colorPct = (pct) => {
          if (pct < 50) return `\x1b[32m${pct}%\x1b[0m`;
          if (pct < 75) return `\x1b[33m${pct}%\x1b[0m`;
          if (pct < 90) return `\x1b[38;5;208m${pct}%\x1b[0m`;
          return `\x1b[5;31m${pct}%\x1b[0m`;
        };
        // The payload's percentage is only as fresh as the last API response,
        // so once resets_at has passed it describes a window that is gone.
        const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
        const windowState = (limit, windowMs) => {
          const rawPct = Number(limit.used_percentage) || 0;
          let pct = Math.round(rawPct);
          let resetStr = '';
          let paceStr = '';
          let etaStr = '';
          const resetsAt = Number(limit.resets_at);
          if (resetsAt > 0) {
            const diffMs = resetsAt * 1000 - Date.now();
            if (diffMs <= 0) {
              pct = 0;
            } else {
              const d = Math.floor(diffMs / 86400000);
              const h = Math.floor((diffMs % 86400000) / 3600000);
              const m = Math.floor((diffMs % 3600000) / 60000);
              const text = d > 0
                ? `${d}d${String(h).padStart(2,'0')}h`
                : `${h}h${String(m).padStart(2,'0')}m`;
              resetStr = ` \x1b[2m${text}\x1b[0m`;

              // Pace: usage against the share of the window already elapsed.
              // Early in a window one request moves the ratio wildly, so wait
              // for 5% of it to pass before judging.
              const elapsedMs = windowMs - diffMs;
              const elapsedFrac = elapsedMs / windowMs;
              if (elapsedFrac >= 0.05 && elapsedFrac <= 1) {
                const delta = Math.round(rawPct - elapsedFrac * 100);
                if (delta >= 1) {
                  const c = delta >= 15 ? '\x1b[31m' : '\x1b[33m';
                  paceStr = ` ${c}\u21E1${delta}%\x1b[0m`;
                } else if (delta <= -1) {
                  paceStr = ` \x1b[2;32m\u21E3${-delta}%\x1b[0m`;
                }
                // ETA: only when the current rate runs out before the reset.
                if (rawPct > 0 && rawPct < 100) {
                  const msToFull = (100 - rawPct) / (rawPct / elapsedMs);
                  if (msToFull < diffMs) {
                    const at = new Date(Date.now() + msToFull);
                    const hhmm = `${String(at.getHours()).padStart(2,'0')}:${String(at.getMinutes()).padStart(2,'0')}`;
                    const label = msToFull > 20 * 3600000 ? `${WEEKDAYS[at.getDay()]} ${hhmm}` : hhmm;
                    etaStr = ` \x1b[31m\u2192 limit ${label}\x1b[0m`;
                  }
                }
              }
            }
          }
          return `${colorPct(pct)}${paceStr}${resetStr}${etaStr}`;
        };
        if (fiveHour) parts.push(`\x1b[1;37m\u26A15h\x1b[0m ${windowState(fiveHour, 5 * 3600000)}`);
        if (sevenDay) parts.push(`\x1b[1;37m\u{1F4C5}7d\x1b[0m ${windowState(sevenDay, 7 * 86400000)}`);
        rateLimitPart = parts.join(' \x1b[2m\u2502\x1b[0m ');
      }
    }

    // ── Subagents ──
    // Not in the payload. Claude Code keeps each subagent's record beside the
    // transcript, in <transcript minus .jsonl>/subagents/: agent-<id>.meta.json
    // gains "finished": true when the agent ends, and agent-<id>.jsonl holds its
    // messages with per-response token usage. This layout is undocumented, so
    // every read here fails closed to an empty segment.
    let subagentPart = '';
    if (MODULES.subagents) {
      try {
        const tp = data.transcript_path;
        if (typeof tp === 'string' && tp.endsWith('.jsonl')) {
          const subDir = path.join(tp.slice(0, -'.jsonl'.length), 'subagents');
          // A killed agent never gets "finished", so one whose log has been
          // silent this long is treated as gone rather than shown forever.
          const STALE_MS = 15 * 60 * 1000;
          const TAIL_BYTES = 256 * 1024;
          const payloadWindow = data.context_window?.context_window_size;

          const lastContextTokens = (logPath) => {
            const stat = fs.statSync(logPath);
            const readSize = Math.min(stat.size, TAIL_BYTES);
            const fd = fs.openSync(logPath, 'r');
            const buf = Buffer.alloc(readSize);
            fs.readSync(fd, buf, 0, readSize, stat.size - readSize);
            fs.closeSync(fd);
            const lines = buf.toString('utf8').split('\n');
            for (let i = lines.length - 1; i >= 0; i--) {
              if (!lines[i].includes('"usage"')) continue;
              try {
                const u = JSON.parse(lines[i]).message?.usage;
                if (!u) continue;
                const n = (Number(u.input_tokens) || 0)
                  + (Number(u.cache_read_input_tokens) || 0)
                  + (Number(u.cache_creation_input_tokens) || 0);
                if (n > 0) return n;
              } catch (e) { /* truncated first line of the tail; keep going */ }
            }
            return 0;
          };

          const active = [];
          for (const f of fs.readdirSync(subDir)) {
            if (!/^agent-[A-Za-z0-9_-]+\.meta\.json$/.test(f)) continue;
            try {
              const meta = JSON.parse(fs.readFileSync(path.join(subDir, f), 'utf8'));
              if (!meta || meta.finished === true) continue;
              const logPath = path.join(subDir, f.replace(/\.meta\.json$/, '.jsonl'));
              let mtime = 0;
              let tokens = 0;
              try {
                mtime = fs.statSync(logPath).mtimeMs;
                tokens = lastContextTokens(logPath);
              } catch (e) {
                mtime = fs.statSync(path.join(subDir, f)).mtimeMs;
              }
              if (Date.now() - mtime > STALE_MS) continue;
              // Past 200k only a 1M window fits; an inherited model shares the
              // main session's window; anything else is assumed to be 200k.
              let windowSize = 200000;
              if (tokens > 200000) windowSize = 1000000;
              else if (meta.model === 'inherit' && Number(payloadWindow) > 0) windowSize = Number(payloadWindow);
              const rawName = [meta.name, meta.description, meta.agentType].find(v => typeof v === 'string' && v) || 'agent';
              active.push({ name: stripControl(rawName), tokens, windowSize, mtime });
            } catch (e) { /* skip this agent */ }
          }

          if (active.length > 0) {
            active.sort((a, b) => a.mtime - b.mtime);
            const MAX_SHOWN = 3;
            const MAX_NAME = 22;
            const cells = active.slice(0, MAX_SHOWN).map(a => {
              const name = a.name.length > MAX_NAME ? a.name.slice(0, MAX_NAME - 1) + '…' : a.name;
              if (!a.tokens) return `\x1b[1;37m${name}\x1b[0m \x1b[2m…\x1b[0m`;
              const pct = Math.max(0, Math.min(100, Math.round(a.tokens / a.windowSize * 100)));
              const filled = Math.floor(pct / 10);
              const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);
              const color = pct < 50 ? '\x1b[32m' : pct < 65 ? '\x1b[33m' : pct < 80 ? '\x1b[38;5;208m' : '\x1b[31m';
              return `\x1b[1;37m${name}\x1b[0m ${color}${bar} ${pct}%\x1b[0m`;
            });
            if (active.length > MAX_SHOWN) cells.push(`\x1b[2m+${active.length - MAX_SHOWN} more\x1b[0m`);
            const header = `\x1b[1;38;5;117m\u{1F916} ${active.length} active\x1b[0m`;
            subagentPart = [header, ...cells].join(' \x1b[2m│\x1b[0m ');
          }
        }
      } catch (e) { /* no subagents dir yet, or unreadable */ }
    }

    // ── Row 3: git context (payload-sourced, uncached) ──
    // repo, worktree and branch cost nothing to obtain, so they are read fresh on
    // every invocation. Only gh/supabase go through the cache below.
    // Wrapped in its own try/catch like every other segment: without it a
    // throw here would blank the entire status line rather than this row.
    let githubPart = '';
    let supabasePart = '';
    try {
      const { execFileSync } = require('child_process');

      const repoInfo = data.workspace?.repo;
      const payloadRepo = repoInfo && typeof repoInfo.owner === 'string' && repoInfo.owner && typeof repoInfo.name === 'string' && repoInfo.name
        ? `${repoInfo.owner}/${repoInfo.name}`
        : '';
      const payloadRepoUrl = payloadRepo && typeof repoInfo.host === 'string' && repoInfo.host
        ? `https://${repoInfo.host}/${repoInfo.owner}/${repoInfo.name}`
        : '';
      const branchName = readBranch(data.workspace?.current_dir || dir);
      const worktreeName = typeof data.workspace?.git_worktree === 'string'
        ? stripControl(data.workspace.git_worktree)
        : '';

      if (MODULES.github || MODULES.supabase) {
        const sessionSafeForCache = session && !/[/\\]|\.\./.test(session);
        const infoCachePath = sessionSafeForCache ? path.join(os.tmpdir(), `claude-info-${session}.json`) : null;
        const CACHE_TTL_MS = 120000;

        let infoCache = null;
        if (infoCachePath) {
          try {
            infoCache = JSON.parse(readTmpFile(infoCachePath));
            if (Date.now() - infoCache.ts > CACHE_TTL_MS) infoCache = null;
          } catch (e) { infoCache = null; }
        }

        if (!infoCache) {
          infoCache = { ts: Date.now(), gh_repo: '', gh_user: '', sb_project: '' };
          const cwd = data.workspace?.project_dir || dir;

          if (MODULES.github) {
            // Fallback only: Claude Code builds that predate workspace.repo, or a
            // repo with no origin remote. Skipped entirely when the payload has it.
            //
            // There is deliberately no branch fallback. readBranch covers every
            // real case — it walks up to the repo root, follows the gitdir:
            // pointer of worktrees and submodules, and handles a detached HEAD —
            // and caching a branch is actively wrong: the cached value outlives a
            // checkout, so the row would show a branch you already left.
            if (!payloadRepo) {
              try {
                const remote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd, timeout: 3000, stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
                const repoMatch = remote.match(/github\.com[:/](.+?)(?:\.git)?$/);
                if (repoMatch) infoCache.gh_repo = repoMatch[1];
              } catch (e) {}
            }
            try {
              const ghStatus = execFileSync('gh', ['auth', 'status'], { timeout: 3000, stdio: ['pipe', 'pipe', 'pipe'] });
              const combined = ghStatus.toString();
              const activeMatch = combined.match(/account (\S+)[\s\S]*?Active account: true/);
              if (activeMatch) infoCache.gh_user = activeMatch[1];
            } catch (e) {
              if (e.stderr) {
                const errStr = e.stderr.toString();
                const activeMatch = errStr.match(/account (\S+)[\s\S]*?Active account: true/);
                if (activeMatch) infoCache.gh_user = activeMatch[1];
              }
            }
          }

          if (MODULES.supabase) {
            try {
              const sbStatus = execFileSync('supabase', ['status'], { cwd, timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }).toString();
              const refMatch = sbStatus.match(/(?:API URL|Project ref):\s*(?:https?:\/\/)?(\S+)/);
              if (refMatch) {
                const ref = refMatch[1].replace('.supabase.co', '');
                infoCache.sb_project = ref;
                try {
                  const sbList = execFileSync('supabase', ['projects', 'list'], { timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }).toString();
                  for (const line of sbList.split('\n')) {
                    if (line.includes(ref)) {
                      const cols = line.split('|').map(c => c.trim());
                      if (cols.length >= 4 && cols[3]) infoCache.sb_project = cols[3];
                      break;
                    }
                  }
                } catch (e) {}
              }
            } catch (e) {}
          }

          if (infoCachePath) {
            try { writeTmpFile(infoCachePath, JSON.stringify(infoCache)); } catch (e) {}
          }
        }

        if (MODULES.github) {
          // Stripped here rather than relying on osc8: osc8 only sanitizes the
          // linked-text path (payloadRepoUrl present), not the plain-text
          // fallback, and infoCache.gh_repo/gh_user come from unvalidated
          // regexes over `git`/`gh` subprocess output.
          //
          // These strip and still render, while readBranch drops a ref outright
          // when stripping changed it. That asymmetry is deliberate: the branch
          // is a value you act on — a mangled name that reads like `main` could
          // have you commit somewhere you did not intend — so a suspect one is
          // better hidden than shown. Repo, worktree, account and project are
          // informational, and showing them inert beats hiding them silently,
          // because visible garbage tells you something is wrong.
          const repoName = stripControl(payloadRepo || infoCache.gh_repo);
          const branch = stripControl(branchName);
          const ghUser = stripControl(infoCache.gh_user);
          if (repoName) {
            // The link needs host, which the git fallback does not reconstruct;
            // without it the repo renders as plain text.
            const repoLabel = payloadRepoUrl ? osc8(payloadRepoUrl, repoName) : repoName;
            const repoStr = `\x1b[1;37m\u{1F419} ${repoLabel}\x1b[0m`;
            const branchStr = branch ? ` \x1b[1;32m\u238B ${branch}\x1b[0m` : '';
            const worktreeStr = worktreeName ? ` \x1b[1;38;5;114m\u{1F333} ${worktreeName}\x1b[0m` : '';
            const userStr = ghUser ? ` \x1b[2m@${ghUser}\x1b[0m` : '';
            githubPart = `${repoStr}${branchStr}${worktreeStr}${userStr}`;
          }
        }

        if (MODULES.supabase) {
          // Sourced from an unvalidated regex over `supabase status`/`projects list`.
          const sbProject = stripControl(infoCache.sb_project);
          if (sbProject) {
            supabasePart = `\x1b[1;38;5;42m\u26A1 ${sbProject}\x1b[0m`;
          }
        }
      }
    } catch (e) { /* silent */ }

    // ── Build display components ──
    const shortPath = (() => {
      const home = os.homedir();
      let p = dir.startsWith(home) ? '~' + dir.slice(home.length) : dir;
      const parts = p.split('/');
      if (parts.length > 4) p = parts[0] + '/\u2026/' + parts.slice(-2).join('/');
      return p;
    })();

    const projectDir = data.workspace?.project_dir;
    const wsName = (() => {
      if (!projectDir) return '';
      const home = os.homedir();
      const p = projectDir.startsWith(home) ? '~' + projectDir.slice(home.length) : projectDir;
      const parts = p.split('/');
      return parts[parts.length - 1] || p;
    })();

    // Lines changed
    const linesAdded = data.cost?.total_lines_added || 0;
    const linesRemoved = data.cost?.total_lines_removed || 0;
    const linesPart = MODULES.lines_changed ? `\x1b[32m+${linesAdded}\x1b[0m \x1b[31m-${linesRemoved}\x1b[0m` : '';

    // Context bar with label
    let ctxPart = '';
    if (remaining != null) {
      const used = usedPct;
      const filled = Math.floor(used / 10);
      const bar = '\u2588'.repeat(filled) + '\u2591'.repeat(10 - filled);
      const label = `CTX ${used}%`;
      if (used < 50) {
        ctxPart = `\x1b[32m${bar} ${label}\x1b[0m`;
      } else if (used < 65) {
        ctxPart = `\x1b[33m${bar} ${label}\x1b[0m`;
      } else if (used < 80) {
        ctxPart = `\x1b[38;5;208m${bar} ${label}\x1b[0m`;
      } else {
        ctxPart = `\x1b[5;31m\u{1F480} ${bar} ${label}\x1b[0m`;
      }
    }

    // Version
    const version = data.version ? `v${data.version}` : '';

    // ── Layout ──
    const dim = (s) => `\x1b[2m${s}\x1b[0m`;
    const sep = dim(' \u2502 ');
    // Claude Code passes the terminal width as COLUMNS (stdout is a pipe, so
    // there is no TTY to ask). A small margin keeps the rule from wrapping.
    const cols = parseInt(process.env.COLUMNS, 10);
    const ruleWidth = Number.isInteger(cols) && cols >= 24 ? Math.min(cols - 4, 300) : 100;
    const hr = dim('\u2500'.repeat(ruleWidth));

    // Location
    let locationPart;
    if (wsName && projectDir !== dir) {
      locationPart = `\x1b[1;36m\u{1F4C1} ${wsName}\x1b[0m ${dim('\u203A')} \x1b[1;34m\u{1F4C2} ${shortPath}\x1b[0m`;
    } else {
      locationPart = `\x1b[1;34m\u{1F4C2} ${shortPath}\x1b[0m`;
    }

    // ROW 1: Model + Version + Location + Lines + Context
    const modelDisplay = `\x1b[1;38;5;141m\u2B21 ${model}\x1b[0m`;
    const versionDisplay = version ? ` \x1b[2;38;5;245m${version}\x1b[0m` : '';

    const row1Cells = [
      `${modelDisplay}${versionDisplay}`,
      locationPart,
      linesPart,
      ctxPart
    ].filter(Boolean);

    // ROW 2: Effort + Output Style + Fast Mode + Session + Cost + Duration + Rate Limits
    const row2Cells = [effortPart, outputStylePart, fastModePart, sessionNamePart, costPart, promptCachePart, durationPart, rateLimitPart].filter(Boolean);

    // ── Pull request ──
    // data.pr is present only while an open PR exists for the branch; it
    // disappears once the PR merges or closes. review_state may be absent on
    // its own, so the symbol is optional while the number is not.
    let prPart = '';
    if (MODULES.pr) {
      try {
        const pr = data.pr;
        // A PR number is a positive integer. `typeof === 'number'` alone would
        // also admit 3.5 and -5, rendering `#3.5` / `#-5`.
        const number = pr && Number.isInteger(pr.number) && pr.number > 0 && pr.number <= Number.MAX_SAFE_INTEGER
          ? pr.number : null;
        if (number != null) {
          const states = Object.assign(Object.create(null), {
            approved:          { symbol: '✓', color: '\x1b[32m' },
            changes_requested: { symbol: '✗', color: '\x1b[38;5;208m' },
            pending:           { symbol: '●', color: '\x1b[33m' },
            draft:             { symbol: '○', color: '\x1b[2m' },
          });
          const state = (typeof pr.review_state === 'string' && states[pr.review_state]) || { symbol: '', color: '\x1b[1;37m' };
          const label = state.symbol ? `#${number} ${state.symbol}` : `#${number}`;
          const linked = osc8(pr.url, label);
          prPart = `${state.color}\u{1F500} ${linked}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ROW 3: GitHub + Supabase
    const row3Cells = [githubPart, prPart, supabasePart].filter(Boolean);

    // Compose
    const lines = [];
    lines.push(hr);
    lines.push(' ' + row1Cells.join(sep));
    if (row2Cells.length > 0) {
      lines.push(hr);
      lines.push(' ' + row2Cells.join(sep));
    }
    if (subagentPart) {
      lines.push(hr);
      lines.push(' ' + subagentPart);
    }
    if (row3Cells.length > 0) {
      lines.push(hr);
      lines.push(' ' + row3Cells.join(sep));
    }
    lines.push(hr);

    process.stdout.write(lines.join('\n'));
  } catch (e) {
    // Silent fail - don't break statusline on parse errors
  }
});
