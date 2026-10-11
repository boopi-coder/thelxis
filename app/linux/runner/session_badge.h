#ifndef RUNNER_SESSION_BADGE_H_
#define RUNNER_SESSION_BADGE_H_

#include <flutter_linux/flutter_linux.h>

// The mandatory "being controlled" badge (docs/PROTOCOL.md section 9): an
// always-on-top, undecorated GTK window in the top-right corner of the primary
// monitor, independent of the Flutter window. Driven over the method channel
// `io.thelxis/badge` (show / dismiss; stopPressed back to Dart).
typedef struct SessionBadge SessionBadge;

SessionBadge* session_badge_new(FlBinaryMessenger* messenger);
void session_badge_free(SessionBadge* badge);

#endif  // RUNNER_SESSION_BADGE_H_
