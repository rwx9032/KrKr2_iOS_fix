// XP3Compat CombinedEngineProbe -- DIAGNOSTIC ONLY, NOT SHIPPING.
//
// One translation unit: production compat first, then the existing read-only
// DisplayProbe, then the independent EngineFrameProbe.  Constructors stay in
// source order (compat install, display timer, engine timer).  Do not edit
// Sources/XP3Compat.m, DisplayProbe.m, or production dylibs for this target.

#include "../../Sources/XP3Compat.m"
#include "DisplayProbe.m"
#include "EngineFrameProbe.m"
