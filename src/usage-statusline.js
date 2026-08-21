#!/usr/bin/env node
// usage-statusline.js — status line wrapper for claude-usage-monitor
//   1. forwards the statusline JSON to `claude-usage record --notify`
//      (stores rate_limits, fires threshold notifications)
//   2. runs the user's original statusLine command (config: inner_statusline), if any
//   3. appends the 5h / 7d usage segment
const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const TOOL = path.join(__dirname, 'claude-usage');

let inner = '';
try {
  inner = JSON.parse(fs.readFileSync(path.join(claudeDir, 'usage-monitor.json'), 'utf8')).inner_statusline || '';
} catch (e) {}

let input = '';
const t = setTimeout(() => process.exit(0), 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => (input += c));
process.stdin.on('end', () => {
  clearTimeout(t);
  let out = '';
  if (inner) {
    try {
      const r = spawnSync(inner, { input, encoding: 'utf8', timeout: 2500, shell: true });
      out = r.stdout || '';
    } catch (e) {}
  } else {
    try {
      const d = JSON.parse(input);
      const model = d.model?.display_name || 'Claude';
      const dir = path.basename(d.workspace?.current_dir || process.cwd());
      const rem = d.context_window?.remaining_percentage;
      out = `\x1b[2m${model}\x1b[0m │ \x1b[2m${dir}\x1b[0m`;
      if (rem != null) out += ` │ ctx ${Math.round(100 - rem)}%`;
    } catch (e) {}
  }
  try {
    spawnSync(TOOL, ['record', '--notify'], { input, encoding: 'utf8', timeout: 2500 });
    const s = spawnSync(TOOL, ['segment'], { encoding: 'utf8', timeout: 1500 });
    out += s.stdout || '';
  } catch (e) {}
  process.stdout.write(out);
});
