# Compatibility

## Codex source reference

The authentication and transport behavior follows OpenAI Codex revision `be6e8eac029b183056b7e4402879f15d2c85f61b`.

That revision corresponds to the `rust-v0.147.0` tag. The package sends `0.147.0` as its compatible Codex client version.

The implementation follows these upstream areas:

- `codex-rs/login/src/pkce.rs` defines PKCE values.
- `codex-rs/login/src/server.rs` defines OAuth parameters and callback behavior.
- `codex-rs/login/src/auth/default_client.rs` defines client headers.
- `codex-rs/models-manager/src/manager.rs` defines catalog priority and default selection.
- `codex-rs/core/src/client.rs` defines the Responses request shape.

The source revision is available in the [OpenAI Codex repository](https://github.com/openai/codex/tree/be6e8eac029b183056b7e4402879f15d2c85f61b).

## Model fallback

The package requests the live Codex model catalog before each response. It selects the first visible model after an ascending priority sort.

If catalog discovery fails, the package uses `gpt-5.6-sol`. Current OpenAI guidance identifies that model as the flagship GPT-5.6 target.

The model fallback source is the [GPT-5.6 upgrade guide](https://developers.openai.com/api/docs/guides/upgrading-to-gpt-5p6-sol.md).

## Update procedure

1. Select an exact OpenAI Codex revision.

2. Compare the complete login, model catalog, headers, request body, and SSE paths.

3. Update `compatibleCodexVersion` after the transport comparison passes.

4. Update `fallbackLatestModel` from current official model guidance.

5. Update request and response tests before behavior changes.

6. Run the package tests and the iOS demo build.

7. Complete one device sign-in and one real SSE request.
