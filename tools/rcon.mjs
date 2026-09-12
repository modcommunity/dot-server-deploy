#!/usr/bin/env node
//
// A Source-protocol RCON client, for administering a running server from a script.
//
//   node tools/rcon.mjs "changelevel hungry_classic"
//   node tools/rcon.mjs --host 10.0.0.5 --port 6081 "status"
//   node tools/rcon.mjs --game-port 6080 "status"     # the same server, named by
//                                                     # the port you already know
//   TMC_RCON_PASSWORD=... node tools/rcon.mjs "games"
//
// `--port` is the RCON port and `--game-port` is the port players connect to, which
// are one apart and NOT interchangeable. A caller administering several servers knows
// the second and not the first -- so it converts here, in the one file that already
// had to state the rule, rather than in every script that has a list of servers. Given
// a game port off by that one, the connection lands on the NEXT server along, which is
// a mistake that succeeds often enough to be believed.
//
// The password comes from cfg/rcon.yml by default. It is deliberately NOT a command
// line option: argv is readable by every other process on the machine and ends up in
// pasted bug reports, which is why ./server refuses --rcon-password and why
// DotConfig refuses secrets from argv and the environment. TMC_RCON_PASSWORD exists
// for a CI runner that has no file, and is the lesser evil rather than a good idea.
//
// The protocol is four little-endian int32 fields and two NULs:
//
//   size (of everything after it) | id | type | body\0 | \0
//
// Types: 3 authenticate, 2 execute. A successful auth is answered with a type-2
// packet carrying the request's id; a failure carries -1, which is the only thing
// distinguishing them and is why a client MUST check it.

import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TYPE_AUTH = 3;
const TYPE_EXEC = 2;
const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

function usage() {
  console.error(`
  node tools/rcon.mjs [--host H] [--port N | --game-port N] [--config DIR] <command...>

  --port       the RCON port.
  --game-port  the port players connect to; RCON is that plus one.

  Reads the password from <config>/rcon.yml unless TMC_RCON_PASSWORD is set.
`);
  process.exit(2);
}

const argv = process.argv.slice(2);
let host = '127.0.0.1';
let port = 0;
let gamePort = 0;
let configDir = path.join(ROOT, 'cfg');
const words = [];

for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--host') host = argv[++i];
  else if (argv[i] === '--port') port = Number(argv[++i]);
  else if (argv[i] === '--game-port') gamePort = Number(argv[++i]);
  else if (argv[i] === '--config') configDir = argv[++i];
  else if (argv[i] === '-h' || argv[i] === '--help') usage();
  else words.push(argv[i]);
}

if (words.length === 0) usage();
const command = words.join(' ');

// A one-key read, not a YAML parser. dot-serve makes the same choice for the same
// reason: a second parser here would drift from the one the server actually uses.
function readCfg(file, key) {
  try {
    const text = fs.readFileSync(file, 'utf8');
    const m = text.match(new RegExp(`^\\s*${key}\\s*:\\s*"?([^"#\\n]*)"?`, 'm'));
    return m ? m[1].trim() : '';
  } catch { return ''; }
}

const password = process.env.TMC_RCON_PASSWORD
  || readCfg(path.join(configDir, 'rcon.yml'), 'rcon_password');

if (!password) {
  console.error(`no RCON password in ${configDir}/rcon.yml and TMC_RCON_PASSWORD is unset`);
  console.error('an empty password means the RCON listener does not open at all');
  process.exit(5);
}

if (!port && gamePort) {
  // The one place the +1 lives. A caller with a list of servers has their game ports
  // and nothing else, and every one of those callers deriving this for itself is how
  // the rule ends up wrong in one of them.
  port = gamePort + 1;
}

if (!port) {
  // rcon_port 0 means "the game port + 1", which is what DotServerConfig does.
  const declared = Number(readCfg(path.join(configDir, 'rcon.yml'), 'rcon_port')) || 0;
  port = declared || (Number(readCfg(path.join(configDir, 'net.yml'), 'net_port')) || 6064) + 1;
}

function packet(id, type, body) {
  const bodyBytes = Buffer.from(body, 'utf8');
  const buf = Buffer.alloc(4 + 4 + 4 + bodyBytes.length + 2);
  buf.writeInt32LE(4 + 4 + bodyBytes.length + 2, 0);
  buf.writeInt32LE(id, 4);
  buf.writeInt32LE(type, 8);
  bodyBytes.copy(buf, 12);
  return buf;
}

const socket = net.createConnection({ host, port });
socket.setTimeout(10000);

let buffer = Buffer.alloc(0);
let authed = false;
const output = [];

socket.on('connect', () => socket.write(packet(1, TYPE_AUTH, password)));

socket.on('data', (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);

  // A short read is normal on a stream socket: keep the partial tail rather than
  // discarding it, or a reply that arrives in two TCP segments is lost.
  while (buffer.length >= 4) {
    const size = buffer.readInt32LE(0);
    if (buffer.length < size + 4) break;

    const id = buffer.readInt32LE(4);
    const body = buffer.slice(12, size + 4 - 2).toString('utf8');
    buffer = buffer.slice(size + 4);

    if (!authed) {
      // -1 is a refused password. Checking it is the whole of the auth handshake,
      // and a client that skipped it would send its command to a server that
      // silently ignores it.
      if (id === -1) {
        console.error('RCON authentication failed: wrong password');
        socket.destroy();
        process.exit(5);
      }
      authed = true;
      socket.write(packet(2, TYPE_EXEC, command));
      continue;
    }

    output.push(body);
    // dot-server answers one command with one packet, so the first reply after auth
    // is the whole of it. Closing here rather than waiting for a timeout is what
    // makes this usable in a script.
    socket.end();
  }
});

socket.on('timeout', () => {
  console.error(`RCON timed out talking to ${host}:${port}`);
  socket.destroy();
  process.exit(4);
});

socket.on('error', (e) => {
  console.error(`RCON could not reach ${host}:${port}: ${e.message}`);
  process.exit(4);
});

socket.on('close', () => {
  const text = output.join('').trimEnd();
  if (text) console.log(text);
  process.exit(0);
});
