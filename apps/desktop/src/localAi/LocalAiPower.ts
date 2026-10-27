// @effect-diagnostics nodeBuiltinImport:off -- Standalone Electron-main module that spawns the bundled PowerShell scripts.
// @effect-diagnostics globalTimers:off -- Quit fallback and arm timers run in Electron callbacks outside any Effect fiber.
// Local AI power switch (Windows): runs the bundled LocalAI-On/Off PowerShell scripts
// (resources/local-ai) so Local Studio itself can bring the local model stack up at launch
// and shut ALL of it down (Ollama, extra local servers, controller, helpers) on demand and whenever the app quits.
// Extra servers (e.g. a llama.cpp llama-server) come from a private per-user file that is never part of the repo:
// %USERPROFILE%/.local-studio-t3/local-ai-extra.json (or LOCALAI_EXTRA_CONFIG); see resources/local-ai/local-ai-extra.example.json.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import * as FS from "node:fs";
import * as Net from "node:net";
import * as OS from "node:os";
import * as Path from "node:path";

import * as Electron from "electron";

export const LOCAL_AI_CHANNELS = {
  status: "local-ai:status",
  powerOff: "local-ai:power-off",
  powerOn: "local-ai:power-on",
  setStartExtra: "local-ai:set-start-extra",
} as const;

export interface LocalAiPortStatus {
  readonly port: number;
  readonly label: string;
  readonly optional: boolean;
  readonly up: boolean;
}

export interface LocalAiStatus {
  readonly supported: boolean;
  readonly starting: boolean;
  readonly ports: ReadonlyArray<LocalAiPortStatus>;
  readonly hasExtraServers: boolean;
  readonly startExtraServersOnLaunch: boolean;
}

interface PortEntry {
  readonly port: number;
  readonly label: string;
  readonly optional: boolean;
}

const BASE_PORTS: ReadonlyArray<PortEntry> = [
  { port: 11434, label: "Ollama", optional: false },
  { port: 18091, label: "Gateway", optional: false },
];

// oxlint-disable-next-line t3code/no-global-process-runtime -- tiny standalone Electron-main module
const runtime = process;
const isWindows = runtime.platform === "win32";
const localAiHome = (): string => runtime.env.LOCALAI_HOME || Path.join(OS.homedir(), "LocalAI");
const settingsFile = (): string => Path.join(localAiHome(), "app-settings.json");

interface LocalAiAppSettings {
  startExtraServersOnLaunch: boolean;
  autoStartOnLaunch: boolean;
}

function readSettings(): LocalAiAppSettings {
  const defaults: LocalAiAppSettings = { startExtraServersOnLaunch: true, autoStartOnLaunch: true };
  try {
    const raw = JSON.parse(FS.readFileSync(settingsFile(), "utf8")) as Partial<LocalAiAppSettings>;
    return { ...defaults, ...raw };
  } catch {
    return defaults;
  }
}

function extraConfigFile(): string {
  return (
    runtime.env.LOCALAI_EXTRA_CONFIG ||
    Path.join(OS.homedir(), ".local-studio-t3", "local-ai-extra.json")
  );
}

function extraPorts(): ReadonlyArray<PortEntry> {
  try {
    const raw = JSON.parse(FS.readFileSync(extraConfigFile(), "utf8").replace(/^\uFEFF/, "")) as {
      servers?: ReadonlyArray<{ name?: unknown; port?: unknown }>;
    };
    return (raw.servers ?? []).flatMap((server) =>
      typeof server.name === "string" && typeof server.port === "number"
        ? [{ port: server.port, label: server.name, optional: true }]
        : [],
    );
  } catch {
    return [];
  }
}

function writeSettings(next: LocalAiAppSettings): void {
  FS.mkdirSync(localAiHome(), { recursive: true });
  FS.writeFileSync(settingsFile(), JSON.stringify(next, null, 2));
}

function scriptsDir(): string | null {
  const resources = (runtime as { resourcesPath?: string }).resourcesPath;
  const candidates = [
    resources ? Path.join(resources, "local-ai") : "",
    Path.resolve(__dirname, "../resources/local-ai"),
    localAiHome(),
  ].filter(Boolean);
  return candidates.find((dir) => FS.existsSync(Path.join(dir, "LocalAI-On.ps1"))) ?? null;
}

function runScript(
  name: string,
  args: ReadonlyArray<string>,
  detached: boolean,
): ChildProcess | null {
  const dir = scriptsDir();
  if (!dir) return null;
  const child = spawn(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-WindowStyle",
      "Hidden",
      "-File",
      Path.join(dir, name),
      ...args,
    ],
    { windowsHide: true, detached, stdio: "ignore" },
  );
  child.on("error", () => {});
  if (detached) child.unref();
  return child;
}

const WMI_CREATE =
  "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $env:LOCALAI_FINISHER_CMD }; exit [int]$r.ReturnValue";

function finisherCommandLine(dir: string, name: string, args: ReadonlyArray<string>): string {
  return [
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File",
    `"${Path.join(dir, name)}"`,
    ...args,
  ].join(" ");
}

// Blocking variant for quit handlers: returns only once the finisher process exists outside
// the app's process tree, so it cannot be torn down with the app.
function launchOutsideAppTreeSync(name: string, args: ReadonlyArray<string>): boolean {
  const dir = scriptsDir();
  if (!dir) return false;
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", WMI_CREATE],
    {
      windowsHide: true,
      stdio: "ignore",
      timeout: 15_000,
      env: { ...runtime.env, LOCALAI_FINISHER_CMD: finisherCommandLine(dir, name, args) },
    },
  );
  if (result.status === 0) return true;
  return runScript(name, args, true) !== null;
}

function launchOutsideAppTree(name: string, args: ReadonlyArray<string>): Promise<boolean> {
  const dir = scriptsDir();
  if (!dir) return Promise.resolve(false);
  const commandLine = finisherCommandLine(dir, name, args);
  return new Promise((resolve) => {
    const child = spawn(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", WMI_CREATE],
      {
        windowsHide: true,
        stdio: "ignore",
        env: { ...runtime.env, LOCALAI_FINISHER_CMD: commandLine },
      },
    );
    const timer = setTimeout(() => resolve(false), 15_000);
    child.once("error", () => {
      clearTimeout(timer);
      // Fall back to a plain detached child.
      resolve(runScript(name, args, true) !== null);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve(true);
      else resolve(runScript(name, args, true) !== null);
    });
  });
}

function probePort(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = Net.connect({ host: "127.0.0.1", port });
    const done = (up: boolean) => {
      socket.destroy();
      resolve(up);
    };
    socket.setTimeout(700, () => done(false));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

let onChild: ChildProcess | null = null;
let shuttingDown = false;

function turnOn(): void {
  if (!isWindows || shuttingDown) return;
  if (onChild && onChild.exitCode === null) return;
  const settings = readSettings();
  onChild = runScript(
    "LocalAI-On.ps1",
    ["-NoStudio", settings.startExtraServersOnLaunch ? "-Extra" : "-NoExtra"],
    false,
  );
  onChild?.once("exit", () => {
    onChild = null;
  });
}

async function status(): Promise<LocalAiStatus> {
  const extra = extraPorts();
  const ports = await Promise.all(
    [...BASE_PORTS, ...extra].map(async (entry) => ({ ...entry, up: await probePort(entry.port) })),
  );
  return {
    supported: isWindows && scriptsDir() !== null,
    starting: onChild !== null && onChild.exitCode === null,
    ports,
    hasExtraServers: extra.length > 0,
    startExtraServersOnLaunch: readSettings().startExtraServersOnLaunch,
  };
}

async function powerOffAndQuit(window: Electron.BrowserWindow | null): Promise<boolean> {
  if (!isWindows) return false;
  // Confirmation is a two-click arm in the sidebar (native message boxes proved unreliable here).
  void window;
  shuttingDown = true;
  if (onChild && onChild.exitCode === null) onChild.kill();
  // Finisher: waits for this process to exit, then runs the full Off sweep and verification.
  // It is created through WMI so it is NOT part of Local Studio's process tree/job and survives the quit.
  await launchOutsideAppTree("LocalAI-Off.ps1", ["-AfterExit", String(runtime.pid)]);
  setTimeout(() => Electron.app.exit(0), 20_000).unref();
  Electron.app.quit();
  return true;
}

export function installLocalAiPower(): void {
  Electron.ipcMain.handle(LOCAL_AI_CHANNELS.status, () => status());
  Electron.ipcMain.handle(LOCAL_AI_CHANNELS.powerOn, () => {
    turnOn();
    return true;
  });
  Electron.ipcMain.handle(LOCAL_AI_CHANNELS.powerOff, (event) =>
    powerOffAndQuit(Electron.BrowserWindow.fromWebContents(event.sender)),
  );
  Electron.ipcMain.handle(LOCAL_AI_CHANNELS.setStartExtra, (_event, value: unknown) => {
    writeSettings({ ...readSettings(), startExtraServersOnLaunch: value === true });
    return value === true;
  });
  if (!isWindows) return;
  // Local AI runs only while the app is open: ANY quit (closing the last window, Alt+F4, menu/tray quit,
  // the power button) runs the full Off out-of-process. The first before-quit is the one every
  // user-initiated quit goes through; the updater's quit-and-install is left alone.
  let updaterQuit = false;
  Electron.autoUpdater.on("before-quit-for-update", () => {
    updaterQuit = true;
  });
  Electron.app.on("before-quit", () => {
    if (shuttingDown || updaterQuit) return;
    shuttingDown = true;
    if (onChild && onChild.exitCode === null) onChild.kill();
    launchOutsideAppTreeSync("LocalAI-Off.ps1", ["-AfterExit", String(runtime.pid)]);
  });
  void Electron.app.whenReady().then(() => {
    if (readSettings().autoStartOnLaunch) turnOn();
  });
}
