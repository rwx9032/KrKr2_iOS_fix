// XP3Compat Combined SceneProbe -- DIAGNOSTIC ONLY, NOT SHIPPED.
//
// One translation unit that preserves the production XP3Compat fix, adds the
// experimental public UIScene lifecycle adapter, and finally the read-only
// DisplayProbe. Order matters:
//   1. production XP3Compat.m (unchanged) so its constructor runs first;
//   2. XP3SceneAdapter.m so the scene delegate class exists before UIKit reads
//      the manifest's UISceneDelegateClassName;
//   3. DisplayProbe.m for the existing public geometry observations.
//
// EngineFrameProbe.m is intentionally NOT included in this target.
// Do not edit Sources/XP3Compat.m, XP3SceneAdapter.m, or DisplayProbe.m here;
// any name collision must be resolved in the wrapper/build flags instead.

#include "../../Sources/XP3Compat.m"
#include "XP3SceneAdapter.m"
#include "../DisplayLab/DisplayProbe.m"
