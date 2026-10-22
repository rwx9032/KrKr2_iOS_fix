// XP3Compat CombinedSceneEngineProbe -- DIAGNOSTIC ONLY, NOT SHIPPING.
//
// One translation unit that keeps the existing CombinedEngineProbe wrapper
// (production compat + DisplayProbe + EngineFrameProbe, with its static name
// collision handling) verbatim and adds the experimental public UIScene
// lifecycle adapter last.
//
//   #include "../DisplayLab/CombinedEngineProbe.m"   (unchanged)
//   #include "XP3SceneAdapter.m"
//
// Do not edit Sources/XP3Compat.m, DisplayLab/*.m, EngineFrameProbe.m,
// XP3SceneAdapter.m, or production dylibs for this target. If a real static
// name collision appears, stop and report it; do not rename in production.

#include "../DisplayLab/CombinedEngineProbe.m"
#include "XP3SceneAdapter.m"
