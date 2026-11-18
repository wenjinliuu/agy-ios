import { AgyRunner } from "./agy-runner.ts";
import { AgyStore } from "./agy-store.ts";
import { loadConfig } from "./config.ts";
import { startRelayClient, type RelayClientHandle } from "./relay-client.ts";
import { startLocalBridgeServer } from "./server.ts";

async function main(): Promise<void> {
  const config = loadConfig();
  if (!config.authToken && !config.relayWsUrl) {
    console.error(
      "BRIDGE_AUTH_TOKEN is required (copy bridge/env.example to bridge/.env).",
    );
    process.exit(1);
  }
  if (!config.authToken) {
    console.error("BRIDGE_AUTH_TOKEN must be set before starting agy-bridge.");
    process.exit(1);
  }

  const store = new AgyStore(config.agyDataDir);
  const runner = new AgyRunner({
    agyBin: config.agyBin,
    defaultWorkspace: config.defaultWorkspace,
    defaultModel: config.defaultModel,
  });

  const deps = { config, store, runner };
  const server = await startLocalBridgeServer(deps);
  console.log(
    `[agy-bridge] listening on http://${config.bindHost}:${server.port}`,
  );

  let relay: RelayClientHandle | null = null;
  if (config.relayWsUrl) {
    relay = startRelayClient(deps);
    console.log(`[agy-bridge] outbound relay enabled -> ${config.relayWsUrl}`);
  }

  const shutdown = async () => {
    relay?.close();
    await server.close();
    process.exit(0);
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error("[agy-bridge] fatal:", err);
  process.exit(1);
});
