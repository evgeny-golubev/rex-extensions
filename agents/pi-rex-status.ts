// Tells rex-sidecar, rex-crab-pond and rex-resume which session a running Pi
// writes. Pi sets its process title to "pi", so its command line can't be
// read, and it doesn't keep the session file open. This extension writes
// ~/.pi/agent/state/rex/<pid>.json with the session file, model, context window
// and thinking level, and removes it when Pi exits. Install it by linking it
// into ~/.pi/agent/extensions/; see agents/README.md.
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const dir = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "state", "rex");
	const file = join(dir, `${process.pid}.json`);
	let working = false;

	// Never interrupts Pi: the status is only for the panes beside it.
	function save(ctx: any) {
		try {
			const model = ctx?.model;
			mkdirSync(dir, { recursive: true });
			writeFileSync(`${file}.tmp`, JSON.stringify({
				pid: process.pid,
				sessionFile: ctx?.sessionManager?.getSessionFile?.() ?? null,
				cwd: ctx?.cwd ?? process.cwd(),
				model: model ? { id: model.id, provider: model.provider, name: model.name, contextWindow: model.contextWindow } : null,
				thinkingLevel: pi.getThinkingLevel?.() ?? null,
				working,
				updatedAt: Date.now(),
			}));
			renameSync(`${file}.tmp`, file);
		} catch {}
	}

	for (const event of ["session_start", "session_switch", "session_fork", "model_select", "turn_end"]) {
		pi.on(event as any, async (_event: any, ctx: any) => save(ctx));
	}
	pi.on("agent_start", async (_event, ctx) => {
		working = true;
		save(ctx);
	});
	pi.on("agent_end", async (_event, ctx) => {
		working = false;
		save(ctx);
	});
	pi.on("session_shutdown", async () => {
		try {
			rmSync(file, { force: true });
		} catch {}
	});
}
