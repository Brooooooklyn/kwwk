# Provider error fixtures

Each file is a provider's error response, kept byte for byte, plus what kwwk
must read it as. `ProviderErrorFixtureTests` replays every file through the
same parser the provider uses in production and checks the expectation.

Fixtures come from real responses only, never from a sample written to look
like one (magpie's rule: a made-up body proves the parser against the wrong
input).

## Adding one

1. The CLI keeps error responses in `~/.kwwk/provider-errors/` (set
   `KWWK_PROVIDER_ERROR_DIR` to move it, `off` to disable). Each record has
   the request method and URL with query values redacted, the status, a few
   diagnostic headers and the body. Request headers and bodies are never
   written, so tokens are not in it. Read it anyway before committing.
2. Copy the record here under a name that says provider and refusal, e.g.
   `xai-bad-credentials-403.json`.
3. Add the fields the record does not have:
   - `provider`: the kwwk store id (`openai-codex`, `kiro`, ...).
   - `parser`: which production parser reads it. `http` is
     `ProviderFailure.http`, used by Anthropic, OpenAI Responses and Chat
     Completions, Gemini and Bedrock. The others are `kiro`, `qoder`,
     `devin:<operation>`, `cursor-http` and `cursor-end-stream`.
   - `source`: where and when it was seen, and how it was provoked.
   - `expect.category`: the `ProviderFailure.Category` it must classify as.
   - `expect.credentialRejection`: whether renewing the login could help,
     i.e. whether the agent loop reports the token to its source.
