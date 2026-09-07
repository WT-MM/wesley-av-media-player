"""Cold admission wiring pins where the GUI owner has no headless link seam."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
owner = (root/'src/qt/native_playback_owner.mm').read_text()
assert 'consumeLifecycle(*observations.lifecycle, observations.admissionRouteChoice)' in owner
failed = owner[owner.index('std::is_same_v<Event, native_protocol::Failed>'):]
assert re.search(r'if \(admissionRouteChoice\)\s*\{[^}]*\}\s*else if \(nativeFailureIsInformational', failed)
assert 'controller_.setLastNotice(nativeFailureText(event.reason))' in failed
assert 'controller_.setLastError(nativeFailureText(event.reason))' in failed
session = (root/'src/platform/macos/native_media_session.mm').read_text()
assert 'logNativeFailure("open", reason, dispatcher.get())' in session
