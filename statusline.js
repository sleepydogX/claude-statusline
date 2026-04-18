#!/usr/bin/env node
// Claude Code Statusline — Enhanced Dashboard
// A rich, informative status bar for Claude Code sessions.
// https://github.com/sleepydogX/claude-statusline

const fs = require('fs');
const path = require('path');
const os = require('os');

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
  permission_mode: true, // Permission mode indicator (added in T4)
  fast_mode: true,       // Fast mode indicator (added in T5)
  mcp_health: true,      // MCP server health (added in T6)
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

    // ── Context window constants ──
    const AUTO_COMPACT_BUFFER_PCT = 16.5;

    // Write context metrics bridge file (for context-monitor hooks)
    if (MODULES.context_bridge && remaining != null) {
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));
      const sessionSafe = session && !/[/\\]|\.\./.test(session);
      if (sessionSafe) {
        try {
          const bridgePath = path.join(os.tmpdir(), `claude-ctx-${session}.json`);
          fs.writeFileSync(bridgePath, JSON.stringify({
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
    let effortPart = '';
    if (MODULES.effort) {
      try {
        const validLevels = new Set(['low', 'medium', 'high', 'xhigh', 'max']);
        const envRaw = process.env.CLAUDE_CODE_EFFORT_LEVEL;
        const envVal = envRaw ? envRaw.toLowerCase() : '';
        const envOverrides = envVal && envVal !== 'auto' && envVal !== 'unset';
        const settingsVal = typeof userSettings.effortLevel === 'string'
          ? userSettings.effortLevel.toLowerCase()
          : '';

        let display;
        let isOverride;
        let invalid = false;

        if (envOverrides) {
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
          const colorMap = {
            auto:   '\x1b[3m',
            low:    '\x1b[38;5;245m',
            medium: '\x1b[32m',
            high:   '\x1b[33m',
            xhigh:  '\x1b[38;5;208m',
            max:    '\x1b[1;35m',
          };
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
          outputStylePart = `\x1b[36m\u270D ${name}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── Permission mode ──
    let permissionModePart = '';
    if (MODULES.permission_mode) {
      try {
        const mode = data.permissionMode;
        if (mode && mode !== 'default') {
          const specs = {
            plan:              { label: 'PLAN',      color: '\x1b[34m',   icon: '\u{1F4CB}' },
            acceptEdits:       { label: 'AUTO-EDIT', color: '\x1b[33m',   icon: '\u270F' },
            bypassPermissions: { label: 'BYPASS',    color: '\x1b[5;31m', icon: '\u26A0' },
          };
          const spec = specs[mode];
          if (spec) {
            permissionModePart = `${spec.color}${spec.icon} ${spec.label}\x1b[0m`;
          }
        }
      } catch (e) { /* silent */ }
    }

    // ── Fast mode ──
    let fastModePart = '';
    if (MODULES.fast_mode) {
      try {
        if (userSettings.fastMode === true) {
          fastModePart = `\x1b[1;96m\u26A1 FAST\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── MCP health ──
    let mcpHealthPart = '';
    if (MODULES.mcp_health) {
      try {
        const servers = Array.isArray(data.mcp_servers) ? data.mcp_servers : [];
        const unhealthy = servers.filter(s => s && s.name && s.status && s.status !== 'connected');
        if (unhealthy.length > 0) {
          let inner;
          if (unhealthy.length <= 2) {
            inner = unhealthy.map(s => s.name).join(', ') + ' down';
          } else {
            inner = `${unhealthy.length} MCPs down`;
          }
          mcpHealthPart = `\x1b[31m\u{1F50C} ${inner}\x1b[0m`;
        }
      } catch (e) { /* silent */ }
    }

    // ── Current task from todos ──
    let task = '';
    const homeDir = os.homedir();
    const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(homeDir, '.claude');
    const todosDir = path.join(claudeDir, 'todos');
    if (session && fs.existsSync(todosDir)) {
      try {
        const files = fs.readdirSync(todosDir)
          .filter(f => f.startsWith(session) && f.includes('-agent-') && f.endsWith('.json'))
          .map(f => ({ name: f, mtime: fs.statSync(path.join(todosDir, f)).mtime }))
          .sort((a, b) => b.mtime - a.mtime);
        if (files.length > 0) {
          try {
            const todos = JSON.parse(fs.readFileSync(path.join(todosDir, files[0].name), 'utf8'));
            const inProgress = todos.find(t => t.status === 'in_progress');
            if (inProgress) task = inProgress.activeForm || '';
          } catch (e) {}
        }
      } catch (e) {}
    }

    // ── Session name (slug from transcript) ──
    let sessionNamePart = '';
    if (MODULES.session_name) {
      const transcriptPath = data.transcript_path;
      if (transcriptPath && fs.existsSync(transcriptPath)) {
        try {
          const sessionSafe = session && !/[/\\]|\.\./.test(session);
          const slugCachePath = sessionSafe ? path.join(os.tmpdir(), `claude-slug-${session}`) : null;
          let slug = '';
          if (slugCachePath && fs.existsSync(slugCachePath)) {
            slug = fs.readFileSync(slugCachePath, 'utf8').trim();
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
              try { fs.writeFileSync(slugCachePath, slug); } catch (e) {}
            }
          }
          if (slug) {
            const formatted = slug.split('-').map(w => w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
            sessionNamePart = `\x1b[1;38;5;213m\u{1F3F7} ${formatted}\x1b[0m`;
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
        durationPart = `\x1b[1;35m\u23F1 ${timeStr}\x1b[0m`;
      }
    }

    // ── Estimated cost ──
    let costPart = '';
    if (MODULES.cost) {
      const totalCost = data.cost?.total_cost_usd;
      if (totalCost != null && totalCost > 0) {
        const costStr = totalCost < 0.01 ? '<$0.01' : `$${totalCost.toFixed(2)}`;
        costPart = `\x1b[1;33m\u{1F4B0} ${costStr}\x1b[0m`;
      }
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
        if (fiveHour) {
          const pct = fiveHour.used_percentage || 0;
          let resetStr = '';
          if (fiveHour.resets_at) {
            const diffMs = fiveHour.resets_at * 1000 - Date.now();
            if (diffMs > 0) {
              const diffH = Math.floor(diffMs / 3600000);
              const diffM = Math.floor((diffMs % 3600000) / 60000);
              resetStr = ` \x1b[2m${diffH}h${String(diffM).padStart(2,'0')}m\x1b[0m`;
            }
          }
          parts.push(`\x1b[1;37m\u26A15h\x1b[0m ${colorPct(pct)}${resetStr}`);
        }
        if (sevenDay) {
          const pct = sevenDay.used_percentage || 0;
          parts.push(`\x1b[1;37m\u{1F4C5}7d\x1b[0m ${colorPct(pct)}`);
        }
        rateLimitPart = parts.join(' \x1b[2m\u2502\x1b[0m ');
      }
    }

    // ── GitHub & Supabase info (cached) ──
    const { execFileSync } = require('child_process');
    let githubPart = '';
    let supabasePart = '';

    if (MODULES.github || MODULES.supabase) {
      const sessionSafeForCache = session && !/[/\\]|\.\./.test(session);
      const infoCachePath = sessionSafeForCache ? path.join(os.tmpdir(), `claude-info-${session}.json`) : null;
      const CACHE_TTL_MS = 120000;

      let infoCache = null;
      if (infoCachePath && fs.existsSync(infoCachePath)) {
        try {
          infoCache = JSON.parse(fs.readFileSync(infoCachePath, 'utf8'));
          if (Date.now() - infoCache.ts > CACHE_TTL_MS) infoCache = null;
        } catch (e) { infoCache = null; }
      }

      if (!infoCache) {
        infoCache = { ts: Date.now(), gh_repo: '', gh_user: '', gh_branch: '', sb_project: '' };
        const cwd = data.workspace?.project_dir || dir;

        if (MODULES.github) {
          try {
            const remote = execFileSync('git', ['remote', 'get-url', 'origin'], { cwd, timeout: 3000 }).toString().trim();
            const repoMatch = remote.match(/github\.com[:/](.+?)(?:\.git)?$/);
            if (repoMatch) infoCache.gh_repo = repoMatch[1];
          } catch (e) {}
          try {
            const branch = execFileSync('git', ['branch', '--show-current'], { cwd, timeout: 2000 }).toString().trim();
            if (branch) infoCache.gh_branch = branch;
          } catch (e) {}
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
          try { fs.writeFileSync(infoCachePath, JSON.stringify(infoCache)); } catch (e) {}
        }
      }

      if (MODULES.github && infoCache.gh_repo) {
        const repoPart = `\x1b[1;37m\u{1F419} ${infoCache.gh_repo}\x1b[0m`;
        const branchStr = infoCache.gh_branch ? ` \x1b[1;32m\u238B ${infoCache.gh_branch}\x1b[0m` : '';
        const userStr = infoCache.gh_user ? ` \x1b[2m@${infoCache.gh_user}\x1b[0m` : '';
        githubPart = `${repoPart}${branchStr}${userStr}`;
      }

      if (MODULES.supabase && infoCache.sb_project) {
        supabasePart = `\x1b[1;38;5;42m\u26A1 ${infoCache.sb_project}\x1b[0m`;
      }
    }

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
      const usableRemaining = Math.max(0, ((remaining - AUTO_COMPACT_BUFFER_PCT) / (100 - AUTO_COMPACT_BUFFER_PCT)) * 100);
      const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));
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
    const hr = dim('\u2500'.repeat(100));

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

    // ROW 2: Effort + Output Style + Permission Mode + Fast Mode + MCP Health + Session + Cost + Duration + Rate Limits
    const row2Cells = [effortPart, outputStylePart, permissionModePart, fastModePart, mcpHealthPart, sessionNamePart, costPart, durationPart, rateLimitPart].filter(Boolean);

    // ROW 3: GitHub + Supabase
    const row3Cells = [githubPart, supabasePart].filter(Boolean);

    // Task row
    const taskRow = task ? `\x1b[1;38;5;220m\u2699 ${task}\x1b[0m` : '';

    // Compose
    const lines = [];
    lines.push(hr);
    lines.push(' ' + row1Cells.join(sep));
    if (taskRow) {
      lines.push(hr);
      lines.push(' ' + taskRow);
    }
    if (row2Cells.length > 0) {
      lines.push(hr);
      lines.push(' ' + row2Cells.join(sep));
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
