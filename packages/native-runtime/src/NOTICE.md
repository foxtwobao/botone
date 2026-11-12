OpenMausBot
Copyright 2026 Milind Soni and OpenMausBot contributors

OpenMausBot was relicensed from the MIT License to the Apache License,
Version 2.0, with the consent of all contributors whose copyright was
incorporated before the transition.

Protocol adapters in this directory are derived from selected lifecycle and
protocol-handling portions of OpenMausBot, licensed under Apache-2.0:

https://github.com/milind-soni/OpenMausBot/tree/acb1159dc09d26aff96df1c1956ab5f5a730693a

Source baseline: `acb1159dc09d26aff96df1c1956ab5f5a730693a`.
The applicable portion of the source tree's root NOTICE is reproduced above.
The repository's Apache-2.0 license also applies to these adaptations; see the
root LICENSE. Other entries in the source NOTICE concern modules not included here.

Source portions: `server/drivers/codex.ts`, `codex-questions.ts`,
`codex-app-approval.ts`, `claude.ts`, `claude-elicitation.ts`,
`server/permission-proxy.ts`, and `server/drivers/acp/{core,host,turn-state,
config-options,session-model-controls,deepseek}.ts`.

Local changes replace product configuration, account management, scheduling,
logging, process launch, events, and persistence with this application's
provider-neutral execution boundary. Unaccepted tasks are never automatically
replayed, permissions are once-only, unsupported interactions are declined,
and startup has no global queue. Optional engines are loaded only on selection.
