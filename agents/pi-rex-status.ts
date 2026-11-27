// Tells rex-sidecar, rex-crab-pond and rex-resume which session a running Pi
// writes. Pi sets its process title to "pi", so its command line can't be
// read, and it doesn't keep the session file open. This extension writes
// ~/.pi/agent/state/rex/<pid>.json with the session file, model, context window
// and thinking level, and removes it when Pi exits. It also tells Rex how to
// resume Pi after a restart (an OSC 7577 report of `pi --session <file>`),
// which only Pi itself can: node hides its environment, and so the report
// token, from other processes. Install it by linking it into
// ~/.pi/agent/extensions/; see agents/README.md.
import { createHash } from "node:crypto";
import { closeSync, mkdirSync, openSync, renameSync, rmSync, writeFileSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const dir = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "state", "rex");
	const file = join(dir, `${process.pid}.json`);
	let working = false;

	// https://www.superlogical.com/rex/docs/build/program-resume.md
	function report(sessionFile: string | null, cwd: string) {
		const token = process.env.OSC7577_TOKEN;
		if (!token || !sessionFile) return;
		const b64 = (s: string) => Buffer.from(s).toString("base64");
		const argv = ["pi", "--session", sessionFile].map(b64).join(",");
		const body = `pid=${process.pid}:time=${Math.floor(Date.now() / 1000)}:argv=${argv}:cwd=${b64(cwd)}`;
		const mac = createHash("sha256").update(`${body}:${token}`).digest("hex");
		const fd = openSync("/dev/tty", "w");
		try {
			writeSync(fd, `\x1b]7577;${body}:mac=${mac}\x1b\\`);
		} finally {
			closeSync(fd);
		}
	}

	// Never interrupts Pi: the status is only for the panes beside it.
	function save(ctx: any) {
		try {
			report(ctx?.sessionManager?.getSessionFile?.() ?? null, ctx?.cwd ?? process.cwd());
		} catch {}
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

	for (const event of ["session_start", "session_switch", "session_fork", "session_tree", "session_compact", "model_select", "thinking_level_select", "turn_end"]) {
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
