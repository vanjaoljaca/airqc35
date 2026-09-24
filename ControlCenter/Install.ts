export const Identity = {
  label: 'com.vanja.qc35.inputguard', bundle: 'com.vanja.qc35.control',
  widget: 'com.vanja.qc35.control.widget',
  helper: 'QC35InputGuard', app: 'AirQc35.app',
};

export type Options = { buildOnly: boolean; noOpen: boolean; uninstall: boolean; headset?: string; input?: string };
export type Command = { file: string; args: string[]; cwd?: string; timeoutMs?: number };
export type CommandResult = { status: number; stdout: string; stderr: string };
export type Service = { loaded: boolean; program?: string; pid?: number };
export type Plist = Record<string, unknown>;
export type Files = {
  exists(path: string): boolean; read(path: string): string; write(path: string, text: string): void;
  mkdir(path: string): void; copy(source: string, target: string): void; move(source: string, target: string): void;
  remove(path: string): void; digest(path: string): string; isLink(path: string): boolean;
};
export type Context = {
  source: string; home: string; uid: number; architecture: string; node: string;
  files: Files; run(command: Command): CommandResult; log(event: string, fields?: Record<string, unknown>): void;
  wait(milliseconds: number): void;
};
export type Artifacts = { helper: string; app: string; builtApp?: string };
export type Paths = ReturnType<typeof createPaths>;
export type ServicePlan = { writePlist: boolean; bootout: boolean; bootstrap: boolean; restart: boolean };
type Replacement = { destination: string; previous?: string };

export function parseOptions(args: string[]): Options {
  const options: Options = { buildOnly: false, noOpen: false, uninstall: false };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === '--build-only') options.buildOnly = true;
    else if (arg === '--no-open') options.noOpen = true;
    else if (arg === '--uninstall') options.uninstall = true;
    else if (arg === '--headset' || arg === '--input') {
      const value = args[++index];
      if (!value || value.startsWith('--')) throw new Error(`${arg} requires an exact name or identifier`);
      options[arg === '--headset' ? 'headset' : 'input'] = value;
    } else throw new Error(`Unknown option: ${arg}`);
  }
  if (options.uninstall && (options.buildOnly || options.headset || options.input)) throw new Error('--uninstall cannot be combined with build or setup options');
  return options;
}

export function createPaths(source: string, home: string, appName = Identity.app) {
  if (!isAbsolute(source) || !isAbsolute(home) || basename(appName) !== appName || !appName.endsWith('.app')) throw new Error('Installer paths must be absolute and the app name must be a basename');
  const runtime = join(home, 'Library', 'Application Support', Identity.helper);
  const build = join(source, 'build', 'Installer');
  return {
    source, home, runtime, build, derived: join(build, 'DerivedData'), payload: join(build, 'Payload'),
    helper: join(runtime, Identity.helper), config: join(runtime, 'config.json'),
    logs: join(home, 'Library', 'Logs', Identity.helper),
    plist: join(home, 'Library', 'LaunchAgents', `${Identity.label}.plist`),
    app: join(home, 'Applications', appName), legacyApp: join(home, 'Applications', 'QC35.app'),
  };
}

export function launchAgent(paths: Paths, existing: Plist = {}): Plist {
  const desired: Plist = { ThrottleInterval: 10, ...existing, Label: Identity.label, ProgramArguments: [paths.helper, 'watch'],
    WorkingDirectory: paths.runtime, ProcessType: 'Background', RunAtLoad: true, KeepAlive: true,
    StandardOutPath: join(paths.logs, 'launchd.stdout.log'),
    StandardErrorPath: join(paths.logs, 'launchd.stderr.log') };
  delete desired.Program;
  return desired;
}

export function planService(existing: Plist | undefined, desired: Plist, service: Service, helperChanged: boolean): ServicePlan {
  const expected = (desired.ProgramArguments as string[])[0];
  if (existing && existing.Label !== Identity.label) throw new Error('Existing LaunchAgent belongs to another service');
  if (service.loaded && !existing) throw new Error('Loaded helper has no LaunchAgent plist to preserve; repair its installation before updating');
  if (service.loaded && service.program !== expected) throw new Error('Loaded service does not run the owned helper; refusing to replace or terminate it');
  const writePlist = !existing || stableJSON(existing) !== stableJSON(desired);
  return { writePlist, bootout: service.loaded && writePlist, bootstrap: !service.loaded || writePlist,
    restart: service.loaded && !writePlist && helperChanged && service.pid !== undefined };
}

export function parseService(result: CommandResult): Service {
  if (result.status !== 0) {
    if (result.status === 113 || /Could not find (?:specified )?service/i.test(result.stderr)) return { loaded: false };
    throw new Error(`Cannot inspect launchd service: ${result.stderr.trim() || result.status}`);
  }
  const program = result.stdout.match(/^\s*program = (.+)$/m)?.[1].trim();
  const pidText = result.stdout.match(/^\s*pid = (\d+)$/m)?.[1];
  return { loaded: true, program, ...(pidText ? { pid: Number(pidText) } : {}) };
}

export function buildCommands(context: Context, paths: Paths): Command[] {
  const common = ['-project', join(context.source, 'ControlCenter', 'QC35.xcodeproj'), '-scheme', 'QC35',
    '-configuration', 'Release', '-derivedDataPath', paths.derived, `ARCHS=${context.architecture}`, 'ONLY_ACTIVE_ARCH=YES'];
  return [
    { file: '/usr/bin/xcrun', timeoutMs: 300_000, args: ['swiftc', '-O', '-warnings-as-errors', '-target', `${context.architecture}-apple-macos27.0`, join(context.source, 'QC35InputGuard.swift'), '-o', join(paths.payload, Identity.helper)] },
    { file: context.node, args: ['--experimental-strip-types', join(context.source, 'ControlCenter', 'BuildProject.ts')] },
    { file: '/usr/bin/xcodebuild', timeoutMs: 900_000, args: [...common, 'build'] },
    { file: '/usr/bin/xcodebuild', timeoutMs: 120_000, args: [...common, '-showBuildSettings', '-json'] },
  ];
}

export function build(context: Context): Artifacts {
  const paths = createPaths(context.source, context.home);
  context.files.mkdir(paths.payload);
  const commands = buildCommands(context, paths);
  for (const command of commands.slice(0, 3)) execute(context, command);
  const settings = JSON.parse(execute(context, commands[3]).stdout) as { target: string; buildSettings: Record<string, string> }[];
  const host = settings.find(value => value.buildSettings.PRODUCT_BUNDLE_IDENTIFIER === Identity.bundle)?.buildSettings;
  if (!host?.TARGET_BUILD_DIR || !host.FULL_PRODUCT_NAME) throw new Error('Build did not describe the companion app');
  createPaths(context.source, context.home, host.FULL_PRODUCT_NAME);
  const app = join(paths.payload, host.FULL_PRODUCT_NAME);
  context.files.remove(app); context.files.copy(join(host.TARGET_BUILD_DIR, host.FULL_PRODUCT_NAME), app);
  const artifacts = { helper: join(paths.payload, Identity.helper), app, builtApp: join(host.TARGET_BUILD_DIR, host.FULL_PRODUCT_NAME) };
  execute(context, { file: '/usr/bin/codesign', args: ['--force', '--sign', '-', '--options', 'runtime', artifacts.helper] });
  verifyArtifacts(context, artifacts);
  context.log('build_completed', { ...artifacts, architecture: context.architecture, configuration: 'Release', signing: 'ad-hoc', notarized: false });
  return artifacts;
}

export function install(context: Context, options: Options, artifacts: Artifacts): void {
  verifyArtifacts(context, artifacts);
  const paths = createPaths(context.source, context.home, basename(artifacts.app));
  const existing = readPlist(context, paths.plist);
  const desired = launchAgent(paths, existing);
  const service = inspectService(context);
  const helperChanged = !context.files.exists(paths.helper) || context.files.digest(paths.helper) !== context.files.digest(artifacts.helper);
  const plan = planService(existing, desired, service, helperChanged);
  assertOwnedDestination(context, paths.app);
  for (const path of [paths.runtime, join(paths.runtime, 'ControlCenter'), paths.logs, dirname(paths.plist), dirname(paths.app)]) context.files.mkdir(path);
  const configPreserved = context.files.exists(paths.config);
  setupIfMissing(context, options, paths, artifacts.helper);
  const replacements: Replacement[] = [];
  let serviceChanged = false;
  try {
    stopOwnedApp(context, paths.app); stopOwnedApp(context, paths.legacyApp);
    if (helperChanged) replacements.push(replace(context, artifacts.helper, paths.helper));
    replacements.push(replace(context, artifacts.app, paths.app));
    serviceChanged = plan.bootstrap || plan.restart;
    applyService(context, paths, desired, plan, service, replacements);
    retireLegacyApp(context, paths, replacements);
    for (const source of new Set([artifacts.app, artifacts.builtApp].filter(Boolean) as string[])) {
      if (source !== paths.app) execute(context, { file: registrationTool, args: ['-u', source] });
    }
    execute(context, { file: registrationTool, args: ['-f', paths.app] });
  } catch (error) {
    rollback(context, paths, replacements, service, serviceChanged, error);
    throw error;
  }
  for (const replacement of replacements) if (replacement.previous) context.files.remove(replacement.previous);
  if (!options.noOpen) execute(context, { file: '/usr/bin/open', args: [paths.app] });
  context.log('installed', { app: paths.app, helper: paths.helper, service: Identity.label, configPreserved, ...plan });
}

export function uninstall(context: Context): void {
  const paths = createPaths(context.source, context.home);
  const existing = readPlist(context, paths.plist);
  const service = inspectService(context);
  if (existing && (existing.Label !== Identity.label || (existing.ProgramArguments as string[] | undefined)?.[0] !== paths.helper || (existing.Program !== undefined && existing.Program !== paths.helper))) throw new Error('LaunchAgent is not the owned helper; refusing uninstall');
  if (service.loaded && service.program !== paths.helper) throw new Error('Loaded service is not the owned helper; refusing uninstall');
  if (service.loaded) bootout(context);
  if (existing) context.files.remove(paths.plist);
  for (const app of new Set([paths.app, paths.legacyApp])) removeOwnedApp(context, app);
  assertNotLink(context, paths.helper);
  context.files.remove(paths.helper);
  context.log('uninstalled', { configPreserved: paths.config, logsPreserved: paths.logs, service: Identity.label });
}

export function runInstaller(context: Context, options: Options): Artifacts | undefined {
  if (options.uninstall) { uninstall(context); return; }
  const artifacts = build(context);
  if (!options.buildOnly) install(context, options, artifacts);
  return artifacts;
}

function setupIfMissing(context: Context, options: Options, paths: Paths, helper: string): void {
  if (context.files.exists(paths.config)) { context.log('configuration_preserved', { path: paths.config }); return; }
  const args = ['setup'];
  if (options.headset) args.push('--headset', options.headset);
  if (options.input) args.push('--input', options.input);
  execute(context, { file: helper, args, timeoutMs: 30_000 });
  if (!context.files.exists(paths.config)) throw new Error('Helper setup did not create configuration; service was not started');
}

function applyService(context: Context, paths: Paths, desired: Plist, plan: ServicePlan, before: Service, replacements: Replacement[]): void {
  const minimumStartTime = plan.bootstrap || plan.restart ? Date.now() - 1000 : undefined;
  if (plan.bootout) bootout(context);
  if (plan.writePlist) replacements.push(writePlist(context, paths.plist, desired));
  if (plan.bootstrap) bootstrap(context, paths);
  if (plan.restart) {
    const current = inspectService(context);
    if (current.program !== paths.helper || !current.pid) throw new Error('Managed helper changed before restart; refusing to signal it');
    context.log('managed_helper_restart', { previousPID: before.pid, pid: current.pid, program: current.program });
    const signal = context.run({ file: '/bin/launchctl', args: ['kill', 'SIGTERM', serviceTarget(context)], timeoutMs: 10_000 });
    if (signal.status !== 0) context.log('restart_signal_uncertain', { error: signal.stderr });
  }
  const after = waitForService(context, paths, plan.restart ? before.pid : undefined, minimumStartTime);
  context.log('service_running', { label: Identity.label, program: after.program, pid: after.pid });
}

function waitForService(context: Context, paths: Paths, previousPID?: number, minimumStartTime?: number): Service {
  const expires = Date.now() + 20_000;
  for (let attempt = 0; attempt < 40 && Date.now() < expires; attempt += 1) {
    const service = inspectService(context);
    if (service.loaded && service.program !== paths.helper) throw new Error('Service changed to an unrelated executable');
    if (service.pid && service.pid !== previousPID && processPath(context, service.pid) === paths.helper && helperReady(context, paths, service.pid, minimumStartTime)) {
      context.wait(500);
      const confirmed = inspectService(context);
      if (confirmed.pid === service.pid && confirmed.program === paths.helper && helperReady(context, paths, service.pid, minimumStartTime)) return confirmed;
      continue;
    }
    context.wait(500);
  }
  throw new Error('Owned helper did not reach a stable running PID with a started event within 20 seconds');
}

function helperReady(context: Context, paths: Paths, pid: number, minimumStartTime?: number): boolean {
  const records: Record<string, unknown>[] = [];
  for (const file of ['events.jsonl.previous', 'events.jsonl']) {
    const path = join(paths.logs, file);
    if (!context.files.exists(path)) continue;
    for (const line of context.files.read(path).split('\n')) {
      try { const item = JSON.parse(line); if (String(item.pid) === String(pid) && item.service === Identity.label && item.runtimeRoot === paths.runtime) records.push(item); } catch {}
    }
  }
  const started = records.findLastIndex(item => item.event === 'started' && (minimumStartTime === undefined || Date.parse(String(item.time)) >= minimumStartTime));
  if (started < 0) return false;
  if (minimumStartTime === undefined) return true;
  const later = records.slice(started + 1);
  const failed = later.findLastIndex(item => item.event === 'audio_error');
  const healthy = later.findLastIndex(item => ['mic_guard_disabled', 'headset_absent', 'preferred_active', 'fallback_active', 'no_unique_safe_input'].includes(String(item.event)));
  return failed < 0 || healthy > failed;
}

function bootstrap(context: Context, paths: Paths): void {
  const result = context.run({ file: '/bin/launchctl', args: ['bootstrap', `gui/${context.uid}`, paths.plist], timeoutMs: 10_000 });
  if (result.status !== 0) {
    const current = inspectService(context);
    if (!current.loaded || current.program !== paths.helper) throw new Error(`Service bootstrap failed: ${result.stderr}`);
  }
}

function bootout(context: Context): void {
  const result = context.run({ file: '/bin/launchctl', args: ['bootout', serviceTarget(context)], timeoutMs: 10_000 });
  if (inspectService(context).loaded) throw new Error(`Service did not stop: ${result.stderr || result.status}`);
}

function rollback(context: Context, paths: Paths, replacements: Replacement[], before: Service, serviceChanged: boolean, original: unknown): void {
  try {
    if (serviceChanged && inspectService(context).loaded) bootout(context);
    for (const item of [...replacements].reverse()) {
      context.files.remove(item.destination);
      if (item.previous) context.files.move(item.previous, item.destination);
    }
    if (serviceChanged && before.loaded) { const startedAfter = Date.now() - 1000; bootstrap(context, paths); waitForService(context, paths, undefined, startedAfter); }
    for (const app of [paths.app, paths.legacyApp]) if (context.files.exists(app)) execute(context, { file: registrationTool, args: ['-f', app] });
    context.log('installation_rolled_back', { error: String(original), configPreserved: true });
  } catch (error) { throw new Error(`Install failed: ${original}; rollback incomplete: ${error}. Preserved backups: ${replacements.map(item => item.previous).filter(Boolean).join(', ')}`); }
}

function verifyArtifacts(context: Context, artifacts: Artifacts): void {
  const info = readPlist(context, join(artifacts.app, 'Contents', 'Info.plist'));
  if (info?.CFBundleIdentifier !== Identity.bundle) throw new Error('Built app has an unexpected bundle identifier');
  for (const path of [artifacts.helper, artifacts.app]) execute(context, { file: '/usr/bin/codesign', args: ['--verify', '--deep', '--strict', path] });
}

function replace(context: Context, source: string, destination: string): Replacement {
  assertNotLink(context, destination);
  const pending = `${destination}.install-${randomUUID()}`;
  const previous = `${destination}.previous-${randomUUID()}`;
  context.files.copy(source, pending);
  try {
    execute(context, { file: '/usr/bin/codesign', args: ['--verify', '--deep', '--strict', pending] });
    if (context.files.exists(destination)) context.files.move(destination, previous);
    try { context.files.move(pending, destination); }
    catch (error) { if (context.files.exists(previous)) context.files.move(previous, destination); throw error; }
    return { destination, ...(context.files.exists(previous) ? { previous } : {}) };
  } finally { context.files.remove(pending); }
}

function assertOwnedDestination(context: Context, app: string): void {
  assertNotLink(context, app);
  if (context.files.exists(app) && readPlist(context, join(app, 'Contents', 'Info.plist'))?.CFBundleIdentifier !== Identity.bundle) throw new Error(`Refusing to replace unrelated application: ${app}`);
}

function retireLegacyApp(context: Context, paths: Paths, replacements: Replacement[]): void {
  if (paths.legacyApp === paths.app || !context.files.exists(paths.legacyApp)) return;
  if (readPlist(context, join(paths.legacyApp, 'Contents', 'Info.plist'))?.CFBundleIdentifier !== Identity.bundle) return;
  assertNotLink(context, paths.legacyApp);
  execute(context, { file: registrationTool, args: ['-u', paths.legacyApp] });
  const previous = `${paths.legacyApp}.previous-${randomUUID()}`;
  context.files.move(paths.legacyApp, previous);
  replacements.push({ destination: paths.legacyApp, previous });
}

function removeOwnedApp(context: Context, app: string): void {
  if (!context.files.exists(app)) return;
  assertNotLink(context, app);
  if (readPlist(context, join(app, 'Contents', 'Info.plist'))?.CFBundleIdentifier !== Identity.bundle) return;
  stopOwnedApp(context, app);
  execute(context, { file: registrationTool, args: ['-u', app] });
  context.files.remove(app);
}

function stopOwnedApp(context: Context, app: string): void {
  const host = ownedExecutable(context, app, Identity.bundle);
  if (!host) return;
  stopExecutable(context, host);
  const widget = ownedExecutable(context, join(app, 'Contents', 'PlugIns', 'QC35Widget.appex'), Identity.widget);
  if (widget) stopExecutable(context, widget);
}

function ownedExecutable(context: Context, bundle: string, identity: string): string | undefined {
  const info = readPlist(context, join(bundle, 'Contents', 'Info.plist'));
  if (info?.CFBundleIdentifier !== identity || typeof info.CFBundleExecutable !== 'string') return;
  if (basename(info.CFBundleExecutable) !== info.CFBundleExecutable) throw new Error('Owned bundle has an invalid executable basename');
  return join(bundle, 'Contents', 'MacOS', info.CFBundleExecutable);
}

function stopExecutable(context: Context, executable: string): void {
  const processes = execute(context, { file: '/bin/ps', args: ['-ww', '-axo', 'pid=,comm='] }).stdout;
  for (const line of processes.split('\n')) {
    const match = line.trim().match(/^(\d+)\s+(.+)$/);
    if (!match || match[2] !== executable) continue;
    const pid = Number(match[1]);
    if (processPath(context, pid) !== executable) continue;
    context.log('owned_application_stopping', { pid, executable });
    execute(context, { file: '/bin/kill', args: ['-TERM', String(pid)] });
    for (let attempt = 0; processPath(context, pid) === executable; attempt += 1) {
      if (attempt === 20) throw new Error(`Owned application PID ${pid} did not quit within 10 seconds`);
      context.wait(500);
    }
  }
}

function processPath(context: Context, pid: number): string | undefined {
  const result = context.run({ file: '/bin/ps', args: ['-ww', '-p', String(pid), '-o', 'comm='], timeoutMs: 5_000 });
  if (result.status === 1 && !result.stdout.trim()) return;
  if (result.status !== 0) throw new Error(`Cannot verify managed PID ${pid}: ${result.stderr}`);
  return result.stdout.trim();
}

function assertNotLink(context: Context, path: string): void {
  if (context.files.isLink(path)) throw new Error(`Refusing to replace symlink: ${path}`);
}

function inspectService(context: Context): Service {
  return parseService(context.run({ file: '/bin/launchctl', args: ['print', serviceTarget(context)], timeoutMs: 10_000 }));
}

function serviceTarget(context: Context): string { return `gui/${context.uid}/${Identity.label}`; }

function readPlist(context: Context, path: string): Plist | undefined {
  if (!context.files.exists(path)) return;
  return JSON.parse(execute(context, { file: '/usr/bin/plutil', args: ['-convert', 'json', '-o', '-', path] }).stdout) as Plist;
}

function writePlist(context: Context, path: string, value: Plist): Replacement {
  assertNotLink(context, path);
  const pending = `${path}.install-${randomUUID()}`;
  try {
    context.files.write(pending, JSON.stringify(value));
    execute(context, { file: '/usr/bin/plutil', args: ['-convert', 'xml1', pending] });
    const previous = context.files.exists(path) ? `${path}.previous-${randomUUID()}` : undefined;
    if (previous) context.files.move(path, previous);
    try { context.files.move(pending, path); }
    catch (error) { if (previous) context.files.move(previous, path); throw error; }
    return { destination: path, ...(previous ? { previous } : {}) };
  } finally { context.files.remove(pending); }
}

function execute(context: Context, command: Command): CommandResult {
  context.log('command_started', { executable: command.file, arguments: command.args });
  const result = context.run(command);
  if (result.status !== 0) throw new Error(`${basename(command.file)} failed (${result.status}): ${result.stderr.trim() || result.stdout.slice(-4000)}`);
  return result;
}

function stableJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`;
  if (value !== null && typeof value === 'object') return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${stableJSON((value as Plist)[key])}`).join(',')}}`;
  return JSON.stringify(value);
}

const registrationTool = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';

function nativeContext(): Context {
  if (process.platform !== 'darwin' || !process.getuid) throw new Error('AirQc35 installer requires macOS');
  const files: Files = {
    exists: existsSync, read: path => readFileSync(path, 'utf8'), write: (path, text) => writeFileSync(path, text, { mode: 0o644 }),
    mkdir: path => { mkdirSync(path, { recursive: true }); },
    copy: (source, target) => cpSync(source, target, { recursive: true, preserveTimestamps: true, verbatimSymlinks: true }),
    move: renameSync, remove: path => rmSync(path, { force: true, recursive: true }),
    digest: path => createHash('sha256').update(readFileSync(path)).digest('hex'),
    isLink: path => { try { return lstatSync(path).isSymbolicLink(); } catch (error) { if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false; throw error; } },
  };
  const run = (command: Command): CommandResult => {
    const result = spawnSync(command.file, command.args, { cwd: command.cwd, encoding: 'utf8', timeout: command.timeoutMs ?? 30_000, killSignal: 'SIGKILL', maxBuffer: 64 * 1024 * 1024 });
    return { status: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.error?.message ?? result.stderr ?? '' };
  };
  const silicon = run({ file: '/usr/sbin/sysctl', args: ['-n', 'hw.optional.arm64'] });
  return { source: resolve(dirname(fileURLToPath(import.meta.url)), '..'), home: homedir(), uid: process.getuid(),
    architecture: silicon.status === 0 && silicon.stdout.trim() === '1' ? 'arm64' : 'x86_64', node: process.execPath, files, run,
    wait: milliseconds => { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds); },
    log: (event, fields = {}) => console.log(JSON.stringify({ event, ...fields })) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { runInstaller(nativeContext(), parseOptions(process.argv.slice(2))); }
  catch (error) { console.error(JSON.stringify({ event: 'installer_failed', error: String(error) })); process.exitCode = 1; }
}

import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
