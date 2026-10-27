// "Local AI" power switch + status lights in the sidebar footer (desktop app on Windows only).
// Backed by window.localAiPower from the desktop preload (apps/desktop/src/localAi/LocalAiPower.ts).
import { PowerIcon } from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { cn } from "../../lib/utils";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

interface LocalAiPortStatus {
  readonly port: number;
  readonly label: string;
  readonly optional: boolean;
  readonly up: boolean;
}

interface LocalAiStatus {
  readonly supported: boolean;
  readonly starting: boolean;
  readonly ports: ReadonlyArray<LocalAiPortStatus>;
  readonly hasExtraServers: boolean;
  readonly startExtraServersOnLaunch: boolean;
}

interface LocalAiPowerBridge {
  readonly status: () => Promise<LocalAiStatus>;
  readonly powerOff: () => Promise<boolean>;
  readonly powerOn: () => Promise<boolean>;
  readonly setStartExtraServersOnLaunch: (value: boolean) => Promise<boolean>;
}

function bridge(): LocalAiPowerBridge | undefined {
  return (globalThis as { localAiPower?: LocalAiPowerBridge }).localAiPower;
}

export function SidebarLocalAiPower() {
  const api = bridge();
  const [status, setStatus] = useState<LocalAiStatus | null>(null);
  const [busy, setBusy] = useState(false);
  // Two-step confirm: first click arms the switch for a few seconds, second click turns everything off.
  const [armed, setArmed] = useState(false);

  useEffect(() => {
    if (!armed) return;
    const timer = setTimeout(() => setArmed(false), 6000);
    return () => clearTimeout(timer);
  }, [armed]);

  const refresh = useCallback(async () => {
    const current = bridge();
    if (!current) return;
    try {
      setStatus(await current.status());
    } catch {
      // ignore transient IPC errors
    }
  }, []);

  useEffect(() => {
    if (!api) return;
    void refresh();
    const timer = setInterval(() => void refresh(), 3000);
    return () => clearInterval(timer);
  }, [api, refresh]);

  if (!api || !status || !status.supported) return null;

  const anyUp = status.ports.some((entry) => entry.up);
  const allUp = status.ports.every((entry) => entry.up || entry.optional);
  const stateLabel = status.starting ? "Starting…" : anyUp ? (allUp ? "On" : "Partly on") : "Off";

  const onPowerClick = async () => {
    if ((anyUp || status.starting) && !armed) {
      setArmed(true);
      return;
    }
    setArmed(false);
    setBusy(true);
    try {
      if (anyUp || status.starting) await api.powerOff();
      else await api.powerOn();
    } finally {
      setBusy(false);
      void refresh();
    }
  };

  return (
    <div
      className="mx-2 mb-1 flex items-center gap-2 rounded-md bg-sidebar-control-surface px-2 py-1.5 text-xs text-sidebar-foreground"
      data-local-ai-power
    >
      <Tooltip>
        <TooltipTrigger
          render={
            <button
              type="button"
              aria-label={
                armed
                  ? "Confirm: turn Local AI off and quit"
                  : anyUp || status.starting
                    ? "Turn Local AI off and quit"
                    : "Turn Local AI on"
              }
              disabled={busy}
              onClick={() => void onPowerClick()}
              className={cn(
                "flex size-6 shrink-0 items-center justify-center rounded-full border transition-colors",
                armed
                  ? "border-destructive bg-destructive/20 text-destructive"
                  : anyUp
                    ? "border-emerald-500/60 bg-emerald-500/15 text-emerald-500 hover:bg-destructive/15 hover:text-destructive"
                    : "border-foreground/20 text-muted-foreground hover:bg-emerald-500/15 hover:text-emerald-500",
              )}
            >
              <PowerIcon className="size-3.5" />
            </button>
          }
        />
        <TooltipPopup side="top">
          {anyUp
            ? "Turn Local AI off: stops Ollama, extra local servers, the gateway and helpers, then quits Local Studio"
            : "Turn Local AI on (Ollama, gateway, extra local servers if enabled)"}
        </TooltipPopup>
      </Tooltip>
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="font-medium">
          {armed ? "Click again to turn off and quit" : `Local AI · ${stateLabel}`}
        </span>
        <span className="flex flex-wrap gap-x-2 text-muted-foreground">
          {status.ports.map((entry) => (
            <span
              key={entry.port}
              className="inline-flex items-center gap-1"
              title={`${entry.label} 127.0.0.1:${entry.port} ${entry.up ? "listening" : "closed"}`}
            >
              <span
                className={cn(
                  "inline-block size-1.5 rounded-full",
                  entry.up ? "bg-emerald-500" : "bg-foreground/25",
                )}
              />
              {entry.label} {entry.port}
            </span>
          ))}
        </span>
        {status.hasExtraServers ? (
          <label className="mt-0.5 inline-flex items-center gap-1 text-muted-foreground">
            <input
              type="checkbox"
              className="size-3"
              checked={status.startExtraServersOnLaunch}
              onChange={(event) => {
                void api.setStartExtraServersOnLaunch(event.target.checked).then(() => refresh());
              }}
            />
            Start extra servers on launch
          </label>
        ) : null}
      </div>
    </div>
  );
}
