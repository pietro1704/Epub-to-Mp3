# Apple native experience — product outcome specification

Status: **Final product specification; all product questions resolved.**
Decision date: 2026-11-12.
Scope: native iPhone, iPad, and Mac applications.

This specification describes the desired finished product and observable
acceptance, not an implementation schedule or a claim of shipped behavior.
Requirements marked confirmed come from the product discussion. The decision
table records the settled choices, including the final dependent questions.
The current deliverable is the specification; this document does not report
application changes or successful runtime validation.

## 1. Native platform experience

**Confirmed:** iPhone, iPad, and Mac share the product behavior, with controls,
menus, navigation, materials, and input appropriate to their native platform.
iOS/iPadOS 27 devices use that system's native experience. Older supported
versions use their own native experience. Mac uses native macOS conventions.

UIKit/AppKit remain the application surfaces. Platform availability determines
the actual component and visual treatment. A custom imitation of newer system
chrome is not an acceptable substitute for native older-system controls.
Native SDK availability and actual runtime acceptance must be established
separately from this product target; the specification does not authorize a
toolchain change, runtime download, or Simulator launch.

The finished experience respects light/dark appearance, Reduce Transparency,
Reduce Motion, increased contrast, VoiceOver, supported text sizes, pointer and
keyboard input. Actions available through touch have an accessible native
equivalent on platforms without touch.

Opening a book still opens the reader directly. No Read/Listen/Download landing
screen is introduced by these requirements.

## 2. Reader chrome without layout flicker

**Confirmed:** the text always uses the geometry of the reader with its chrome
hidden. Showing or hiding chrome changes the overlay, never the text geometry.

- Top and bottom bars float over the content. Their system material or blur is
  confined to the area behind the bars, leaving the reading surface unaffected.
- Native Liquid Glass is used where appropriate and available; native standard
  materials provide the corresponding experience on other supported versions.
  Existing system material is not compounded with a second custom glass layer.
- The text can remain beneath the material while the bars are visible. Physical
  safe areas remain respected in the underlying chrome-free layout.
- The same words, line breaks, page boundaries, reading anchor, selection,
  progress, and raw viewport offset survive a chrome toggle.
- Repeated, rapid, and interrupted toggles settle on the most recently requested
  state, with no flash, blank frame, text jump, or accumulated position drift.
- Text size, orientation, and real window-size changes can legitimately alter
  pagination. Merely toggling bars cannot cause that reflow.
- Paginated and continuous reading both obey this contract; first and final
  pages retain their content. Overlay coverage is distinct from clipped glyphs:
  glyphs in the underlying text layout remain complete.

**Acceptance:** a visible/hidden round trip preserves the exact underlying
viewport and content position; repeated toggles do not change page count or
boundaries. Every supported reader surface satisfies this, including EPUB and
PDF where those surfaces are available.

**Existing-contract difference:** the current [viewport ADR](adr/2026-08-14-reader-viewport-transition.md)
and [native reader instructions](../ios/EpubToMp3/AGENTS.md) allow chrome to
change viewport size while preserving offset. The requested final behavior
replaces that size-changing product assumption with a fixed viewport. Their
ordering, identity, offset preservation, and glyph protection guarantees remain
applicable. This specification records the difference explicitly; it does not silently
claim the implementation or canonical runtime contracts have already changed.

## 3. Reader top bar and recent tool

**Confirmed:** exactly two application action buttons appear on the trailing
side of the reader top bar: the most recently used tool and the native More
button (`…`). Navigation on the leading side remains native.

- Choosing a tool from More makes it the direct-access tool.
- The choice survives closing and reopening the application.
- More retains access to the reader's other supported tools in logically grouped
  native menus, with meaningful localized labels and symbols.
- Navigation, temporary selection commands, and unrelated screens do not
  silently replace the recent reader tool.
- Other screens keep their context-appropriate principal action and More menu;
  the remembered-tool rule belongs to the reader.
- Before any recorded choice, the direct-access tool is Aa, for appearance and
  typography. Using another eligible reader tool replaces it as the recent tool.

**Acceptance:** choosing a tool, leaving the book, reopening the app, and opening
another book preserves the intended direct access without adding a third reader
action button. A smaller supported window still exposes every command.

## 4. Native selection, playback, and persistent highlights

**Confirmed:** long press preserves native text selection. The prominent
application action is `Tocar daqui` (Play from here), with additional actions
under `…` or the platform's native More/submenu affordance.

- Native selection handles and selection adjustment remain functional. System
  editing actions remain governed by the native selection menu.
- App-specific secondary actions, including highlighting and applicable existing
  note actions, are grouped under More rather than expanding the primary row.
- Long press inside an existing persistent text highlight targets that highlight.
  Its menu offers Play from here and Remove highlight instead of Add highlight.
- Long press on unhighlighted text offers the corresponding Add highlight action.
- Remove highlight removes only the targeted persistent highlight. Other saved
  highlights, reading progress, and playback state retain their identity.
- A menu gesture cannot also turn the page, toggle chrome, start playback, or
  create a duplicate highlight. Playback starts only after the explicit action.
- Persistent user highlights are distinct from the transient audio-following
  highlight and from a saved book-position bookmark.
- On Mac, native selection and contextual-menu input expose the same commands.

**Acceptance:** an existing highlight can be selected and removed via its own
menu, remains removed after reopening the book, and never exposes an Add action
for the same targeted highlight. Play from here starts at the beginning of the
selected or targeted highlighted range and continues through subsequent content;
it does not stop at the end of the selection. The range retains its book and
content identity even if the user changes screens before audio is ready.

## 5. Dismissing the miniplayer ends its session

**Confirmed:** dragging the miniplayer downward stops playback, cancels the
streaming generation associated with that playback session, and removes the
miniplayer from the screen.

- The action is session cancellation, not merely pause or visual concealment.
- Late preparation, conversion, and playback callbacks from that dismissed
  session cannot resume audio, re-create the miniplayer, or affect a newer session.
- The last usable listening position and already produced usable audio remain
  available. Dismissal does not delete the book, installed models, or downloads.
- An independently requested manual conversion continues.
- Returning to another screen or relaunching the application cannot revive the
  dismissed session. A new explicit playback request may create a new session.
- An incomplete drag returns to the prior presentation without cancellation.
- System media state reflects the end of the session. Accessible and native
  pointer/keyboard equivalents provide the same outcome where needed.

**Acceptance:** dismissal works while playing, paused, loading, and generating;
audio remains stopped and the bar remains absent when old work finishes. A
concurrent independent manual conversion remains intact.

## 6. Library grid and initially concealed search

**Confirmed:** the library's top-bar More menu exposes collection layout
controls. The user chooses the number of columns; rows follow automatically.
Cover and cell sizes adapt to the available screen or window size, like Finder.

- Layout changes are presentation preferences; they do not reorder, filter,
  duplicate, or lose books or clear the active search.
- The chosen preference survives returning to the library and restarting the
  app. Rotation, iPad window resizing, and Mac window resizing adapt the grid
  while keeping covers and titles usable.
- Search is initially concealed at the top. On touch platforms, pulling the
  library downward reveals the native search field.
- Search remains reachable with native keyboard and accessibility interactions;
  Mac uses an equivalent initially concealed native search presentation.
- An active query remains apparent while filtering results.
- The column-count preference is explicit and visible in the More menu. The
  library does not substitute a cover-size slider or ask for a fixed row count.
- When a narrower window cannot accommodate the requested column count with
  legible content and usable controls, the displayed grid temporarily uses fewer
  columns. The requested count remains saved and returns when space permits.
- An incomplete final row keeps the same cell sizing and column alignment as
  complete rows; it does not stretch remaining covers across the window.

**Acceptance:** the selected layout fits narrow and wide windows without
horizontal overflow, unusably small controls, or distorted covers. Choosing a
count, shrinking the window, and expanding it restores that count without a new
selection. Search can be revealed, used, cleared, and dismissed without changing
the library's data.

## 7. Voice models have a dedicated destination

**Confirmed:** a single Voice models row in Settings opens a separate destination
by forward/push navigation, with native back navigation. On Mac the equivalent
detail navigation follows the platform's Settings conventions.

That destination contains voice/model selection, model downloads and removal,
and voice tests. State and progress remain visible and correct when entering,
leaving, or revisiting the destination. Returning to Settings restores its
navigation context. Ordinary voice-model access does not open an alert or
replace the navigation flow with an unrelated modal.

Existing explicit download consent, model protection, provider selection, and
fallback policies remain applicable. Accessing the screen alone downloads
nothing and starts no narration.

**Acceptance:** model operations and voice selection are available from the
dedicated screen; navigating back and forward preserves the actual operation
state without duplicate observers or actions.

## 8. Remote-backend section geometry

**Confirmed:** the existing section keeps its current functions but has correct
native grouping, spacing, and bottom corners.

- An absent validation warning contributes no empty row or reserved blank space.
- The actual last visible cell receives the group's bottom corners.
- A visible validation warning uses a real row; its appearance and disappearance
  update spacing, separators, and the last-cell treatment together.

**Acceptance:** valid, invalid, and inactive configurations display only their
applicable content, with no orphan blank row and no square lower edge on the
last visible grouped cell. This visual correction adds no backend requirement
to the embedded local conversion architecture.

## 9. Magnetic sliders for values in points

**Confirmed:** Settings and Aa controls that choose point-valued quantities use
a magnetic slider, with no numeric-entry alert.

- The slider snaps to the nearest allowed value while it is dragged.
- The current numeric value and its unit remain visible; the result updates
  immediately and persists consistently between Settings and Aa.
- Tapping the row or its value does not open the removed numeric alert.
- Keyboard and accessibility adjustments produce the same allowed values.
- Valid ranges remain meaningful for each setting; labels stay readable at
  supported accessibility text sizes.
- Allowed values are the current predefined values for each control, including
  irregularly spaced values. No new universal one-point increment is introduced.
- Current values remain valid when replacing a chooser or numeric alert with a
  slider. The labels, stored value, live preview, and accessibility value agree.
- For font size, the predefined scale remains 14, 17, 20, 24, and 28 pt.
- For line spacing in the existing iOS/iPadOS controls, values remain 0 through
  16 pt in 2 pt increments; margins remain 16 through 80 pt in 4 pt increments.
- Existing Mac Aa presets remain 16, 24, 32, 48, and 64 pt for margins and
  -1, 0, 0.5, 1, 2, and 3 pt for letter spacing. The requirement preserves the
  existing control's predefined set rather than silently replacing it with
  another platform's set. Other units retain their own existing choices.

**Acceptance:** every point-valued control reaches its minimum, intermediate
values, and maximum with snapping and no alert, and retains the chosen value.

## 10. Platform information without a toggle

**Confirmed:** remove the toggle from the Platform cell. Keep useful platform
information as information rather than an apparent on/off setting.

**Acceptance:** the cell contains no switch and accessibility does not announce
an adjustable toggle. Displayed platform information remains correct.

## 11. Automatic language identification throughout conversion

**Confirmed:** streaming narration and manual conversion use the same language
identification policy. It applies to the book content, independently of the
application's interface language and regardless of conversion entry point.

### 11.1 Book-level evidence and consensus

- The initial classification is for the book as a whole.
- Language declared in HTML/EPUB markup or book metadata is preferred evidence,
  never sufficient by itself. Content is always analyzed as well.
- Multiple representative content segments are sampled statistically across the
  book, rather than relying on a title, the opening page, or one chapter.
- A definite single book language requires agreement among the representative,
  informative content samples. Disagreement or insufficient evidence leads to
  additional different segments, distributed beyond the initially sampled areas.
- If markup or metadata declares English but all informative samples agree on
  Portuguese, Portuguese is confirmed and the declaration is treated as
  incorrect. Metadata has initial priority as a clue, not authority to override
  consistent content evidence.
- Meaningful content disagreement cannot be discarded to manufacture unanimity:
  it triggers more analysis or a multilingual classification. The app must not
  present a majority guess as a confirmed single language.
- Front matter, quotations, names, and sparse passages must not silently force
  a wrong language over the body of the book. Evidence and uncertainty remain
  distinguishable.

### 11.2 Multilingual books and parallel translations

- When the content actually uses multiple languages, language can belong to a
  chapter or a smaller passage, according to where the language changes.
- The app supports books with alternating languages and bilingual editions with
  facing pages or side-by-side original/translation content.
- Native reading order, source passage identity, chapter identity, and the
  relation between parallel passages remain preserved; visual proximity alone
  must not interleave unrelated lines into the narration.
- Bilingual editions always narrate both languages. There is no default that
  silently omits the translation or asks the user to choose just one language.
- Narration follows the book's reading order: one complete page or column,
  followed by its corresponding page or column. It does not alternate original
  and translation sentence by sentence or paragraph by paragraph.
- For a left-original/right-translation edition, the complete left page/column
  precedes the corresponding right page/column before advancing to the next pair.
  Other source reading directions preserve the book's actual order.
- Each passage is narrated once in its resolved language with the appropriate
  voice; changes of voice do not reset reading position or lose text boundaries.

### 11.3 Two-language voice coverage

- If existing installed voices/models cover both languages, those compatible
  selections are used. A model that supports both languages need not be
  duplicated just to create a secondary slot.
- If two models are needed, the app recommends the appropriate downloads, one
  for the primary language and one secondary model for the other language.
- Recommendations identify the covered languages and retain explicit download
  consent. The user can use an already installed compatible system voice under
  the existing fallback policy instead of an unnecessary model download.
- The second-language model is selected because its language is needed; using
  it does not require the primary model to fail first. This differs from
  technical-failure fallback, which must also remain language compatible.
- A missing second-language voice cannot silently cause that language to be
  skipped, pronounced using an incompatible voice, or reported as converted.
  The existing recovery flow explains what is missing and offers compatible
  installed voices or an explicit model download.
- The active language and voice remain identifiable through language transitions
  and fallback. Explicitly configured selections are preserved when compatible.

### 11.4 Narration, persistence, and unresolved results

- Narration uses a voice compatible with the resolved book/chapter/passage
  language, while respecting explicit provider choices and installed capability.
- The active voice/provider is identifiable when fallback is in use. Missing
  compatible voices retain the existing explicit model-installation flow;
  detection itself does not download models or authorize an online provider.
- With the same source content and language decisions, streaming and manual
  conversion agree on language and passage boundaries.
- Confirmed decisions remain associated with the correct book/content identity.
  Old analysis or audio cannot overwrite a changed source or a newer selection.
- Inconclusive initial analysis automatically examines additional different
  representative passages. The app does not immediately ask the user to guess.
- Only after further available content cannot establish a reliable result does
  the app ask the user to identify the book's language or unresolved language
  scope. It does not silently fall back to the interface/system language.
- Resampling is bounded and cancellable. Sparse or unidentifiable content reaches
  that understandable recovery state instead of an endless loading state.
- A manual correction can target a book or a passage. It is explicitly marked,
  saved for that scope, and takes precedence over automatic results there; it
  cannot be overwritten by a late analysis result. Other passages keep their
  own decisions, and the user can return the corrected scope to automatic mode.
- Changing an authoritative language decision cannot reuse audio narrated in
  the previous incorrect language as if it matched the corrected request.
- User-visible language names, uncertainty, and recovery messages are localized.

**Acceptance cases:** correct metadata plus matching text; missing metadata;
incorrect metadata overridden by unanimous content; conflicting samples;
short/sparse books; foreign quotations;
chapter-language changes; language changes within a chapter; facing-page and
side-by-side bilingual content narrated in both languages in book order; missing
primary or secondary voice; accepted and declined model-download recommendations;
interrupted analysis; manual book/passage correction; and matching results through
streaming and manual conversion.

## 12. Complete interface localization

**Confirmed:** audit the entire native app in Brazilian Portuguese, English, and
Spanish, including menus, accessibility, errors, conversion states, and recovery.

- Every app-owned user-facing string has the intended translation in all three
  existing locales. Raw localization keys and unexplained source-language text
  are not acceptable interface output.
- Plurals, formatted numbers, units, language names, and variable substitutions
  follow the selected locale and remain grammatically correct.
- App language follows native system/per-app language settings. It remains
  independent of the book language and narration language.
- Model names, proper names, technical identifiers where intentionally exposed,
  book titles, and original book text are preserved rather than mistranslated.
- Translation changes do not clip controls or remove their accessible names.
- External technical failures receive understandable localized presentation;
  diagnostic detail can remain available through the existing appropriate path.

**Acceptance:** all affected normal, empty, loading, error, cancellation, and
recovery states have coherent localized visible and accessible text in each
supported locale.

## 13. Confirmed decision record

All questions from the product interview are resolved. IDs retain their interview
numbers so that the final outcomes can be checked against the user's answers.

| ID | Product choice | Confirmed outcome |
| --- | --- | --- |
| D14 | Library density control | Explicit column count, automatic rows, responsive cell sizing. |
| D15 | Incorrect language declaration | Consistent content evidence overrides incorrect metadata. |
| D16 | Bilingual narration | Always narrate both languages; recommend two models, including a secondary model, when needed. |
| D17 | Inconclusive language identification | Analyze other representative passages first; ask only if a reliable result still cannot be obtained. |
| D18 | Play from here | Start at the selected range's beginning and continue onward. |
| D19 | Initial recent reader tool | Aa. |
| D20 | Magnetic slider values | Preserve each control's existing predefined values. |
| D21 | Manual language correction | Allowed for a book or passage, authoritative for the corrected scope. |
| D22 | Parallel bilingual reading order | Complete each source page/column, then its corresponding page/column in book order. |
| D23 | Narrow-window column behavior | Temporarily reduce displayed columns for legibility; restore the saved requested count when space permits. |

## 14. Relationship to existing specifications and Apple guidance

This is a scoped refinement of the [reader product specification](reader-product-spec.md).
Within the areas covered here, the explicit confirmed outcomes above are the
new requested targets. Other features are not added by implication. Runtime
claims remain subject to actual acceptance under the [execution policy](agents/execution-policy.md).

Official sources checked for the native-design constraints:

- [Apple HIG: Menus](https://developer.apple.com/design/human-interface-guidelines/menus)
  — native command organization, labels, and submenu affordances.
- [Apple HIG: Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
  — contextual native actions and adaptation to available space.
- [Apple HIG: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
  — separation of controls from content and system material behavior.
- [Apple HIG: Sliders](https://developer.apple.com/design/human-interface-guidelines/sliders)
  — native value adjustment; magnetic steps are this product's chosen behavior.
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
  — standard UIKit/AppKit components and accessibility-aware material adaptation.

Exact button counts, remembered tools, fixed reader geometry, and language
consensus are product requirements from this discussion, not claims that the
HIG mandates those choices. This document makes no unsupported claim about a
new API specific to iOS 27.
