// XP3Compat Combined DisplayProbe -- DIAGNOSTIC ONLY, NOT SHIPPED.
//
// One translation unit that preserves the production XP3Compat fix and adds
// the read-only display probe. Order matters: the compat fix is included first
// so its constructor runs before the probe's when the dylib loads.
//
// Do not edit Sources/XP3Compat.m or DisplayProbe.m for this target; if names
// ever collide they must be resolved here (or in the wrapper build flags), not
// in production.

#include "../../Sources/XP3Compat.m"
#include "DisplayProbe.m"
