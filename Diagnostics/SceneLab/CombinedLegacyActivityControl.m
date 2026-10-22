// XP3Compat CombinedLegacyActivityControl -- DIAGNOSTIC ONLY, NOT SHIPPING.
//
// Control A: existing legacy pipeline without any Scene/Bootstrap/Adaptive
// adoption. Exactly:
//   production XP3Compat.m + DisplayProbe.m + EngineFrameProbe.m
//   + EngineActivityProbe.m
//
// The existing CombinedEngineProbe wrapper already handles the static names
// shared by these generated sources. Do not include XP3SceneAdapter,
// XP3SceneBootstrap, or XP3AdaptiveGeometry in this control.

#include "../DisplayLab/CombinedEngineProbe.m"
#include "EngineActivityProbe.m"
