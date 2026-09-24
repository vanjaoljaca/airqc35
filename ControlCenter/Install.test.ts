class MemoryFiles implements Files {
  entries = new Map<string, string>();
  directories = new Set<string>();
  links = new Set<string>();
  exists(path: string) { return this.entries.has(path) || this.directories.has(path); }
  read(path: string) { const value = this.entries.get(path); if (value === undefined) throw new Error(`Missing test file: ${path}`); return value; }
  write(path: string, value: string) { this.mkdir(dirname(path)); this.entries.set(path, value); }
  mkdir(path: string) { this.directories.add(path); }
  copy(source: string, target: string) {
    if (!this.exists(source)) throw new Error(`Missing copy source: ${source}`);
    for (const [path, value] of [...this.entries]) if (path === source || path.startsWith(`${source}/`)) this.write(target + path.slice(source.length), value);
    for (const path of [...this.directories]) if (path === source || path.startsWith(`${source}/`)) this.mkdir(target + path.slice(source.length));
  }
  move(source: string, target: string) { this.remove(target); this.copy(source, target); this.remove(source); }
  remove(path: string) {
    for (const key of [...this.entries.keys()]) if (key === path || key.startsWith(`${path}/`)) this.entries.delete(key);
    for (const key of [...this.directories]) if (key === path || key.startsWith(`${path}/`)) this.directories.delete(key);
  }
  digest(path: string) { return createHash('sha256').update(this.read(path)).digest('hex'); }
  isLink(path: string) { return this.links.has(path); }
}

function fixture() {
  const files = new MemoryFiles();
  const paths = createPaths('/arbitrary source/Air Qc35', '/Users/Person With Spaces');
  const artifacts = { helper: join(paths.payload, Identity.helper), app: join(paths.payload, Identity.app), builtApp: join(paths.derived, 'Build/Products/Release', Identity.app) };
  const commands: Command[] = []; const events: { event: string; [key: string]: unknown }[] = [];
  const processes = new Map<number, string>();
  const state = { service: { loaded: false } as Service, nextPID: 200, bootstrapFailures: 0, restartDelay: 0, restartPending: false, neverRun: false, emitStarted: true, startupError: false, errorDuringConfirmation: false, waits: 0 };
  const ok = (stdout = '') => ({ status: 0, stdout, stderr: '' });
  const app = (path: string, identity = Identity.bundle, contents = 'new app') => {
    files.mkdir(path); files.write(join(path, 'Contents/Info.plist'), JSON.stringify({ CFBundleIdentifier: identity, CFBundleExecutable: 'AirQc35' }));
    files.write(join(path, 'Contents/MacOS/AirQc35'), contents);
  };
  const started = (pid: number, revision = '4') => {
    const path = join(paths.logs, 'events.jsonl');
    const record = { pid: String(pid), service: Identity.label, runtimeRoot: paths.runtime, time: new Date().toISOString(), revision };
    let text = files.exists(path) ? files.read(path) : '';
    text += JSON.stringify({ ...record, event: 'started' }) + '\n';
    if (state.startupError) text += JSON.stringify({ ...record, event: 'audio_error' }) + '\n';
    files.write(path, text);
  };
  const start = () => {
    state.service = { loaded: true, program: paths.helper, ...(state.neverRun ? {} : { pid: state.nextPID++ }) };
    if (state.service.pid) { processes.set(state.service.pid, paths.helper); if (state.emitStarted) started(state.service.pid); }
  };
  const context: Context = {
    source: paths.source, home: paths.home, uid: 777, architecture: 'arm64', node: '/portable node/bin/node', files,
    log: (event, fields = {}) => events.push({ event, ...fields }), wait: () => {
      state.waits += 1;
      if (state.errorDuringConfirmation && state.service.pid) {
        const path = join(paths.logs, 'events.jsonl');
        files.write(path, files.read(path) + JSON.stringify({ event: 'audio_error', pid: String(state.service.pid), service: Identity.label, runtimeRoot: paths.runtime }) + '\n');
        state.errorDuringConfirmation = false;
      }
    },
    run: command => {
      commands.push(command);
      const [action] = command.args;
      if (command.file === '/usr/bin/plutil') return command.args.includes('json') ? ok(files.read(command.args.at(-1)!)) : ok();
      if (command.file === '/bin/launchctl') {
        if (action === 'print') {
          if (state.restartPending && state.restartDelay-- <= 0) { start(); state.restartPending = false; }
          return state.service.loaded ? ok(`program = ${state.service.program}\n${state.service.pid ? `pid = ${state.service.pid}\n` : ''}`) : { status: 113, stdout: '', stderr: 'Could not find service' };
        }
        if (action === 'bootout') { if (state.service.pid) processes.delete(state.service.pid); state.service = { loaded: false }; return ok(); }
        if (action === 'bootstrap') {
          if (state.bootstrapFailures-- > 0) return { status: 5, stdout: '', stderr: 'Injected bootstrap failure' };
          start(); return ok();
        }
        if (action === 'kill') { state.restartPending = true; return ok(); }
      }
      if (command.file === '/bin/ps') {
        if (command.args.includes('-axo')) return ok([...processes].map(([pid, path]) => `${pid} ${path}`).join('\n'));
        const executable = processes.get(Number(command.args[command.args.indexOf('-p') + 1]));
        return executable ? ok(executable) : { status: 1, stdout: '', stderr: '' };
      }
      if (command.file === '/bin/kill') { processes.delete(Number(command.args.at(-1))); return ok(); }
      if (command.file === artifacts.helper && action === 'setup') { files.write(paths.config, '{"discovered":true}'); return ok(); }
      if (command.file === '/usr/bin/xcrun') { files.write(artifacts.helper, 'new helper'); return ok(); }
      if (command.file === '/usr/bin/xcodebuild') {
        if (command.args.includes('-json')) return ok(JSON.stringify([{ target: 'QC35', buildSettings: { PRODUCT_BUNDLE_IDENTIFIER: Identity.bundle, TARGET_BUILD_DIR: dirname(artifacts.builtApp), FULL_PRODUCT_NAME: Identity.app } }]));
        app(artifacts.builtApp); return ok();
      }
      return ok();
    },
  };
  app(artifacts.app); files.write(artifacts.helper, 'new helper');
  const existing = (helper = 'old helper', plist = launchAgent(paths)) => {
    files.write(paths.helper, helper); files.write(paths.plist, JSON.stringify(plist)); files.write(paths.config, ' { "keep": "every byte" }\n');
    app(paths.app, Identity.bundle, 'old app'); state.service = { loaded: true, program: paths.helper, pid: 100 }; processes.set(100, paths.helper); started(100, '3');
  };
  return { context, files, paths, artifacts, commands, events, processes, state, app, existing };
}

const noOpen = parseOptions(['--no-open']);
const mutations = (commands: Command[]) => commands.filter(command => command.file === '/bin/launchctl' && command.args[0] !== 'print');

test('paths and build arguments preserve spaces and native Release settings', () => {
  const { context, paths } = fixture();
  const commands = buildCommands(context, paths);
  assert.equal(commands[0].args[commands[0].args.indexOf('-o') + 1], join(paths.payload, Identity.helper));
  assert(commands[0].args.includes(join(paths.source, 'QC35InputGuard.swift')));
  assert(commands[2].args.includes('Release')); assert(commands[2].args.includes('ARCHS=arm64'));
  assert(commands.every(command => command.file !== '/bin/sh'));
  assert.throws(() => parseOptions(['--headset'])); assert.throws(() => parseOptions(['--uninstall', '--build-only']));
});

test('existing stable LaunchAgent is semantically reused, including log paths and throttle', () => {
  const { paths } = fixture(); const current = launchAgent(paths);
  assert.equal(current.StandardOutPath, join(paths.logs, 'launchd.stdout.log'));
  assert.equal(current.ThrottleInterval, 10);
  assert.deepEqual(planService(current, launchAgent(paths, current), { loaded: true, program: paths.helper, pid: 1 }, false), { writePlist: false, bootout: false, bootstrap: false, restart: false });
  assert.throws(() => planService(current, current, { loaded: true, program: '/unrelated/program' }, true));
  assert.equal(launchAgent(paths, { ...current, Program: '/unrelated/override' }).Program, undefined);
  assert.throws(() => parseService({ status: 1, stdout: '', stderr: 'Operation not permitted' }));
});

test('build-only produces verified artifacts without setup, service, or home-directory mutations', () => {
  const f = fixture(); runInstaller(f.context, parseOptions(['--build-only']));
  assert.equal(f.commands.filter(command => command.file === '/usr/bin/codesign').length, 3);
  assert.equal(f.commands.some(command => command.file === '/bin/launchctl' || command.args.includes('setup')), false);
  assert.equal([...f.files.entries.keys()].some(path => path.startsWith(`${f.paths.home}/`)), false);
});

test('fresh installation discovers configuration and bootstraps the standalone owned helper', () => {
  const f = fixture(); install(f.context, parseOptions(['--no-open', '--headset', 'Renamed QC35', '--input', 'Safe mic UID']), f.artifacts);
  assert.deepEqual(f.commands.find(command => command.args[0] === 'setup')?.args, ['setup', '--headset', 'Renamed QC35', '--input', 'Safe mic UID']);
  assert.deepEqual(mutations(f.commands).map(command => command.args[0]), ['bootstrap']);
  assert.equal(JSON.parse(f.files.read(f.paths.plist)).ProgramArguments[0], f.paths.helper);
  assert.equal(f.events.find(event => event.event === 'installed')?.configPreserved, false);
  assert.equal(f.commands.some(command => command.file === '/usr/bin/open'), false);
});

test('same binary and plist preserve exact config/plist bytes without launchd mutation', () => {
  const f = fixture(); f.existing('new helper'); const config = f.files.read(f.paths.config); const plist = f.files.read(f.paths.plist);
  install(f.context, noOpen, f.artifacts);
  assert.equal(f.files.read(f.paths.config), config); assert.equal(f.files.read(f.paths.plist), plist);
  assert.equal(mutations(f.commands).length, 0); assert.equal(f.commands.some(command => command.args[0] === 'setup'), false);
});

test('helper-only update signals managed job and waits for a stable different PID', () => {
  const f = fixture(); f.existing(); f.state.restartDelay = 3;
  install(f.context, noOpen, f.artifacts);
  assert.deepEqual(mutations(f.commands).map(command => command.args), [['kill', 'SIGTERM', `gui/777/${Identity.label}`]]);
  assert(f.state.waits >= 3); assert.notEqual(f.events.find(event => event.event === 'service_running')?.pid, 100);
  assert.equal(f.commands.some(command => command.args.includes('kickstart')), false);
});

test('bootstrap failure restores previous helper, app and exact plist, then restores old service', () => {
  const f = fixture(); f.existing('old helper', { ...launchAgent(f.paths), KeepAlive: false });
  const plist = f.files.read(f.paths.plist); f.state.bootstrapFailures = 1;
  assert.throws(() => install(f.context, noOpen, f.artifacts), /bootstrap failed/);
  assert.equal(f.files.read(f.paths.helper), 'old helper'); assert.equal(f.files.read(join(f.paths.app, 'Contents/MacOS/AirQc35')), 'old app');
  assert.equal(f.files.read(f.paths.plist), plist); assert.equal(f.state.service.loaded, true);
  assert(f.events.some(event => event.event === 'installation_rolled_back'));
});

test('loaded service with no PID never reports successful installation', () => {
  const f = fixture(); f.state.neverRun = true;
  assert.throws(() => install(f.context, noOpen, f.artifacts), /stable running PID/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
  assert.equal(f.files.exists(f.paths.helper), false); assert.equal(f.files.exists(f.paths.config), true);
});

test('stable PID without its own started event is not accepted as ready', () => {
  const f = fixture(); f.state.emitStarted = false;
  f.files.write(join(f.paths.logs, 'events.jsonl'), JSON.stringify({ event: 'started', pid: '999', service: Identity.label, runtimeRoot: f.paths.runtime, time: new Date().toISOString() }) + '\n');
  assert.throws(() => install(f.context, noOpen, f.artifacts), /started event/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
  assert.equal(f.files.exists(f.paths.helper), false);
});

test('early audio error after started does not count as a healthy install', () => {
  const f = fixture(); f.state.startupError = true;
  assert.throws(() => install(f.context, noOpen, f.artifacts), /started event/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
});

test('startup error appearing during PID confirmation prevents success', () => {
  const f = fixture(); f.state.errorDuringConfirmation = true;
  assert.throws(() => install(f.context, noOpen, f.artifacts), /started event/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
});

test('unchanged helper accepts its existing startup receipt despite a historical transient error', () => {
  const f = fixture(); f.existing('new helper');
  const path = join(f.paths.logs, 'events.jsonl');
  f.files.write(path, f.files.read(path) + JSON.stringify({ event: 'audio_error', pid: '100', service: Identity.label, runtimeRoot: f.paths.runtime }) + '\n');
  install(f.context, noOpen, f.artifacts);
  assert.equal(mutations(f.commands).length, 0);
  assert.equal(f.events.some(event => event.event === 'installed'), true);
});

test('uninstall rejects an executable Program override before touching service state', () => {
  const f = fixture(); f.existing('new helper', { ...launchAgent(f.paths), Program: '/unrelated/override' });
  assert.throws(() => uninstall(f.context), /not the owned helper/);
  assert.equal(mutations(f.commands).length, 0); assert.equal(f.files.exists(f.paths.helper), true);
});

test('legacy migration stops only the exact owned app path and unregisters source builds before final registration', () => {
  const f = fixture(); f.existing('new helper'); f.app(f.paths.legacyApp);
  f.processes.set(800, join(f.paths.legacyApp, 'Contents/MacOS/AirQc35'));
  f.processes.set(801, '/somewhere else/AirQc35.app/Contents/MacOS/AirQc35');
  install(f.context, noOpen, f.artifacts);
  assert.equal(f.processes.has(800), false); assert.equal(f.processes.has(801), true); assert.equal(f.files.exists(f.paths.legacyApp), false);
  const registrations = f.commands.filter(command => command.file.endsWith('/lsregister'));
  assert.deepEqual(registrations.at(-1)?.args, ['-f', f.paths.app]);
  assert(registrations.some(command => command.args[0] === '-u' && command.args[1] === f.artifacts.app));
});

test('fresh install tolerates already unregistered payload and derived app copies', () => {
  const f = fixture(); const run = f.context.run;
  f.context.run = command => {
    const result = run(command);
    if (command.file.endsWith('/lsregister') && command.args[0] === '-u') return { status: 1, stdout: '', stderr: `failed to scan ${command.args[1]}: -10814\n from spotlight\n` };
    return result;
  };
  install(f.context, noOpen, f.artifacts);
  assert.deepEqual(f.events.filter(event => event.event === 'build_copy_already_unregistered').map(event => event.path), [f.artifacts.app, f.artifacts.builtApp]);
  assert.deepEqual(f.commands.filter(command => command.file.endsWith('/lsregister')).at(-1)?.args, ['-f', f.paths.app]);
  assert.equal(f.events.some(event => event.event === 'installed'), true);
  assert.equal(f.events.some(event => event.event === 'installation_rolled_back'), false);
});

test('other build-copy unregister errors still fail and roll back installation', () => {
  const f = fixture(); const run = f.context.run;
  f.context.run = command => {
    const result = run(command);
    if (command.file.endsWith('/lsregister') && command.args[0] === '-u') return { status: 1, stdout: '', stderr: `failed to scan ${command.args[1]}: -10811\n from spotlight\n` };
    return result;
  };
  assert.throws(() => install(f.context, noOpen, f.artifacts), /lsregister failed/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
  assert.equal(f.files.exists(f.paths.app), false);
  assert.equal(f.events.some(event => event.event === 'installation_rolled_back'), true);
});

test('installed-app registration remains strict even for application-not-found errors', () => {
  const f = fixture(); const run = f.context.run;
  f.context.run = command => {
    const result = run(command);
    if (command.file.endsWith('/lsregister') && command.args[0] === '-f') return { status: 1, stdout: '', stderr: `failed to scan ${command.args[1]}: -10814\n from spotlight\n` };
    return result;
  };
  assert.throws(() => install(f.context, noOpen, f.artifacts), /lsregister failed/);
  assert.equal(f.events.some(event => event.event === 'installed'), false);
  assert.equal(f.files.exists(f.paths.app), false);
});

test('update and migration stop verified embedded widgets before moving their apps, preserving other widget paths', () => {
  const f = fixture(); f.existing('new helper'); f.app(f.paths.legacyApp);
  const executable = (app: string) => join(app, 'Contents/PlugIns/QC35Widget.appex/Contents/MacOS/QC35Widget');
  for (const [index, app] of [f.paths.app, f.paths.legacyApp].entries()) {
    f.files.write(join(app, 'Contents/PlugIns/QC35Widget.appex/Contents/Info.plist'), JSON.stringify({ CFBundleIdentifier: Identity.widget, CFBundleExecutable: 'QC35Widget' }));
    f.processes.set(810 + index, executable(app));
  }
  f.processes.set(812, executable('/another app/AirQc35.app'));
  const move = f.files.move.bind(f.files);
  f.files.move = (source, target) => {
    if ([f.paths.app, f.paths.legacyApp].includes(source)) assert.equal([...f.processes.values()].includes(executable(source)), false);
    move(source, target);
  };
  install(f.context, noOpen, f.artifacts);
  assert.deepEqual(f.commands.filter(command => command.file === '/bin/kill').map(command => command.args), [['-TERM', '810'], ['-TERM', '811']]);
  assert.equal(f.processes.has(812), true);
});

test('embedded widget with a different bundle identity is not signalled', () => {
  const f = fixture(); f.existing('new helper');
  const bundle = join(f.paths.app, 'Contents/PlugIns/QC35Widget.appex');
  f.files.write(join(bundle, 'Contents/Info.plist'), JSON.stringify({ CFBundleIdentifier: 'org.someone.other.widget', CFBundleExecutable: 'QC35Widget' }));
  f.processes.set(820, join(bundle, 'Contents/MacOS/QC35Widget'));
  install(f.context, noOpen, f.artifacts);
  assert.equal(f.processes.has(820), true);
  assert.equal(f.commands.some(command => command.file === '/bin/kill'), false);
});

test('unrelated legacy app survives installation and uninstall preserves config and logs', () => {
  const f = fixture(); f.existing('new helper'); f.app(f.paths.legacyApp, 'org.someone.other');
  f.files.write(join(f.paths.logs, 'launchd.stdout.log'), 'keep log'); const config = f.files.read(f.paths.config);
  install(f.context, noOpen, f.artifacts); uninstall(f.context);
  assert.equal(f.files.read(f.paths.config), config); assert.equal(f.files.read(join(f.paths.logs, 'launchd.stdout.log')), 'keep log');
  assert.equal(f.files.exists(f.paths.legacyApp), true); assert.equal(f.files.exists(f.paths.helper), false); assert.equal(f.files.exists(f.paths.app), false);
});

test('unrelated destination and symlink helper are rejected without service mutation', () => {
  const f = fixture(); f.app(f.paths.app, 'org.someone.other');
  assert.throws(() => install(f.context, noOpen, f.artifacts), /unrelated application/);
  assert.equal(mutations(f.commands).length, 0);
  const other = fixture(); other.existing(); other.files.links.add(other.paths.helper);
  assert.throws(() => install(other.context, noOpen, other.artifacts), /symlink/);
  assert.equal(mutations(other.commands).length, 0);
});

test('CLI launched through a symlink runs instead of silently succeeding', { skip: process.platform !== 'darwin' }, () => {
  const directory = mkdtempSync(join(tmpdir(), 'airqc35-cli-'));
  const entry = join(directory, 'Install.ts');
  try {
    symlinkSync(fileURLToPath(new URL('./Install.ts', import.meta.url)), entry);
    const result = spawnSync(process.execPath, ['--experimental-strip-types', entry, '--invalid-option'], { encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /Unknown option: --invalid-option/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { createHash } from 'node:crypto';
import { buildCommands, createPaths, Identity, install, launchAgent, parseOptions, parseService, planService, runInstaller, uninstall } from './Install.ts';
import type { Command, Context, Files, Service } from './Install.ts';
import { mkdtempSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
