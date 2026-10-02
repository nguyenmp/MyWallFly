#!/usr/bin/env node
// Render a saved transcript into the page, so a real meeting can be looked at.
//
//   node render.js ../../2026-10-01T21-34-06Z/transcript.txt [out.html]
//
// A saved transcript is one line per turn. This reads it, works out when each
// turn ended, and swaps the page's data block for the real thing. The page
// itself is never copied, so there is only ever one copy of it to keep up.
//
// The changes made on the page are kept beside the transcript in edits.json.
// When that file is there it goes into the page too, so the names, merges, and
// reassignments come back with the transcript.

const fs = require('fs');
const path = require('path');

const TURN = /^\[\s*([0-9.]+)\s*s\]\s*([A-Za-z]+)\s+([A-Za-z0-9]+):\s*(.*)$/;
const LIVE = /^\s*\u2026\s*([A-Za-z]+)\s+([A-Za-z0-9]+):\s*(.*)$/;

// The transcript calls the second track "sys". The page calls it "system".
function trackName(raw){ return raw === 'sys' ? 'system' : raw; }

function parse(text){
  const turns = [];
  let open = null;
  text.split('\n').forEach(raw => {
    if (!raw.trim()) return;
    let m = raw.match(TURN);
    if (m){
      turns.push({
        track: trackName(m[2]),
        label: m[3],
        t0: Math.round(Number(m[1]) * 1000),
        text: m[4].trim()
      });
      return;
    }
    m = raw.match(LIVE);
    if (m) open = { track: trackName(m[1]), label: m[2], text: m[3].trim() };
  });
  return { turns: turns, open: open };
}

// A saved line carries the moment it started, not when it ended. The next turn
// on the same track gives the end. The last turn on a track has nothing after it,
// so guess from its length at about 2.7 words a second.
function addEnds(turns){
  const byTrack = new Map();
  turns.forEach(t => {
    if (!byTrack.has(t.track)) byTrack.set(t.track, []);
    byTrack.get(t.track).push(t);
  });
  byTrack.forEach(list => {
    list.sort((a, b) => a.t0 - b.t0);
    list.forEach((turn, i) => {
      const next = list[i + 1];
      if (next && next.t0 > turn.t0){
        turn.t1 = next.t0;
        return;
      }
      const words = turn.text.split(/\s+/).filter(Boolean).length;
      turn.t1 = turn.t0 + Math.max(1000, Math.round(words * 370));
    });
  });
  return turns;
}

// The changes the reader made on the page, if the run kept them.
function readEdits(near){
  const file = path.join(path.dirname(path.resolve(near)), 'edits.json');
  if (!fs.existsSync(file)) return null;
  try {
    const list = JSON.parse(fs.readFileSync(file, 'utf8'));
    return Array.isArray(list) && list.length ? list : null;
  } catch (err) {
    console.error('could not read ' + file + ': ' + err.message);
    return null;
  }
}

function main(){
  const source = process.argv[2];
  if (!source){
    console.error('usage: node render.js <transcript.txt> [out.html]');
    process.exit(2);
  }
  const text = fs.readFileSync(source, 'utf8');
  const data = parse(text);
  addEnds(data.turns);
  data.open = data.open || null;
  data.edits = readEdits(source);
  data.label = path.basename(path.dirname(path.resolve(source))) || 'sample data';
  data.turns = data.turns.map(t => ({
    track: t.track, label: t.label, t0: t.t0, t1: t.t1, text: t.text
  }));

  const page = path.join(__dirname, '..', 'Sources', 'WallFlyTranscribe', 'Web', 'transcript.html');
  const template = fs.readFileSync(page, 'utf8');
  const marker = 'window.WALLFLY_DATA = ';
  const from = template.indexOf(marker);
  const to = from < 0 ? -1 : template.indexOf('\n};\n</script>', from);
  if (from < 0 || to < 0) throw new Error('cannot find the data block in transcript.html');

  const out = process.argv[3]
    || path.join(path.dirname(path.resolve(source)), data.label + '-page.html');
  // The template already carries the closing "};" of the block, so only the
  // object itself is replaced.
  const filled = template.slice(0, from + marker.length)
               + JSON.stringify(data, null, 2)
               + template.slice(to + 2);
  fs.writeFileSync(out, filled);

  const speakers = new Set(data.turns.map(t => t.track + ' ' + t.label));
  const last = data.turns.reduce((m, t) => Math.max(m, t.t1), 0);
  const longest = data.turns.reduce((m, t) => Math.max(m, t.text.length), 0);
  console.log('turns      ' + data.turns.length);
  console.log('speakers   ' + speakers.size + ' across ' + new Set(data.turns.map(t => t.track)).size + ' tracks');
  console.log('span       ' + Math.round(last / 60000) + ' minutes');
  console.log('longest    ' + longest + ' characters on one line');
  console.log('live line  ' + (data.open ? 'yes' : 'no'));
  console.log('changes    ' + (data.edits ? data.edits.length : 'none kept'));
  console.log('wrote      ' + out);
}

main();
