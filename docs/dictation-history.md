# Dictation history

The tray/menu-bar panel keeps the latest 20 non-empty dictations in
`dictation_history.json` under the application support directory. Entries contain
text, a stable ID and completion time; audio is handled by the existing recording
and recovery flow. The newest entry appears first and history is restored on
startup. Clipboard-only bursts still accumulate their output in the clipboard,
while history keeps each transcript separately.

Recognition updates the in-memory history immediately. Atomic file writes run
asynchronously in order, independently of the recognition worker. Deletions use
the same write chain, so clearing history during recognition removes completed
entries and lets later results become new entries. A failed deletion is rolled
back if the user has not already changed the list again; saving errors remain
visible. Quitting through the panel waits for pending writes. Corrupt individual
items are skipped without losing valid adjacent entries.

Manual history copies use `NativeBridge.copyText`, sharing clipboard reservations
with automatic pastes. The copy checkmark appears only after a successful write;
a failed write shows an error instead. The latest row copies its own transcript,
including when the clipboard contains an accumulated dictation burst.

History appears in one rounded, softly tinted group with a shared left edge for
headings, transcripts and timestamps. It uses the shared typography, spacing and
icon sizes, keyboard-accessible
Cupertino controls, a disclosure with bounded scrolling, and the application's
spring/reduced-motion settings. The model selector and download/unload buttons
use the same components as the existing interface. Native panel height follows
content layout changes, including local disclosure animations and deletions.

Regression tests cover queued transcripts, persistence ordering, startup recovery,
clear during recognition, disk/clipboard failure, guarded paste/copy ordering,
keyboard disclosure, light/dark themes, 20 entries, reduced motion, and a long
model menu inside a narrow panel. Existing FIFO, cancellation and indicator-mode
checks run unchanged on macOS and Windows.
