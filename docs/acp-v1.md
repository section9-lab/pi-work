# ACP v1 compatibility boundary

PiWork and its bundled Agent Host use newline-delimited ACP v1 JSON-RPC as their transport.
The core request, history replay, configuration, and streaming paths do not require
`_piWork/*` methods. Agents without the `_meta.piWork.extensions` marker are never probed with
PiWork extension requests.

## Standard ACP v1 surface

- `initialize`, including standard agent capabilities, authentication methods, and client
  boolean-config capability negotiation
- `session/list`, `session/new`, `session/load`, `session/resume`, `session/close`, and
  `session/delete`
- `session/prompt` and the `session/cancel` notification
- `session/set_mode` and `session/set_config_option`
- `session/update` user text, agent text, thought, tool-call, tool-call-update, plan,
  available-command, current-mode, config-option, session-info, and usage notifications
- `session/request_permission`, including selected and cancelled responses
- `elicitation/create` form requests at session or request scope, including string, select,
  boolean, integer, number, and multi-select fields plus accept, decline, and cancel responses

The bundled Pi runtime maps extension `select`, `confirm`, `input`, and `editor` dialogs to
standard ACP form elicitation when the client advertises `elicitation.form`. Pi's status lines
and text widgets use the generic compatibility events described below. Text widgets retain their
original content; checklist symbols never imply ACP plans, priorities, or execution states.

Session, message, turn, and event correlation used by the native UI is local Swift state.
Standard `messageId` values are preserved, and standard ACP agents do not need to provide
PiWork-specific sequence or turn metadata. Updates emitted before a `session/load` response are
buffered by the local session projection instead of being lost.

## Retained PiWork extensions

The following product features have no direct ACP v1 request equivalent and remain explicitly
namespaced extension methods:

- model/provider catalog and Pi's multi-provider authentication management
- persistent Agent Host settings
- extension package installation, configuration, update, enablement, and removal
- Git branch discovery and selection
- HTML export
- PiWork's materialized session snapshot, transcript pagination, and full tool-output retrieval
- on-demand slash-command lookup
- user-initiated session renaming

Custom session storage and the Chat/Work bootstrap profile remain under `_meta.piWork` on the
relevant standard session requests. They are optional and must never be required by another ACP
agent.

The bundled host also returns `_meta.piWork.extensions: true` and a granular
`_meta.piWork.capabilities` list from `initialize`. The legacy boolean remains for compatibility,
while the client gates each private request on its declared capability. ACP v1 has no standard
capability namespace for the product-specific methods above, so this metadata prevents PiWork
from probing arbitrary or partially compatible agents with unsupported private requests.

## Known interoperability gaps

- The bundled host still uses its snapshot extension as a richer, optional projection containing
  pagination, persisted tool output, Git state, and model metadata. Standard agents use
  `session/load` replay or an empty `session/resume` projection and are not sent snapshot requests.
- Generic ACP mode and select/boolean configuration objects have a fallback editor in the
  composer. Recognized model, thought-level, context, and PiWork access-mode controls keep their
  specialized UI.
- Standard available commands feed the native command picker. Plans appear in the collapsible
  activity panel above the composer. Cumulative cost remains in the context-usage popover.
- Standard tool-call content preserves and renders text, image, resource-link, embedded-resource,
  and diff blocks. Terminal references are preserved, but PiWork does not yet implement the ACP
  terminal client methods needed to stream their output.
- Standard agent-managed `authenticate` and `logout` actions appear alongside PiWork's separate
  multi-provider account controls. Provider-specific account management remains a PiWork extension
  because ACP agent authentication does not identify or manage an agent's internal providers.
- All four standard permission options (`allow_once`, `allow_always`, `reject_once`, and
  `reject_always`) are preserved, displayed, and returned using the Agent's option ID.
- Image support for ACP model choices is derived from the standard Agent-level prompt capability.
  The current context-window size is learned from `usage_update`; ACP v1 does not define static
  per-model context-window or maximum-output metadata.
- Filesystem, terminal, URL elicitation, and terminal-auth client capabilities are not advertised
  or implemented. Form elicitation is advertised and implemented.
- MCP HTTP and SSE transports are not advertised. MCP server parameters, including stdio servers,
  are accepted by the wire shape but are not connected because the Pi runtime has no native MCP
  integration.
- Embedded-resource and audio prompt blocks are not supported by the native composer. Baseline
  resource links are preserved as Markdown links when forwarded to Pi.
- Audio tool content is identified but does not yet have native playback controls.
- Pi extension `setStatus` has no standard ACP v1 equivalent. PiWork forwards it through the
  capability-gated `_piWork/extension_status` update using only a generic key and text; any
  installed extension key is accepted and no plugin name is inspected.
- Pi extension `setWidget(key, string[], options)` uses `_piWork/extension_widget`, advertised as
  `session.extensionWidget` in `_meta.piWork.capabilities`. Updates carry `key`, the complete
  `lines` array, and `placement` (`aboveEditor` by default or `belowEditor`). An update with no
  `lines` removes only that key. Widgets are independent, are included in the optional snapshot,
  and are cleared along with statuses before reloaded extensions start.
- Swift groups statuses and text widgets by their original key in one native activity panel above
  the composer. Both Pi placements use this panel, with above-editor entries ordered first. It
  is centered, shows a single short status without disclosure, and expands multi-line or multiple
  items inline with a bounded scroll area. Empty panels disappear and duplicate status/widget text
  is shown only once. There
  are no per-plugin renderers or inferred task states. Standard ACP plans remain a separate,
  structured section in the same panel.
- Package versions and update actions live in Settings → Plugins and reuse the existing package
  list/update extensions. Installed `version` is optional metadata; it is not a latest-version claim.
  Pi's status API has no update-notice category, so Swift only removes an explicit arrow/version/
  update-command suffix from chat presentation. A matching command label alone is hidden too;
  other task text is retained. Unknown notice formats remain visible, raw session status is unchanged,
  and commands embedded in status text are never executed. No plugin-specific names are matched.
- Component-factory widgets are rendered in AgentHost using a headless Pi TUI at 80 columns;
  their text follows the same widget update path. Pi's `requestRender` refreshes the output,
  unchanged frames are suppressed, and replaced/reloaded/disposed components are cleaned up.
  Terminal control sequences are stripped from both widgets and status lines. Native wrapping
  cannot recover text already truncated by a plugin's 80-column renderer.
- This is a read-only text projection, not a terminal emulator: widget keyboard handling,
  overlays, images, and ANSI styling are not reproduced. `custom`, `notify`, editor mutation,
  header/footer, and theme APIs still degrade to no-ops.

These remaining gaps require capability negotiation, dedicated native UI, or an adapter for the
affected feature. They no longer block the baseline create/load/resume/prompt/configuration flow
for a standard ACP v1 agent.
